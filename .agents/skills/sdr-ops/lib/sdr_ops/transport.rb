# frozen_string_literal: true

module SdrOps
  # ssh access to SDR servers, using the user's own ssh config (dlss-jump, Kerberos).
  class Transport
    SSH_OPTIONS = ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20'].freeze
    RESULT_PREFIX = 'SDR_OPS_RESULT '
    ROW_PREFIX = 'SDR_OPS_ROW '

    attr_reader :environment

    def initialize(environment:, shell: Shell.new)
      @environment = environment
      @shell = shell
    end

    def kerberos_ticket?
      @shell.run('klist', '-s').success?
    end

    # @return [String, nil] the SUNet ID from the default Kerberos principal
    def kerberos_sunet
      result = @shell.run('klist')
      return unless result.success?

      result.stdout[/principal:\s*([^@\s]+)@/i, 1]&.downcase
    end

    def preflight!(user:, host:)
      raise RemoteError, 'No Kerberos ticket: run `kinit` (then retry).' unless kerberos_ticket?

      result = ssh(user:, host:, command: 'true')
      return if result.success?

      raise RemoteError, "Can't ssh to #{user}@#{host} non-interactively (#{result.stderr.strip.lines.last&.strip}). " \
                         'Check `kinit`, the VPN, your ssh config (dlss-jump), and that you have ssh access as ' \
                         "#{user} on that host."
    end

    # Run a command string on a host with bash. `login: true` uses a login shell, which app commands need
    # (puppet sets ROBOT_ENVIRONMENT etc. in the profile); file transfers skip it so profile output can't leak in.
    def ssh(user:, host:, command:, stdin_data: nil, login: false)
      @shell.run(*ssh_argv(user:, host:, command:, login:), stdin_data:)
    end

    def ssh_argv(user:, host:, command:, login: false)
      ['ssh', *SSH_OPTIONS, "#{user}@#{host}", "bash #{login ? '-lc' : '-c'} #{Shellwords.escape(command)}"]
    end

    # Run a script from remote/ on the DSA host with `bin/rails runner`. The script arrives on stdin.
    # @return [Array<Hash>] parsed SDR_OPS_RESULT / SDR_OPS_ROW lines, in order
    def dsa_runner(script, env: {})
      rails_runner(user: DSA_USER, host: environment.dsa_host, app_dir: DSA_APP_DIR, script:, env:)
    end

    # Run a script from remote/ in the stacks app on a stacks host (`login --stacks`), the same way.
    def stacks_runner(script, env: {})
      rails_runner(user: STACKS_USER, host: environment.stacks_host, app_dir: STACKS_APP_DIR, script:, env:)
    end

    # Run a script from remote/ with a robot app's bundle on a workspace host. The script arrives on stdin.
    def app_ruby(profile, script, env: {})
      command = "cd #{APP_DIRS.fetch(profile)} && #{env_assignments(env)} bundle exec ruby -"
      run_remote_script(user: WORKSPACE_USER, host: environment.workspace_host(profile), command:, script:)
    end

    # Copy a local file to a path on a workspace host: upload to a partial file, check its md5 on the host,
    # then move it into place, so a bad or interrupted upload never sits under the real name.
    def put_file(profile, local_path:, remote_path:, md5:)
      host = environment.workspace_host(profile)
      partial = "#{remote_path}.sdr-ops-partial"
      run!(ssh_argv(user: WORKSPACE_USER, host:, command: "mkdir -p #{Shellwords.escape(File.dirname(remote_path))}"),
           "Couldn't create #{File.dirname(remote_path)}")
      run!(scp_argv(File.expand_path(local_path), "#{WORKSPACE_USER}@#{host}:#{partial}"), "Upload of #{remote_path} failed")
      verify = <<~SH
        sum=$(md5sum #{Shellwords.escape(partial)} | cut -d' ' -f1)
        if [ "$sum" != #{Shellwords.escape(md5)} ]; then rm -f #{Shellwords.escape(partial)}; echo "md5 mismatch on host: $sum" >&2; exit 3; fi
        mv -f #{Shellwords.escape(partial)} #{Shellwords.escape(remote_path)}
      SH
      run!(ssh_argv(user: WORKSPACE_USER, host:, command: verify), "Upload of #{remote_path} failed")
      remote_path
    end

    # Copy a file from a workspace host to a local path. Callers verify md5s against cocina.
    def get_file(profile, remote_path:, local_path:)
      local_path = File.expand_path(local_path)
      FileUtils.mkdir_p(File.dirname(local_path))
      host = environment.workspace_host(profile)
      run!(scp_argv("#{WORKSPACE_USER}@#{host}:#{remote_path}", local_path), "Download of #{remote_path} failed")
      local_path
    rescue RemoteError
      FileUtils.rm_f(local_path)
      raise
    end

    # scp in SFTP mode (-s): remote paths are taken literally, not interpreted by a remote shell.
    # Local paths are always absolute, so scp can't mistake one containing ":" for a remote path.
    def scp_argv(source, destination)
      ['scp', '-s', '-q', *SSH_OPTIONS, source, destination]
    end

    # @return [String, nil] md5 of a file on a workspace host, or nil if it doesn't exist
    def remote_md5(profile, path)
      escaped = Shellwords.escape(path)
      result = ssh(user: WORKSPACE_USER, host: environment.workspace_host(profile),
                   command: "if [ -f #{escaped} ]; then md5sum #{escaped} | cut -d' ' -f1; fi")
      raise RemoteError, "Couldn't check #{path}: #{result.stderr.strip}" unless result.success?

      value = result.stdout.strip
      value.empty? ? nil : value
    end

    def remove_remote(profile, path)
      ssh(user: WORKSPACE_USER, host: environment.workspace_host(profile), command: "rm -rf #{Shellwords.escape(path)}")
    end

    private

    def rails_runner(user:, host:, app_dir:, script:, env:)
      command = "cd #{app_dir} && #{env_assignments(env.merge('RAILS_ENV' => 'production'))} " \
                "bin/rails runner #{Shellwords.escape('eval($stdin.read)')}"
      run_remote_script(user:, host:, command:, script:)
    end

    def run!(argv, failure)
      result = @shell.run(*argv)
      raise RemoteError, "#{failure}: #{result.stderr.strip}" unless result.success?

      result
    end

    def run_remote_script(user:, host:, command:, script:)
      result = ssh(user:, host:, command:, stdin_data: File.read(script), login: true)
      unless result.success?
        raise RemoteError,
              "#{File.basename(script)} failed on #{host}: #{result.stderr.strip.lines.last(5).join}"
      end

      parse_records(result.stdout)
    end

    def parse_records(stdout)
      stdout.to_s.each_line.filter_map do |line|
        if line.start_with?(RESULT_PREFIX)
          JSON.parse(line.delete_prefix(RESULT_PREFIX))
        elsif line.start_with?(ROW_PREFIX)
          JSON.parse(line.delete_prefix(ROW_PREFIX))
        end
      end
    end

    def env_assignments(env)
      env.map do |key, value|
        raise UsageError, "Bad remote variable name #{key.inspect}" unless key.to_s.match?(/\A[A-Z_][A-Z0-9_]*\z/)

        "#{key}=#{Shellwords.escape(value.to_s)}"
      end.join(' ')
    end
  end
end
