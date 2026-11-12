# frozen_string_literal: true

module SdrOps
  # Runs local commands. Always takes an argv array (never a shell string) so nothing is re-parsed by a shell.
  class Shell
    Result = Data.define(:stdout, :stderr, :exitstatus) do
      def success?
        exitstatus.zero?
      end
    end

    def run(*argv, stdin_data: nil)
      stdout, stderr, status = Open3.capture3(*argv, stdin_data: stdin_data.to_s)
      Result.new(stdout:, stderr:, exitstatus: status.exitstatus || 1)
    end

    def available?(command)
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, command)) }
    end
  end
end
