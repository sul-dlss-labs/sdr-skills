# frozen_string_literal: true

module SdrOps
  # Short-lived personal DSA tokens: minted over ssh on the DSA host, kept in the OS keychain,
  # never printed or written to files. Non-secret details (sub, expiry, versions) go in a state file.
  class Credentials
    DEFAULT_TTL = 8 * 3600
    MAX_TTL = 12 * 3600
    MIN_TTL = 5 * 60
    EXPIRY_MARGIN = 120
    TOKEN_PATTERN = /\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/
    SUNET_PATTERN = /\A[a-z0-9]{2,16}\z/

    def initialize(environment:, shell: Shell.new, keychain: nil, state_dir: nil)
      @environment = environment
      @keychain = keychain || Keychain.for_platform(shell)
      @state_dir = state_dir || File.join(ENV.fetch('XDG_CONFIG_HOME', File.expand_path('~/.config')), 'sdr-ops')
    end

    # Parse durations like "8h", "90m", "3600" (seconds).
    def self.parse_ttl(value)
      seconds = case value.to_s
                when /\A(\d+)h\z/ then Regexp.last_match(1).to_i * 3600
                when /\A(\d+)m\z/ then Regexp.last_match(1).to_i * 60
                when /\A(\d+)s?\z/ then Regexp.last_match(1).to_i
                else raise UsageError, "Can't parse TTL #{value.inspect} (use e.g. 8h or 90m)"
                end
      raise UsageError, "TTL must be between 5m and #{MAX_TTL / 3600}h" unless seconds.between?(MIN_TTL, MAX_TTL)

      seconds
    end

    # Claims from a JWT payload, without verifying the signature (only DSA can do that).
    def self.claims(token)
      payload = token.split('.')[1].to_s
      JSON.parse(Base64.urlsafe_decode64(payload + ('=' * ((4 - (payload.length % 4)) % 4))))
    rescue ArgumentError, JSON::ParserError
      raise AuthError, 'Stored token is malformed; run `sdr-ops login` again.'
    end

    def login(sunet:, transport:, ttl: DEFAULT_TTL)
      raise UsageError, "Not a SUNet ID: #{sunet.inspect}" unless SUNET_PATTERN.match?(sunet.to_s)

      transport.preflight!(user: DSA_USER, host: @environment.dsa_host)
      result = transport.dsa_runner(File.join(REMOTE_DIR, 'mint_token.rb'),
                                    env: { 'SDR_OPS_SUB' => sunet, 'SDR_OPS_TTL' => ttl }).last
      token = result&.fetch('token', nil).to_s
      raise RemoteError, 'mint_token.rb returned no token' unless TOKEN_PATTERN.match?(token)

      claims = self.class.claims(token)
      raise RemoteError, 'Minted token has unexpected claims' unless claims['sub'] == sunet && claims['exp'].to_i > Time.now.to_i

      @keychain.store(service, sunet, token)
      raise Error, 'Token was not stored in the keychain' unless @keychain.fetch(service) == token

      write_state('sub' => sunet, 'exp' => claims['exp'], 'minted_at' => Time.now.utc.iso8601,
                  'dsa_cocina_models_version' => result['cocina_models_version'])
      summary
    end

    def logout
      @keychain.delete(service)
      FileUtils.rm_f(state_path)
    end

    # @return [String] the token, if present and unexpired
    def token!
      token = @keychain.fetch(service)
      raise AuthError, "Not logged in to #{env_name}: run `sdr-ops --env #{env_name} login`." if token.nil? || token.empty?

      exp = self.class.claims(token)['exp'].to_i
      if exp < Time.now.to_i + EXPIRY_MARGIN
        raise AuthError,
              "Your #{env_name} token has expired: run `sdr-ops --env #{env_name} login`."
      end

      token
    end

    # @return [String] the SUNet ID the token was minted for
    def sub!
      self.class.claims(token!)['sub']
    end

    def state
      File.exist?(state_path) ? JSON.parse(File.read(state_path)) : {}
    end

    # Non-secret description of the current session (never includes the token).
    def summary
      current = state
      exp = current['exp']&.to_i
      { env: env_name, sub: current['sub'], expires_at: exp && Time.at(exp).utc.iso8601,
        expired: exp.nil? || exp < Time.now.to_i, dsa_cocina_models_version: current['dsa_cocina_models_version'],
        local_cocina_models_version: Cocina::Models::VERSION }
    end

    def cocina_drift?
      remote = state['dsa_cocina_models_version']
      remote && remote != Cocina::Models::VERSION
    end

    private

    def env_name
      @environment.name
    end

    def service
      "sdr-ops-#{env_name}-dsa"
    end

    def state_path
      File.join(@state_dir, "#{env_name}.json")
    end

    def write_state(data)
      FileUtils.mkdir_p(@state_dir)
      File.write(state_path, JSON.pretty_generate(data))
      File.chmod(0o600, state_path)
    end
  end

  # OS keychain access. Secrets are passed on stdin, never as command arguments.
  module Keychain
    def self.for_platform(shell)
      return MacOS.new(shell) if RUBY_PLATFORM.include?('darwin')
      return Libsecret.new(shell) if shell.available?('secret-tool')

      Unavailable.new
    end

    # macOS: `security -i` reads its command from stdin, so the token never appears in a process listing.
    class MacOS
      def initialize(shell)
        @shell = shell
      end

      def store(service, account, secret)
        raise UsageError, 'Refusing to store an unexpected secret' unless Credentials::TOKEN_PATTERN.match?(secret)

        delete(service)
        @shell.run('security', '-i', stdin_data: "add-generic-password -s #{service} -a #{account} -w #{secret}\n")
      end

      def fetch(service)
        result = @shell.run('security', 'find-generic-password', '-s', service, '-w')
        result.success? ? result.stdout.strip : nil
      end

      def delete(service)
        @shell.run('security', 'delete-generic-password', '-s', service)
      end
    end

    # Linux with libsecret (secret-tool reads the secret from stdin).
    class Libsecret
      def initialize(shell)
        @shell = shell
      end

      def store(service, account, secret)
        @shell.run('secret-tool', 'store', "--label=#{service}", 'service', service, 'account', account,
                   stdin_data: secret)
      end

      def fetch(service)
        result = @shell.run('secret-tool', 'lookup', 'service', service)
        result.success? ? result.stdout.strip : nil
      end

      def delete(service)
        @shell.run('secret-tool', 'clear', 'service', service)
      end
    end

    # No keychain on this platform: logging in is impossible, nothing is stored.
    class Unavailable
      def store(*)
        raise Error, 'No supported keychain: sdr-ops needs macOS Keychain or libsecret (secret-tool).'
      end

      def fetch(*) = nil
      def delete(*) = nil
    end
  end
end
