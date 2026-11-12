# frozen_string_literal: true

module SdrOps
  # Machine-readable results go to stdout as JSON lines; messages for people go to stderr.
  class Output
    def initialize(out: $stdout, err: $stderr)
      @out = out
      @err = err
    end

    def emit(record)
      @out.puts(JSON.generate(record))
      @out.flush
    end

    def info(message)
      @err.puts(message)
    end

    def warn(message)
      @err.puts("WARNING: #{message}")
    end
  end
end
