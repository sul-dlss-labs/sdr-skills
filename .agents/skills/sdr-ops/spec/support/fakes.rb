# frozen_string_literal: true

# Records commands instead of running them; returns queued or default results.
class FakeShell
  attr_reader :calls

  def initialize
    @calls = []
    @responses = []
  end

  # Queue a response for the next command whose argv includes `match` (first match wins).
  def respond(match, stdout: '', stderr: '', exitstatus: 0)
    @responses << [match, SdrOps::Shell::Result.new(stdout:, stderr:, exitstatus:)]
  end

  def run(*argv, stdin_data: nil)
    @calls << { argv:, stdin: stdin_data }
    index = @responses.index { |match, _| argv.any? { |arg| arg.to_s.include?(match) } }
    index ? @responses.delete_at(index).last : SdrOps::Shell::Result.new(stdout: '', stderr: '', exitstatus: 0)
  end

  def available?(_command) = false
end

# Records transport calls made by the library.
class FakeTransport
  attr_reader :puts, :gets, :scripts, :removed
  attr_accessor :remote_md5s, :script_results, :downloads

  def initialize
    @puts = []
    @gets = []
    @scripts = []
    @removed = []
    @remote_md5s = {}
    @script_results = []
    @downloads = {}
  end

  def kerberos_sunet = 'jdoe'
  def preflight!(**) = nil

  def put_file(profile, local_path:, remote_path:, md5:)
    @puts << { profile:, remote_path:, md5:, bytes: File.binread(local_path) }
    remote_path
  end

  def get_file(profile, remote_path:, local_path:)
    @gets << { profile:, remote_path:, local_path: }
    FileUtils.mkdir_p(File.dirname(local_path))
    File.binwrite(local_path, @downloads.fetch(remote_path, ''))
    local_path
  end

  def remote_md5(_profile, path) = @remote_md5s[path]

  def app_ruby(profile, script, env: {})
    @scripts << { profile:, script: File.basename(script), env: }
    @script_results
  end

  def dsa_runner(script, env: {})
    @scripts << { profile: :dsa, script: File.basename(script), env: }
    @script_results
  end

  def stacks_runner(script, env: {})
    @scripts << { profile: :stacks, script: File.basename(script), env: }
    @script_results
  end

  def remove_remote(_profile, path)
    @removed << path
  end
end

class FakeCredentials
  attr_accessor :drift, :stacks_token

  def initialize(drift: false, stacks_token: nil)
    @drift = drift
    @stacks_token = stacks_token
  end

  def stacks_token! = @stacks_token || raise(SdrOps::AuthError, 'No stage stacks token: run `login --stacks`.')

  def cocina_drift? = @drift
  def state = { 'dsa_cocina_models_version' => @drift ? '0.0.1' : Cocina::Models::VERSION }
end

module ContextHelpers
  def build_context(dsa:, execute: false, transport: FakeTransport.new, output: nil, credentials: FakeCredentials.new, **)
    @out = StringIO.new
    @err = StringIO.new
    SdrOps::Context.new(env: 'stage', execute:, as: 'jdoe', run_dir: File.join(@tmpdir, 'run'),
                        output: output || SdrOps::Output.new(out: @out, err: @err), transport:,
                        credentials:, client: dsa, **)
  end

  def emitted
    @out.string.lines.map { |line| JSON.parse(line) }
  end
end
