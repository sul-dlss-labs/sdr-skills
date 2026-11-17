# frozen_string_literal: true

require 'erb'
require 'net/http'
require 'tempfile'

module SdrOps
  # Fetch, add, replace, remove, and change files in an object's structural metadata.
  # See references/files.md for where bytes must be and which attributes matter.
  class Files # rubocop:disable Metrics/ClassLength
    ID_NAMESPACE = 'https://cocina.sul.stanford.edu'
    MIMETYPES = {
      '.cpg' => 'text/plain', '.prj' => 'text/plain', '.txt' => 'text/plain', '.csv' => 'text/csv',
      '.xml' => 'application/xml', '.json' => 'application/json', '.geojson' => 'application/geo+json',
      '.shp' => 'application/vnd.shp', '.shx' => 'application/vnd.shx', '.dbf' => 'application/vnd.dbf',
      '.tif' => 'image/tiff', '.tiff' => 'image/tiff', '.jp2' => 'image/jp2', '.jpg' => 'image/jpeg',
      '.jpeg' => 'image/jpeg', '.png' => 'image/png', '.pdf' => 'application/pdf', '.zip' => 'application/zip'
    }.freeze
    FETCH_SOURCES = %w[preservation workspace stacks].freeze
    STACKS_DOWNLOADS = %w[world stanford].freeze
    FILE_SET_TYPES = %w[attachment audio document file image media object page preview three_dimensional thumb
                        video].freeze

    def initialize(context)
      @context = context
    end

    # @return [Array<Hash>] one row per file
    def list(druid, workspace: false)
      state = @context.state(druid)
      rows = each_file(state.cocina).map { |file_set, file| row(state.druid, file_set, file) }
      return rows unless workspace

      rows.each do |row|
        md5 = transport.remote_md5(@context.host, workspace_path(state.druid, row[:filename]))
        row[:in_workspace] = !md5.nil?
        row[:workspace_md5_matches] = md5 == row[:md5] if md5
      end
    end

    # `access:` (a file access hash) and `sdr_generated_text:` override what would be copied from `like:`.
    def add(druid, path: nil, content: nil, filename: nil, like: nil, file_set: nil, new_file_set: nil,
            file_set_type: nil, mimetype: nil, use: nil, preserve: nil, shelve: nil, publish: nil,
            access_from_object: false, access: nil, sdr_generated_text: false)
      state = @context.fresh_state(druid)
      @context.versions.require_own_version!(state)
      source = Source.new(path:, content:)
      filename = validate_filename!(filename || (path && File.basename(path)))
      raise Skip, "#{state.druid} already has a file named #{filename}; use replace" if find_file(state.cocina, filename)

      template = like && find_file!(state, like)
      target = target_file_set(state, like:, file_set:, new_file_set:, file_set_type:)
      file = build_file(state, target:, filename:, source:, template:, mimetype:, use:, preserve:, shelve:, publish:,
                               access_from_object:, access:, sdr_generated_text:)
      new_cocina = with_file_set(state.cocina, target.new(structural: target.structural.new(
        contains: target.structural.contains + [file]
      )))
      change(state, 'files.add', new_cocina, source:, filename:, overwrite: false,
                                             args: { filename:, like:, file_set: target.externalIdentifier },
                                             details: { file: file.to_h })
    end

    def replace(druid, filename, path: nil, content: nil, mimetype: nil)
      state = @context.fresh_state(druid)
      @context.versions.require_own_version!(state)
      source = Source.new(path:, content:)
      existing = find_file!(state, filename)
      replacement = existing.new(size: source.size, hasMessageDigests: source.digests,
                                 hasMimeType: mimetype || existing.hasMimeType, version: state.version)
      new_cocina = map_files(state.cocina) { |file| file.filename == filename ? replacement : file }
      change(state, 'files.replace', new_cocina, source:, filename:, overwrite: true,
                                                 args: { filename: },
                                                 details: { before: digest_summary(existing),
                                                            after: digest_summary(replacement) })
    end

    def remove(druid, filenames, drop_empty_file_sets: false)
      state = @context.fresh_state(druid)
      @context.versions.require_own_version!(state)
      filenames.each { |name| find_file!(state, name) }
      file_sets = state.cocina.structural.contains.filter_map do |fs|
        kept = fs.structural.contains.reject { |file| filenames.include?(file.filename) }
        next if kept.empty? && drop_empty_file_sets

        fs.new(structural: fs.structural.new(contains: kept))
      end
      new_cocina = SdrOps.valid_cocina! { state.cocina.new(structural: state.cocina.structural.new(contains: file_sets)) }
      change(state, 'files.remove', new_cocina, args: { filenames:, drop_empty_file_sets: })
    end

    # Make files readable by every robot: add group and other read permission to their workspace copies and, with
    # `export:`, to the bag accessioning exported for preservation (whose files may link to them). This fixes bytes
    # on disk, not cocina, so it needs no open version. Use it when preservationIngestWF:transfer-object fails with
    # "Permission denied" (files uploaded before sdr-ops set 0644). The dry run reports the current modes.
    def make_readable(druid, filenames, export: true)
      state = @context.state(druid)
      raise UsageError, 'Name the files to make readable' if filenames.empty?

      filenames.each { find_file!(state, it) }
      paths = filenames.flat_map do |name|
        [workspace_path(state.druid, name), (File.join(Druid.export_content_dir(state.druid), name) if export)].compact
      end
      @context.ensure_mutations_allowed!
      modes = transport.make_readable(@context.host, paths, change: @context.execute?)
      raise Skip, "#{state.druid}: none of #{paths.join(', ')} exist on #{@context.host}" if modes.all? { it[:kind] == 'missing' }

      unreadable = modes.reject { it[:kind] == 'missing' || readable_mode?(it[:mode_after]) }
      if @context.execute? && unreadable.any?
        raise Error, "#{state.druid}: still not readable: #{unreadable.map { "#{it[:path]} (#{it[:mode_after]})" }.join(', ')}"
      end

      @context.report(druid: state.druid, action: 'files.make_readable', result: @context.execute? ? 'ok' : 'planned',
                      args: { filenames:, export: }, details: { modes: })
    end

    # Move files into a file set (by ID or label): named files, and/or every file of the `from:` file sets, in
    # order, inserted at `position` (1-based; default last). Moving within one file set reorders it. Files keep
    # their identifiers and attributes. `drop_empty_file_sets:` removes file sets the move leaves empty.
    def move(druid, filenames = [], to:, from: [], position: nil, drop_empty_file_sets: false)
      state = @context.fresh_state(druid)
      @context.versions.require_own_version!(state)
      target = @context.file_sets.find!(state, to)
      names = (filenames + from.flat_map { @context.file_sets.find!(state, it).structural.contains.map(&:filename) }).uniq
      raise UsageError, 'Name files to move, or --from file sets' if names.empty?

      sets = state.cocina.structural.contains
      new_sets = rearrange(sets, names.map { find_file!(state, it) }, target, position, drop_empty_file_sets)
      raise Skip, "#{state.druid}: nothing would change" if new_sets == sets

      save_file_sets(state, 'files.move', new_sets, args: { files: names, to: target.externalIdentifier, position:,
                                                            drop_empty_file_sets: }.compact)
    end

    # Save a new list of file sets (used by FileSets too), reporting the layout before and after.
    def save_file_sets(state, action, file_sets, args:)
      before = file_set_summary(state.cocina.structural.contains)
      new_cocina = SdrOps.valid_cocina! { state.cocina.new(structural: state.cocina.structural.new(contains: file_sets)) }
      change(state, action, new_cocina, args:, details: { before:, after: file_set_summary(file_sets) })
    end

    # Change attributes of one file. `use: 'none'` removes the use.
    def set(druid, filename, mimetype: nil, use: nil, preserve: nil, shelve: nil, publish: nil,
            access_from_object: false, access: nil, sdr_generated_text: nil)
      state = @context.fresh_state(druid)
      @context.versions.require_own_version!(state)
      existing = find_file!(state, filename)
      attributes = existing.to_h
      attributes[:hasMimeType] = mimetype if mimetype
      if use == 'none'
        attributes.delete(:use)
      elsif use
        attributes[:use] = use
      end
      admin = attributes[:administrative].merge({ sdrPreserve: preserve, shelve:, publish: }.compact)
      attributes[:administrative] = admin
      attributes[:access] = object_file_access(state.cocina) if access_from_object
      attributes[:access] = access if access
      attributes[:sdrGeneratedText] = sdr_generated_text unless sdr_generated_text.nil?
      require_workspace_bytes!(state, existing, reason: 'turning preserve on') if preserve && !existing.administrative.sdrPreserve
      updated = build_cocina_file(attributes)
      raise Skip, "#{state.druid} #{filename}: nothing to change" if updated == existing

      new_cocina = map_files(state.cocina) { |file| file.filename == filename ? updated : file }
      change(state, 'files.set', new_cocina, args: { filename:, mimetype:, use:, preserve:, shelve:, publish:,
                                                     access_from_object:, access:, sdr_generated_text: }.compact)
    end

    # Download files (default: all applicable) for one druid into `to` (default <run>/downloads/<druid>).
    # `range:` (stacks only; "FIRST-LAST", "FIRST-" or "-COUNT" bytes) downloads just that part of each file, e.g.
    # `range: '0-1048575'` for a COG's headers, saved as <name>.bytes-0-1048575.<ext> next to where the whole file
    # would go.
    def fetch(druid, filenames = [], version: nil, source: 'preservation', to: nil, range: nil)
      raise UsageError, "--source must be one of #{FETCH_SOURCES.join(', ')}" unless FETCH_SOURCES.include?(source)
      raise UsageError, '--range works only with --source stacks' if range && source != 'stacks'

      range &&= ByteRange.parse(range)
      state = @context.state(druid)
      cocina = version ? @context.client.object(state.druid).version.find(version.to_i) : state.cocina
      files = select_files(state.druid, cocina, filenames, source)
      to = File.expand_path(to || File.join(@context.run_dir, 'downloads', Druid.bare(state.druid)))
      plan = files.map { |f| fetch_item(f, to, source, range) }
      send(:"fetch_from_#{source}", state.druid, files, plan, version, range) if @context.execute?
      total = plan.sum { |item| (range ? item[:range_bytes] : item[:size]).to_i }
      @context.report(druid: state.druid, action: 'files.fetch', result: @context.execute? ? 'ok' : 'planned',
                      args: { source:, version:, to:, range: range&.to_s }.compact,
                      details: { files: plan, total_bytes: total })
    end

    # Cocina access for a new file derived from the object's access (citation-only becomes dark).
    def object_file_access(cocina)
      access = cocina.access.to_h.slice(:view, :download, :location, :controlledDigitalLending)
      access[:view] = 'dark' if access[:view] == 'citation-only'
      access
    end

    def self.file_id(druid, file_set_id)
      resource_id = resource_id_from(file_set_id)
      resource_id = SecureRandom.uuid if resource_id.nil? || resource_id.empty?
      "#{ID_NAMESPACE}/file/#{Druid.bare(druid)}-#{resource_id}/#{SecureRandom.uuid}"
    end

    def self.file_set_id(druid)
      "#{ID_NAMESPACE}/fileSet/#{Druid.bare(druid)}-#{SecureRandom.uuid}"
    end

    def self.file_set_type(type)
      return Cocina::Models::FileSetType.file if type.nil?
      return type if type.start_with?('https://')

      name = type.tr('-', '_')
      unless FILE_SET_TYPES.include?(name)
        raise UsageError,
              "File set type must be one of #{FILE_SET_TYPES.join(', ')} (got #{type.inspect})"
      end

      Cocina::Models::FileSetType.public_send(name)
    end

    # Same derivation as DSA's Cocina::IdGenerator, so new file IDs look like the ones DSA mints.
    def self.resource_id_from(file_set_id)
      return if file_set_id.nil? || file_set_id.empty?
      return file_set_id unless file_set_id.start_with?("#{ID_NAMESPACE}/fileSet/")

      file_set_id.split('/').last.split('-').reject { |segment| Druid.valid?(segment) }.join('-')
    end

    private

    def transport = @context.transport

    # Stage bytes (if any), then save the cocina, then report. In a dry run nothing is uploaded or saved.
    def change(state, action, new_cocina, args:, source: nil, filename: nil, overwrite: false, details: nil)
      @context.ensure_mutations_allowed!
      before = state.summary
      remote = filename && source && workspace_path(state.druid, filename)
      staged = remote && stage!(source, remote, overwrite:)
      description = @context.description(@context.reason || state.description)
      if @context.execute?
        state.cocina = @context.client.object(state.druid).update(params: new_cocina, user_name: @context.as,
                                                                  description:)
      else
        state.cocina = new_cocina
        @context.mark_planned(state.druid)
      end
      extra = { description:, workspace_path: remote, upload: staged }.compact
      @context.report(druid: state.druid, action:, result: @context.execute? ? 'ok' : 'planned', args:, before:,
                      after: state.summary, details: (details || {}).merge(extra))
    end

    # @return [String] what happened to the bytes: uploaded | already-present | planned
    def stage!(source, remote_path, overwrite:)
      return 'planned' unless @context.execute?

      existing = transport.remote_md5(@context.host, remote_path)
      return 'already-present' if existing == source.md5
      raise Skip, "The workspace already has a different #{remote_path}; remove it or use replace" if existing && !overwrite

      source.with_local_path do |path|
        transport.put_file(@context.host, local_path: path, remote_path:, md5: source.md5)
      end
      'uploaded'
    end

    def build_file(state, target:, filename:, source:, template:, mimetype:, use:, preserve:, shelve:, publish:,
                   access_from_object:, access:, sdr_generated_text:)
      base = template ? template.administrative.to_h : {}
      administrative = { publish: pick(publish, base[:publish]), sdrPreserve: pick(preserve, base[:sdrPreserve]),
                         shelve: pick(shelve, base[:shelve]) }
      raise UsageError, 'Without --like, pass all of --preserve, --shelve, and --publish' if administrative.values.any?(&:nil?)

      use = template&.use if use.nil?
      use = nil if use == 'none'
      access ||= template && !access_from_object ? template.access.to_h : object_file_access(state.cocina)
      build_cocina_file({
        type: Cocina::Models::ObjectType.file,
        externalIdentifier: self.class.file_id(state.druid, target.externalIdentifier),
        label: filename,
        filename:,
        size: source.size,
        version: state.version,
        hasMimeType: mimetype || source.mimetype(filename),
        sdrGeneratedText: sdr_generated_text,
        hasMessageDigests: source.digests,
        access:,
        administrative:,
        use:
      }.compact)
    end

    def build_cocina_file(attributes)
      SdrOps.valid_cocina!("file attributes for #{attributes[:filename]}") { Cocina::Models::File.new(attributes) }
    end

    def pick(explicit, default)
      explicit.nil? ? default : explicit
    end

    def target_file_set(state, like:, file_set:, new_file_set:, file_set_type:)
      file_sets = state.cocina.structural.contains
      return file_set_containing(file_sets, like) if like

      return @context.file_sets.find!(state, file_set) if file_set
      return new_file_set(state, new_file_set, file_set_type || file_sets.first&.type) if new_file_set
      return file_sets.first if file_sets.one?

      raise UsageError, "#{state.druid} has #{file_sets.size} file sets: pass --like, --file-set, or --new-file-set"
    end

    def new_file_set(state, label, type)
      Cocina::Models::FileSet.new(type: self.class.file_set_type(type),
                                  externalIdentifier: self.class.file_set_id(state.druid), label:,
                                  version: state.version, structural: { contains: [] })
    end

    # Take `moving` out of every file set, insert it into `target` at `position`, and optionally drop file sets
    # the move emptied.
    def rearrange(sets, moving, target, position, drop_empty)
      emptied = sets.select { |fs| fs.structural.contains.any? { moving.include?(it) } }.map(&:externalIdentifier)
      sets.filter_map do |fs|
        files = fs.structural.contains - moving
        files = FileSets.insert(files, moving, position).flatten(1) if fs.externalIdentifier == target.externalIdentifier
        next if drop_empty && files.empty? && emptied.include?(fs.externalIdentifier)

        fs.new(structural: fs.structural.new(contains: files))
      end
    end

    def file_set_summary(file_sets)
      file_sets.map { { label: it.label, type: it.type.split('/').last, files: it.structural.contains.map(&:filename) } }
    end

    def file_set_containing(file_sets, filename)
      file_sets.find { |fs| fs.structural.contains.any? { |file| file.filename == filename } }
    end

    def with_file_set(cocina, file_set)
      SdrOps.valid_cocina! { with_file_set_unchecked(cocina, file_set) }
    end

    def with_file_set_unchecked(cocina, file_set)
      contains = cocina.structural.contains
      replaced = contains.map { |fs| fs.externalIdentifier == file_set.externalIdentifier ? file_set : fs }
      replaced << file_set unless contains.any? { |fs| fs.externalIdentifier == file_set.externalIdentifier }
      cocina.new(structural: cocina.structural.new(contains: replaced))
    end

    def map_files(cocina, &)
      file_sets = cocina.structural.contains.map do |fs|
        fs.new(structural: fs.structural.new(contains: fs.structural.contains.map(&)))
      end
      cocina.new(structural: cocina.structural.new(contains: file_sets))
    end

    def each_file(cocina)
      return [] unless cocina.respond_to?(:structural) && cocina.structural

      cocina.structural.contains.flat_map { |fs| fs.structural.contains.map { |file| [fs, file] } }
    end

    def find_file(cocina, filename)
      each_file(cocina).find { |_fs, file| file.filename == filename }&.last
    end

    def find_file!(state, filename)
      find_file(state.cocina, filename) || raise(Skip, "#{state.druid} has no file named #{filename}")
    end

    def validate_filename!(filename)
      raise UsageError, 'A filename is required (pass filename: with content:)' if filename.nil? || filename.empty?
      if filename.start_with?('/') || filename.split('/').include?('..') || filename.match?(/[\r\n]/) ||
         filename.end_with?(' ')
        raise UsageError, "Unsafe filename #{filename.inspect}"
      end

      filename
    end

    # Group and other can read: e.g. 644, 664, 755 (octal mode digits from stat).
    def readable_mode?(mode)
      mode.to_s.match?(/\A[0-7]?[0-7][4-7][4-7]\z/)
    end

    def workspace_path(druid, filename)
      File.join(Druid.workspace_content_dir(druid), filename)
    end

    def local_path(dir, filename)
      path = File.expand_path(filename, dir)
      raise UsageError, "Refusing to write outside #{dir}: #{filename}" unless path.start_with?("#{dir}/")

      path
    end

    def md5_of(file)
      file.hasMessageDigests.find { |digest| digest.type == 'md5' }&.digest
    end

    def digest_summary(file)
      { size: file.size, md5: md5_of(file), mimetype: file.hasMimeType }
    end

    def row(druid, file_set, file)
      { druid:, file_set: file_set.externalIdentifier, filename: file.filename, mimetype: file.hasMimeType,
        use: file.use, preserve: file.administrative.sdrPreserve, shelve: file.administrative.shelve,
        publish: file.administrative.publish, view: file.access.view, download: file.access.download,
        size: file.size, md5: md5_of(file), sdr_generated: file.sdrGeneratedText }
    end

    def require_workspace_bytes!(state, file, reason:)
      md5 = transport.remote_md5(@context.host, workspace_path(state.druid, file.filename))
      return if md5 && md5 == md5_of(file)

      raise Skip, "#{reason} needs #{file.filename} in the workspace with md5 #{md5_of(file)} (found #{md5 || 'nothing'})"
    end

    def select_files(druid, cocina, filenames, source)
      all = each_file(cocina).map(&:last)
      chosen = filenames.map { |name| all.find { |file| file.filename == name } || raise(Skip, "#{druid} has no #{name}") }
      chosen = all if filenames.empty?
      case source
      when 'preservation'
        chosen.select! { |file| file.administrative.sdrPreserve } if filenames.empty?
        chosen.each { |file| raise Skip, "#{file.filename} isn't preserved" unless file.administrative.sdrPreserve }
      when 'stacks'
        chosen.select! { |file| stacks_downloadable?(file) } if filenames.empty?
        chosen.each do |file|
          next if stacks_downloadable?(file)

          raise Skip, "#{file.filename} isn't downloadable from stacks (shelve: #{file.administrative.shelve}, " \
                      "download: #{file.access.download}); use --source preservation"
        end
      end
      raise Skip, "#{druid}: no files to fetch from #{source}" if chosen.empty?

      chosen
    end

    # World-downloadable files need no credentials; Stanford-only ones need a stacks service token
    # (`login --stacks`), which stacks treats like a Stanford user. Location-restricted and no-download files
    # can't be fetched from stacks this way.
    def stacks_downloadable?(file)
      file.administrative.shelve && STACKS_DOWNLOADS.include?(file.access.download)
    end

    def fetch_item(file, to, source, range)
      path = local_path(to, file.filename)
      item = { filename: file.filename, size: file.size, md5: md5_of(file), local_path: range ? range.local_path(path) : path }
      item.merge!(range: range.to_s, range_bytes: range.length_for(file.size)) if range
      source == 'stacks' ? item.merge(stacks_token: file.access.download != 'world') : item
    end

    def fetch_from_preservation(druid, _files, plan, version, _range)
      Downloads.from_preservation(transport, profile: @context.host, scratch_dir: @context.scratch_dir, druid:,
                                             items: plan, version:)
    end

    def fetch_from_workspace(druid, _files, plan, _version, _range)
      plan.each do |item|
        transport.get_file(@context.host, remote_path: workspace_path(druid, item[:filename]),
                                          local_path: item[:local_path])
        item[:md5_matches_cocina] = Digest::MD5.file(item[:local_path]).hexdigest == item[:md5]
      end
    end

    def fetch_from_stacks(druid, _files, plan, version, range)
      token = @context.credentials.stacks_token! if plan.any? { it[:stacks_token] }
      Downloads.from_stacks(@context.environment, druid, plan, version:, token:, range:)
    end

    # The bytes for a new or replaced file: a local path or a string.
    class Source
      def initialize(path: nil, content: nil)
        raise UsageError, 'Pass exactly one of path: or content:' unless path.nil? ^ content.nil?
        raise UsageError, "No such file: #{path}" if path && !File.file?(path)

        @path = path && File.expand_path(path)
        @content = content
      end

      def size
        @path ? File.size(@path) : @content.bytesize
      end

      def md5 = @md5 ||= digest(Digest::MD5)
      def sha1 = @sha1 ||= digest(Digest::SHA1)

      def digests
        [{ type: 'sha1', digest: sha1 }, { type: 'md5', digest: md5 }]
      end

      def mimetype(filename)
        known = MIMETYPES[File.extname(filename).downcase]
        return known if known
        raise UsageError, "Can't infer a mimetype for #{filename}; pass --mimetype" unless @path

        detected, status = Open3.capture2('file', '--brief', '--mime-type', @path)
        raise UsageError, "Can't infer a mimetype for #{filename}; pass --mimetype" unless status.success?

        detected.strip
      end

      def with_local_path
        return yield @path if @path

        Tempfile.create('sdr-ops-content') do |file|
          file.binmode
          file.write(@content)
          file.flush
          yield file.path
        end
      end

      private

      def digest(klass)
        @path ? klass.file(@path).hexdigest : klass.hexdigest(@content)
      end
    end
  end
end
