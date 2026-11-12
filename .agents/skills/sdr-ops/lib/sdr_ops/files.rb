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
    def fetch(druid, filenames = [], version: nil, source: 'preservation', to: nil)
      raise UsageError, "--source must be one of #{FETCH_SOURCES.join(', ')}" unless FETCH_SOURCES.include?(source)

      state = @context.state(druid)
      cocina = version ? @context.client.object(state.druid).version.find(version.to_i) : state.cocina
      files = select_files(state.druid, cocina, filenames, source)
      to = File.expand_path(to || File.join(@context.run_dir, 'downloads', Druid.bare(state.druid)))
      plan = files.map { |f| { filename: f.filename, size: f.size, md5: md5_of(f), local_path: local_path(to, f.filename) } }
      send(:"fetch_from_#{source}", state.druid, files, plan, version) if @context.execute?
      @context.report(druid: state.druid, action: 'files.fetch', result: @context.execute? ? 'ok' : 'planned',
                      args: { source:, version:, to: },
                      details: { files: plan, total_bytes: plan.sum { |item| item[:size].to_i } })
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

      if file_set
        return file_sets.find { |fs| fs.externalIdentifier == file_set || fs.label == file_set } ||
               raise(Skip, "#{state.druid} has no file set #{file_set.inspect}")
      end
      return new_file_set(state, new_file_set, file_set_type || file_sets.first&.type) if new_file_set
      return file_sets.first if file_sets.one?

      raise UsageError, "#{state.druid} has #{file_sets.size} file sets: pass --like, --file-set, or --new-file-set"
    end

    def new_file_set(state, label, type)
      Cocina::Models::FileSet.new(type: self.class.file_set_type(type),
                                  externalIdentifier: self.class.file_set_id(state.druid), label:,
                                  version: state.version, structural: { contains: [] })
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
          unless stacks_downloadable?(file)
            raise Skip,
                  "#{file.filename} isn't world-downloadable from stacks; use --source preservation"
          end
        end
      end
      raise Skip, "#{druid}: no files to fetch from #{source}" if chosen.empty?

      chosen
    end

    def stacks_downloadable?(file)
      file.administrative.shelve && file.access.download == 'world'
    end

    def fetch_from_preservation(druid, files, plan, version)
      remote_root = "#{@context.scratch_dir}/fetch-#{SecureRandom.hex(4)}"
      request = { druid:, version:, dest: remote_root,
                  files: files.map { |file| { filepath: file.filename, md5: md5_of(file) } } }
      records = transport.app_ruby(@context.host, File.join(REMOTE_DIR, 'fetch_preserved.rb'),
                                   env: { 'SDR_OPS_FETCH' => JSON.generate(request) })
      records.each do |record|
        item = plan.find { it[:filename] == record['filepath'] }
        transport.get_file(@context.host, remote_path: record['path'], local_path: item[:local_path])
        verify_local!(item)
      end
    ensure
      transport.remove_remote(@context.host, remote_root) if remote_root
    end

    def fetch_from_workspace(druid, _files, plan, _version)
      plan.each do |item|
        transport.get_file(@context.host, remote_path: workspace_path(druid, item[:filename]),
                                          local_path: item[:local_path])
        item[:md5_matches_cocina] = Digest::MD5.file(item[:local_path]).hexdigest == item[:md5]
      end
    end

    def fetch_from_stacks(druid, _files, plan, version)
      plan.each do |item|
        escaped = item[:filename].split('/').map { ERB::Util.url_encode(it) }.join('/')
        base = @context.environment.stacks_url
        path = version ? "v2/file/#{Druid.bare(druid)}/version/#{version}/#{escaped}" : "file/#{Druid.bare(druid)}/#{escaped}"
        http_download("#{base}/#{path}", item[:local_path])
        verify_local!(item)
      end
    end

    def verify_local!(item)
      actual = Digest::MD5.file(item[:local_path]).hexdigest
      return item[:verified] = true if item[:md5].nil? || actual == item[:md5]

      FileUtils.rm_f(item[:local_path])
      raise Error, "#{item[:filename]}: downloaded md5 #{actual} doesn't match cocina (#{item[:md5]})"
    end

    def http_download(url, local_path, redirects: 5)
      uri = URI(url)
      FileUtils.mkdir_p(File.dirname(local_path))
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.request(Net::HTTP::Get.new(uri)) do |response|
          case response
          when Net::HTTPSuccess
            File.open(local_path, 'wb') { |file| response.read_body { |chunk| file.write(chunk) } }
          when Net::HTTPRedirection
            raise Error, "Too many redirects fetching #{url}" if redirects.zero?

            return http_download(URI.join(url, response['location']).to_s, local_path, redirects: redirects - 1)
          else
            raise Error, "#{url} returned HTTP #{response.code}"
          end
        end
      end
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
