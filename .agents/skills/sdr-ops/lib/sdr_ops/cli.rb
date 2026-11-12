# frozen_string_literal: true

require 'optparse'

module SdrOps
  # `sdr-ops [global options] COMMAND [args] [options]`. Global options may appear anywhere before `--`.
  class CLI # rubocop:disable Metrics/ClassLength
    GLOBAL_FLAGS = {
      '--env' => :env, '--host' => :host, '--as' => :as, '--reason' => :reason, '--ticket' => :ticket,
      '--run' => :run_dir, '--limit' => :limit, '--max-failures' => :max_failures, '--format' => :format,
      '--druids' => :druids
    }.freeze
    BOOLEAN_FLAGS = { '--execute' => :execute }.freeze
    EXIT = { ok: 0, failed: 1, usage: 2, auth: 3, remote: 4 }.freeze

    USAGE = <<~TEXT
      Usage: sdr-ops --env qa|stage|prod [global options] COMMAND [args] [options]

      Global options (anywhere before `--`):
        --env ENV            qa, stage, or prod (required)
        --execute            apply changes (default is a dry run that changes nothing)
        --as SUNETID         who actions are attributed to (default: your Kerberos principal)
        --reason TEXT        description recorded on changes (defaults to the version description)
        --ticket REF         appended to descriptions, e.g. gis-robot-suite#1134
        --run DIR            run directory for the ledger and downloads (default: ~/sdr-ops-runs/DATE-adhoc)
        --druids FILE        druids to act on: CSV with a druid column, or one per line
        --limit N            only the first N druids (pilots)
        --max-failures N     stop after N consecutive errors (default 3)
        --host accession|gis server for workspace transfers and exec (default accession)
        --format jsonl|csv   output format for listings (default jsonl)

      Session:   login [--ttl 8h] | logout | whoami
      Inspect:   status DRUID... | show DRUID [--version N] [--public] | files DRUID [--workspace]
                 workflows DRUID [--workflow WF] [--version N] | events DRUID [--type T]
      Find:      find [--source solr|workflows] [--workflow WF --step S --status S] [--error-match RE]
                      [--content-type T] [--collection DRUID] [--facet FIELD=VALUE] [--fields a,b] [--out FILE] [--argo-url]
      Versions:  version open DRUID... --description TEXT | version close DRUID... [--description TEXT]
                 [--no-accession] [--user-versions MODE] [--lane L] | version discard DRUID...
      Workflows: workflow run WF DRUID... [--version N] [--lane L] | workflow set WF STEP STATUS DRUID... [--expect S]
                 workflow reset WF STEP DRUID... | workflow skip-all WF DRUID... --note TEXT
                 check --until WF[:STEP]:complete DRUID...
      Files:     files fetch DRUID [FILE...] [--source preservation|workspace|stacks] [--version N] [--to DIR]
                 files add DRUID PATH... [--filename N] [--like FILE | --file-set ID | --new-file-set LABEL] [--mimetype T]
                       [--use U] [--preserve B] [--shelve B] [--publish B] [--access-from-object]
                 files replace DRUID FILE PATH [--mimetype T] | files remove DRUID FILE... [--drop-empty-file-sets]
                 files set DRUID FILE [--mimetype T] [--use U] [--preserve B] [--shelve B] [--publish B]
      Collections: collection add|remove COLLECTION_DRUID DRUID...
      Clone:     clone DRUID --apo DRUID [--from prod] [--source public|dsa] [--collection DRUID] [--tag TAG]
                 [--skip-unavailable] [--keep-open]   (into --env stage or qa)
      Register:  register --title TEXT --apo DRUID [--type object] [--source-id ID] [--collection DRUID] [--tag TAG]
                 [--view V --download D] [--accession]
        (files add/replace/remove/set and collection need --open "VERSION DESCRIPTION" [--keep-open],
         unless this run already opened the version)
      Scripts:   run SCRIPT.rb [ARGS] | push LOCAL... [--to SUBDIR] | pull REMOTE... [--to DIR] | exec -- CMD...
    TEXT

    def self.start(argv, output: Output.new, **context_options)
      new(argv.dup, output:, context_options:).start
    end

    def initialize(argv, output:, context_options: {})
      @argv = argv
      @output = output
      @context_options = context_options
    end

    def start
      globals = extract_globals!(@argv)
      command = @argv.shift
      return usage(EXIT[:ok]) if command.nil? || %w[help -h --help].include?(command)

      @context = build_context(globals)
      @druids_file = globals[:druids]
      dispatch(command)
    rescue UsageError, OptionParser::ParseError => e
      @output.info("sdr-ops: #{e.message}")
      EXIT[:usage]
    rescue AuthError => e
      @output.info("sdr-ops: #{e.message}")
      EXIT[:auth]
    rescue RemoteError => e
      @output.info("sdr-ops: #{e.message}")
      EXIT[:remote]
    rescue Skip => e
      @output.emit({ result: e.is_a?(OpenVersionExists) ? 'stopped' : 'skipped', message: e.message })
      EXIT[:ok]
    rescue Error, Dor::Services::Client::Error, SystemCallError => e
      @output.info("sdr-ops: #{e.class}: #{e.message}")
      EXIT[:failed]
    end

    private

    attr_reader :context

    def usage(code)
      @output.info(USAGE)
      code
    end

    def dispatch(command)
      case command
      when 'login' then login
      when 'logout' then logout
      when 'whoami' then whoami
      when 'status' then each_druid(summary: false) { |druid| context.output.emit(context.read.status(druid)) }
      when 'show' then show
      when 'files' then files
      when 'workflows' then list_workflows
      when 'events' then events
      when 'find' then find
      when 'version' then version
      when 'workflow' then workflow
      when 'check' then check
      when 'collection' then collection
      when 'register' then register
      when 'clone' then clone_object
      when 'run' then run_script
      when 'push' then push
      when 'pull' then pull
      when 'exec' then remote_exec
      else raise UsageError, "Unknown command #{command.inspect} (see `sdr-ops help`)"
      end
    end

    # --- global options -------------------------------------------------------------------------------

    def extract_globals!(argv)
      globals = {}
      remaining = []
      until argv.empty?
        arg = argv.shift
        if arg == '--'
          remaining.push(arg, *argv)
          break
        end
        flag, inline = arg.split('=', 2)
        if BOOLEAN_FLAGS.key?(arg)
          globals[BOOLEAN_FLAGS[arg]] = true
        elsif GLOBAL_FLAGS.key?(flag)
          value = inline || argv.shift
          raise UsageError, "#{flag} needs a value" if value.nil?

          globals[GLOBAL_FLAGS[flag]] = value
        else
          remaining << arg
        end
      end
      argv.replace(remaining)
      globals
    end

    def build_context(globals)
      raise UsageError, '--env is required (qa, stage, or prod)' unless globals[:env]

      Context.new(env: globals[:env], execute: globals[:execute], as: globals[:as], reason: globals[:reason],
                  ticket: globals[:ticket], run_dir: globals[:run_dir], host: globals[:host] || 'accession',
                  limit: globals[:limit] && Integer(globals[:limit]),
                  max_failures: Integer(globals[:max_failures] || 3), format: globals[:format] || 'jsonl',
                  output: @output, **@context_options)
    end

    def parse(argv = @argv)
      options = {}
      parser = OptionParser.new { |opts| yield opts, options }
      parser.parse!(argv)
      options
    end

    def druids_from(args, include_file: true)
      list = args.dup
      list += Batch.read(@druids_file).map { it['druid'] } if @druids_file && include_file
      raise UsageError, 'Give at least one druid (or --druids FILE)' if list.empty?

      list
    end

    # Commands that take a single DRUID argument (files …) pass single: true, so --druids doesn't apply.
    def each_druid(args = @argv, summary: true, single: false, &block)
      rows = druids_from(args, include_file: !single).map { |druid| { 'druid' => druid } }
      result = if summary
                 Batch.new(context).run(rows) { |row, _ctx| block.call(row['druid']) }
               else
                 quiet_batch(rows, &block)
               end
      result[:batch][:error].to_i.positive? || result[:batch][:aborted] ? EXIT[:failed] : EXIT[:ok]
    end

    # Read-only commands: emit rows (as JSON lines, or CSV at the end) without batch summaries.
    def quiet_batch(rows)
      errors = 0
      rows.each do |row|
        yield row['druid']
      rescue Skip, Dor::Services::Client::NotFoundResponse => e
        @output.emit({ druid: row['druid'], result: 'skipped', message: e.message })
      rescue AuthError, UsageError, RemoteError
        raise
      rescue Error, Dor::Services::Client::Error => e
        errors += 1
        @output.emit({ druid: row['druid'], result: 'error', message: e.message })
      end
      { batch: { error: errors } }
    end

    def emit_rows(rows)
      if context.format == 'csv'
        Find.write(rows, out: nil, format: 'csv')
      else
        rows.each { |row| @output.emit(row) }
      end
    end

    # --- session ----------------------------------------------------------------------------------------

    def login
      options = parse { |opts, o| opts.on('--ttl DURATION') { o[:ttl] = it } }
      ttl = Credentials.parse_ttl(options[:ttl] || '8h')
      summary = context.credentials.login(sunet: context.as, transport: context.transport, ttl:)
      @output.emit(summary)
      warn_drift
      EXIT[:ok]
    end

    def logout
      context.credentials.logout
      @output.emit({ env: context.environment.name, logged_out: true })
      EXIT[:ok]
    end

    def whoami
      summary = context.credentials.summary.merge(kerberos: context.transport.kerberos_sunet)
      @output.emit(summary)
      warn_drift
      EXIT[:ok]
    end

    def warn_drift
      return unless context.credentials.cocina_drift?

      @output.warn("DSA runs cocina-models #{context.credentials.state['dsa_cocina_models_version']}, this bundle has " \
                   "#{Cocina::Models::VERSION}. Update the skill's Gemfile.lock before making changes.")
    end

    # --- inspect ----------------------------------------------------------------------------------------

    def show
      options = parse do |opts, o|
        opts.on('--version N', Integer) { o[:version] = it }
        opts.on('--public') { o[:public] = true }
      end
      druid = @argv.shift || raise(UsageError, 'show needs a druid')
      @output.emit(context.read.cocina(druid, version: options[:version], public: options[:public]) || {})
      EXIT[:ok]
    end

    def list_workflows
      options = parse do |opts, o|
        opts.on('--workflow WF') { o[:workflow] = it }
        opts.on('--version N', Integer) { o[:version] = it }
      end
      rows = []
      code = each_druid(summary: false) { |druid| rows.concat(context.read.workflows(druid, **options)) }
      emit_rows(rows)
      code
    end

    def events
      types = []
      parse { |opts, _o| opts.on('--type T') { types << it } }
      rows = []
      code = each_druid(summary: false) { |druid| rows.concat(context.read.events(druid, types: types.empty? ? nil : types)) }
      emit_rows(rows)
      code
    end

    def find
      options = { facets: {} }
      out = nil
      argo = false
      OptionParser.new do |opts|
        opts.on('--source S') { options[:source] = it }
        opts.on('--workflow WF') { options[:workflow] = it }
        opts.on('--step STEP') { options[:step] = it }
        opts.on('--status STATUS') { options[:status] = it }
        opts.on('--error-match RE') { options[:error_match] = it }
        opts.on('--content-type T') { options[:content_type] = it }
        opts.on('--collection DRUID') { options[:collection] = it }
        opts.on('--facet FIELD=VALUE') do |v|
          k, val = v.split('=', 2)
          options[:facets][k] = val
        end
        opts.on('--fields LIST', Array) { options[:fields] = it }
        opts.on('--out FILE') { out = it }
        opts.on('--argo-url') { argo = true }
      end.parse!(@argv)
      finder = Find.new(context)
      if argo
        @output.emit({ argo_url: finder.argo_url(**options.except(:source, :error_match)) })
        return EXIT[:ok]
      end

      rows = finder.run(**options)
      Find.write(rows, out:, format: out&.end_with?('.csv') ? 'csv' : context.format)
      @output.info("#{rows.size} result(s)#{" written to #{out}" if out}")
      EXIT[:ok]
    end

    # --- versions and workflows -------------------------------------------------------------------------

    def version
      sub = @argv.shift
      case sub
      when 'open'
        options = parse { |opts, o| opts.on('--description TEXT') { o[:description] = it } }
        raise UsageError, 'version open needs --description' unless options[:description]

        each_druid { |druid| context.versions.open(druid, description: options[:description]) }
      when 'close'
        options = parse do |opts, o|
          opts.on('--description TEXT') { o[:description] = it }
          opts.on('--no-accession') { o[:accession] = false }
          opts.on('--user-versions MODE') { o[:user_versions] = it }
          opts.on('--lane LANE') { o[:lane] = it }
        end
        each_druid { |druid| context.versions.close(druid, **options) }
      when 'discard'
        each_druid { |druid| context.versions.discard(druid) }
      else raise UsageError, 'version needs open, close, or discard'
      end
    end

    def workflow
      sub = @argv.shift
      case sub
      when 'run'
        options = parse do |opts, o|
          opts.on('--version N', Integer) { o[:version] = it }
          opts.on('--lane LANE') { o[:lane] = it }
        end
        name = @argv.shift || raise(UsageError, 'workflow run needs a workflow name')
        each_druid { |druid| context.workflows.run(druid, name, **options) }
      when 'set'
        options = parse do |opts, o|
          opts.on('--expect STATUS') { o[:expect] = it }
          opts.on('--note TEXT') { o[:note] = it }
        end
        name, step, status = @argv.shift(3)
        raise UsageError, 'workflow set needs WF STEP STATUS' unless status

        each_druid { |druid| context.workflows.set(druid, name, step, status, **options) }
      when 'reset'
        options = parse { |opts, o| opts.on('--note TEXT') { o[:note] = it } }
        name, step = @argv.shift(2)
        raise UsageError, 'workflow reset needs WF STEP' unless step

        each_druid { |druid| context.workflows.reset(druid, name, step, **options) }
      when 'skip-all'
        options = parse { |opts, o| opts.on('--note TEXT') { o[:note] = it } }
        name = @argv.shift || raise(UsageError, 'workflow skip-all needs a workflow name')
        each_druid { |druid| context.workflows.skip_all(druid, name, note: options[:note]) }
      else raise UsageError, 'workflow needs run, set, reset, or skip-all'
      end
    end

    def check
      options = parse { |opts, o| opts.on('--until SPEC') { o[:until] = it } }
      raise UsageError, 'check needs --until WF[:STEP]:complete' unless options[:until]

      context.workflows.parse_until(options[:until])
      rows = []
      code = each_druid(summary: false) { |druid| rows << context.workflows.check(druid, options[:until]) }
      emit_rows(rows)
      counts = rows.group_by { it[:state] }.transform_values(&:size)
      @output.info("check #{options[:until]}: #{counts.map { |k, v| "#{v} #{k}" }.join(', ')}")
      code
    end

    # --- content changes --------------------------------------------------------------------------------

    def files
      case @argv.first
      when 'fetch' then @argv.shift && files_fetch
      when 'add' then @argv.shift && files_add
      when 'replace' then @argv.shift && files_replace
      when 'remove' then @argv.shift && files_remove
      when 'set' then @argv.shift && files_set
      else files_list
      end
    end

    def files_list
      options = parse { |opts, o| opts.on('--workspace') { o[:workspace] = true } }
      rows = []
      code = each_druid(summary: false) { |druid| rows.concat(context.read.files(druid, **options)) }
      emit_rows(rows)
      code
    end

    def files_fetch
      options = parse do |opts, o|
        opts.on('--source SOURCE') { o[:source] = it }
        opts.on('--version N', Integer) { o[:version] = it }
        opts.on('--to DIR') { o[:to] = it }
      end
      druid = @argv.shift || raise(UsageError, 'files fetch needs a druid')
      each_druid([druid], single: true) { |d| context.files.fetch(d, @argv, **options) }
    end

    def files_add
      version_options, options = content_options do |opts, o|
        opts.on('--filename NAME') { o[:filename] = it }
        opts.on('--like FILE') { o[:like] = it }
        opts.on('--file-set ID') { o[:file_set] = it }
        opts.on('--new-file-set LABEL') { o[:new_file_set] = it }
        opts.on('--file-set-type TYPE') { o[:file_set_type] = it }
        file_attribute_options(opts, o)
      end
      druid, *paths = @argv
      raise UsageError, 'files add needs DRUID PATH...' if druid.nil? || paths.empty?
      raise UsageError, '--filename only works with a single PATH' if options[:filename] && paths.size > 1

      each_druid([druid], single: true) do |d|
        with_content_version(d, **version_options) do
          paths.each { |path| context.files.add(d, path:, **options) }
        end
      end
    end

    def files_replace
      version_options, options = content_options { |opts, o| opts.on('--mimetype TYPE') { o[:mimetype] = it } }
      druid, filename, path = @argv
      raise UsageError, 'files replace needs DRUID FILENAME PATH' unless path

      each_druid([druid], single: true) do |d|
        with_content_version(d, **version_options) { context.files.replace(d, filename, path:, **options) }
      end
    end

    def files_remove
      version_options, options = content_options do |opts, o|
        opts.on('--drop-empty-file-sets') { o[:drop_empty_file_sets] = true }
      end
      druid, *filenames = @argv
      raise UsageError, 'files remove needs DRUID FILENAME...' if druid.nil? || filenames.empty?

      each_druid([druid], single: true) do |d|
        with_content_version(d, **version_options) { context.files.remove(d, filenames, **options) }
      end
    end

    def files_set
      version_options, options = content_options { |opts, o| file_attribute_options(opts, o) }
      druid, filename = @argv
      raise UsageError, 'files set needs DRUID FILENAME' unless filename

      each_druid([druid], single: true) do |d|
        with_content_version(d, **version_options) { context.files.set(d, filename, **options) }
      end
    end

    def collection
      sub = @argv.shift
      raise UsageError, 'collection needs add or remove' unless %w[add remove].include?(sub)

      version_options, = content_options { |_opts, _o| nil }
      collection_druid = @argv.shift || raise(UsageError, "collection #{sub} needs COLLECTION_DRUID DRUID...")
      each_druid do |druid|
        with_content_version(druid, **version_options) do
          context.collections.public_send(sub, druid, collection_druid)
        end
      end
    end

    def file_attribute_options(opts, options)
      opts.on('--mimetype TYPE') { options[:mimetype] = it }
      opts.on('--use USE', 'e.g. master, derivative; "none" removes it') { options[:use] = it }
      opts.on('--preserve BOOL', TrueClass) { options[:preserve] = it }
      opts.on('--shelve BOOL', TrueClass) { options[:shelve] = it }
      opts.on('--publish BOOL', TrueClass) { options[:publish] = it }
      opts.on('--access-from-object') { options[:access_from_object] = true }
      opts.on('--view VIEW', 'file access view; use with --download') { (options[:access] ||= {})[:view] = it }
      opts.on('--download DOWNLOAD') { (options[:access] ||= {})[:download] = it }
      opts.on('--sdr-generated BOOL', TrueClass) { options[:sdr_generated_text] = it }
    end

    # Parses --open/--keep-open plus a command's own options.
    def content_options
      version_options = {}
      options = parse do |opts, o|
        opts.on('--open DESCRIPTION') { version_options[:open] = it }
        opts.on('--keep-open') { version_options[:keep_open] = true }
        yield opts, o
      end
      [version_options, options]
    end

    # Content changes happen in a version this run opened: an existing run-owned version, or a new one.
    def with_content_version(druid, open: nil, keep_open: false, &)
      state = context.fresh_state(druid)
      return yield if state.own_version?

      context.versions.require_own_version!(state) if open.nil?
      context.versions.open(druid, description: open, keep_open:, &)
    end

    def register
      tags = []
      options = parse do |opts, o|
        opts.on('--title TEXT') { o[:title] = it }
        opts.on('--apo DRUID') { o[:apo] = it }
        opts.on('--source-id ID', 'default: sdr-ops:<sunet>-<timestamp>') { o[:source_id] = it }
        opts.on('--type TYPE', 'default: object') { o[:type] = it }
        opts.on('--collection DRUID') { o[:collection] = it }
        opts.on('--tag TAG', 'repeatable, e.g. "Project : sdr-ops testing"') { tags << it }
        opts.on('--view VIEW') { o[:view] = it }
        opts.on('--download DOWNLOAD') { o[:download] = it }
        opts.on('--accession', 'close version 1 right away, starting accessionWF') { o[:accession] = true }
      end
      raise UsageError, 'register needs --title and --apo' unless options[:title] && options[:apo]

      context.registration.register(**options, tags:)
      @output.info('DRY RUN: nothing was registered. Re-run with --execute.') if context.dry_run?
      EXIT[:ok]
    end

    def clone_object
      tags = []
      options = parse do |opts, o|
        opts.on('--apo DRUID', 'APO in the target environment') { o[:apo] = it }
        opts.on('--from ENV', 'source environment (default prod)') { o[:from] = it }
        opts.on('--source SOURCE', 'public (purl, default) or dsa (head version; needs a login there)') { o[:source] = it }
        opts.on('--collection DRUID') { o[:collection] = it }
        opts.on('--tag TAG') { tags << it }
        opts.on('--skip-unavailable', "leave out files that can't be fetched") { o[:skip_unavailable] = true }
        opts.on('--keep-open', "don't close version 1 (no accessioning yet)") { o[:keep_open] = true }
      end
      druid = @argv.shift || raise(UsageError, 'clone needs a source DRUID')
      raise UsageError, 'clone needs --apo (an APO in the target environment)' unless options[:apo]

      context.cloner.clone_from(druid, **options, tags:)
      @output.info('DRY RUN: nothing was downloaded or created. Re-run with --execute.') if context.dry_run?
      EXIT[:ok]
    end

    # --- scripts and transfers --------------------------------------------------------------------------

    def run_script
      script = @argv.shift || raise(UsageError, 'run needs a script path')
      raise UsageError, "No such script: #{script}" unless File.file?(script)

      @argv.unshift(@druids_file) if @druids_file && @argv.empty?
      SdrOps.context = context
      ARGV.replace(@argv)
      load File.expand_path(script)
      EXIT[:ok]
    end

    def push
      options = parse { |opts, o| opts.on('--to SUBDIR') { o[:to] = it } }
      raise UsageError, 'push needs LOCAL...' if @argv.empty?

      dest_dir = File.join(context.scratch_dir, safe_relative(options[:to] || '.'))
      @argv.each do |local|
        raise UsageError, "No such file: #{local}" unless File.file?(local)

        remote = File.join(dest_dir, File.basename(local))
        md5 = Digest::MD5.file(local).hexdigest
        context.transport.put_file(context.host, local_path: local, remote_path: remote, md5:) if context.execute?
        transfer_report('push', local:, remote:, md5:)
      end
      dry_run_notice
    end

    def pull
      options = parse { |opts, o| opts.on('--to DIR') { o[:to] = it } }
      raise UsageError, 'pull needs REMOTE...' if @argv.empty?

      to = File.expand_path(options[:to] || File.join(context.run_dir, 'pulled'))
      @argv.each do |spec|
        remote = remote_path_for(spec)
        local = File.join(to, File.basename(remote))
        context.transport.get_file(context.host, remote_path: remote, local_path: local) if context.execute?
        transfer_report('pull', local:, remote:)
      end
      dry_run_notice
    end

    def remote_exec
      @argv.shift if @argv.first == '--'
      raise UsageError, 'exec needs -- CMD...' if @argv.empty?

      command = "mkdir -p #{Shellwords.escape(context.scratch_dir)} && cd #{Shellwords.escape(context.scratch_dir)} && " \
                "#{Shellwords.join(@argv)}"
      host = context.environment.workspace_host(context.host)
      unless context.execute?
        @output.emit({ action: 'exec', result: 'planned', host:, command: })
        return dry_run_notice
      end

      result = context.transport.ssh(user: WORKSPACE_USER, host:, command:, login: true)
      $stdout.write(result.stdout)
      $stderr.write(result.stderr)
      @output.emit({ action: 'exec', result: result.success? ? 'ok' : 'error', host:, exit_status: result.exitstatus })
      result.success? ? EXIT[:ok] : EXIT[:failed]
    end

    def remote_path_for(spec)
      if spec.start_with?('workspace:')
        druid, filename = spec.delete_prefix('workspace:').split('/', 2)
        raise UsageError, 'Use workspace:DRUID/FILENAME' unless filename

        File.join(Druid.workspace_content_dir(druid), safe_relative(filename))
      else
        File.join(context.scratch_dir, safe_relative(spec))
      end
    end

    def safe_relative(path)
      raise UsageError, "Unsafe path #{path.inspect}" if path.start_with?('/') || path.split('/').include?('..')

      path
    end

    def transfer_report(action, **details)
      context.ledger.record(druid: nil, action:, result: context.execute? ? 'ok' : 'planned', dry_run: context.dry_run?,
                            args: details)
      @output.emit({ action:, result: context.execute? ? 'ok' : 'planned',
                     host: context.environment.workspace_host(context.host), **details })
    end

    def dry_run_notice
      @output.info('DRY RUN: nothing was transferred or run. Re-run with --execute.') if context.dry_run?
      EXIT[:ok]
    end
  end
end
