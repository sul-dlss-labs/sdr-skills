# frozen_string_literal: true

module SdrOps
  # Everything one invocation (or one generated script) shares: environment, identity, dry-run/execute,
  # run directory and ledger, the DSA client, and per-object working state.
  class Context
    attr_reader :environment, :output, :reason, :ticket, :run_dir, :limit, :max_failures, :format, :host

    def initialize(env:, execute: false, as: nil, reason: nil, ticket: nil, run_dir: nil, host: 'accession',
                   limit: nil, max_failures: 3, format: 'jsonl', output: Output.new, shell: Shell.new,
                   transport: nil, credentials: nil, client: nil, transports: {}, credentials_by_env: {})
      @environment = SdrOps.environment(env)
      @execute = execute ? true : false
      @explicit_as = as
      @reason = reason
      @ticket = ticket
      @run_dir = File.expand_path(run_dir || default_run_dir)
      @host = host
      @environment.workspace_host(host) # validates --host
      @limit = limit
      @max_failures = max_failures
      @format = format
      @output = output
      @shell = shell
      @transport = transport
      @credentials = credentials
      @client = client
      @transports = transports
      @credentials_by_env = credentials_by_env
      @states = {}
      @planned = Set.new
    end

    def execute? = @execute
    def dry_run? = !@execute
    def run_id = File.basename(run_dir)

    def transport
      @transport ||= Transport.new(environment:, shell: @shell)
    end

    def credentials
      @credentials ||= Credentials.new(environment:, shell: @shell)
    end

    # Another environment's transport and credentials (e.g. the source of a clone).
    def transport_for(other)
      return transport if other.name == environment.name

      @transports[other.name] ||= Transport.new(environment: other, shell: @shell)
    end

    def credentials_for(other)
      return credentials if other.name == environment.name

      @credentials_by_env[other.name] ||= Credentials.new(environment: other, shell: @shell)
    end

    # The SUNet ID actions are attributed to: --as, else the Kerberos principal.
    def as
      @as ||= @explicit_as || transport.kerberos_sunet ||
              raise(UsageError, 'Pass --as SUNETID (no Kerberos principal found; run `kinit`?)')
    end

    # A configured Dor::Services::Client. The token never leaves this process.
    def client
      @client ||= begin
        token = credentials.token!
        sub = Credentials.claims(token)['sub']
        raise AuthError, "--as #{as} doesn't match the token's subject (#{sub}); log in as yourself." unless sub == as

        Dor::Services::Client.configure(url: environment.dsa_url, token:)
      end
    end

    def ledger
      @ledger ||= Ledger.new(path: File.join(run_dir, 'ledger.jsonl'), run_id:, env: environment.name, as:)
    end

    # Working state for a druid, loaded from DSA on first use (or when refresh: true).
    def state(druid, refresh: false)
      druid = Druid.normalize(druid)
      existing = @states[druid]
      return existing.reload!(client:, ledger:) if existing && refresh

      @states[druid] ||= ObjectState.load(druid, client:, ledger:)
    end

    def forget(druid)
      druid = Druid.normalize(druid)
      @states.delete(druid)
      @planned.delete(druid)
    end

    # In a dry run, an object with planned changes keeps its in-memory state instead of being reloaded.
    def mark_planned(druid)
      @planned << Druid.normalize(druid) if dry_run?
    end

    def state_planned?(druid)
      @planned.include?(Druid.normalize(druid))
    end

    # State for a change: fresh from DSA unless this dry run has already planned changes to it.
    def fresh_state(druid)
      state(druid, refresh: !state_planned?(druid))
    end

    # The description recorded on cocina updates and step notes: reason plus ticket.
    def description(text = nil)
      base = text || reason
      raise UsageError, '--reason is required for changes' if base.nil? || base.strip.empty?

      [base, ticket].compact.join('; ')
    end

    # Checks before anything that changes SDR.
    def ensure_mutations_allowed!
      client
      return unless credentials.cocina_drift?

      remote = credentials.state['dsa_cocina_models_version']
      raise Error, "DSA runs cocina-models #{remote} but this bundle has #{Cocina::Models::VERSION}; " \
                   'update the skill bundle before making changes (see `sdr-ops whoami`).'
    end

    # Record an action in the ledger and emit it.
    def report(druid:, action:, result:, args: {}, before: nil, after: nil, message: nil, details: nil)
      row = ledger.record(druid:, action:, result:, dry_run: dry_run?, args:, before:, after:, message:)
      output.emit(details ? row.merge(details:) : row)
      row
    end

    # Per-run scratch directory on the workspace host.
    def scratch_dir
      "/tmp/sdr-ops-#{as}-#{run_id.gsub(/[^A-Za-z0-9._-]/, '_')}"
    end

    # Read-only lookups (status, cocina, files, workflows, events). Named `read` because `inspect` is Object#inspect.
    def read = (@read ||= Inspect.new(self))
    def versions = (@versions ||= Versions.new(self))
    def workflows = (@workflows ||= Workflows.new(self))
    def files = (@files ||= Files.new(self))
    def collections = (@collections ||= Collections.new(self))
    def find = (@find ||= Find.new(self))
    def registration = (@registration ||= Registration.new(self))
    def cloner = (@cloner ||= Cloner.new(self))

    private

    def default_run_dir
      root = ENV.fetch('SDR_OPS_RUNS_DIR') { File.expand_path('~/sdr-ops-runs') }
      File.join(root, "#{Time.now.strftime('%Y-%m-%d')}-adhoc")
    end
  end
end
