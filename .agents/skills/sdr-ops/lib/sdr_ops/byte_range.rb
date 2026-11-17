# frozen_string_literal: true

module SdrOps
  # An HTTP byte range, in the Range header's own syntax: "FIRST-LAST" (inclusive), "FIRST-" (to the end), or
  # "-COUNT" (the last COUNT bytes). Used to read part of a file, e.g. a COG's headers, without downloading it all.
  class ByteRange
    attr_reader :from, :to, :count

    def self.parse(spec)
      return spec if spec.is_a?(self)

      case spec.to_s.strip
      when /\A(\d+)-(\d+)\z/ then new(from: Integer(Regexp.last_match(1)), to: Integer(Regexp.last_match(2)))
      when /\A(\d+)-\z/ then new(from: Integer(Regexp.last_match(1)))
      when /\A-(\d+)\z/ then new(count: Integer(Regexp.last_match(1)))
      else raise UsageError, "--range must be FIRST-LAST, FIRST- or -COUNT (bytes), e.g. 0-1048575 (got #{spec.inspect})"
      end
    end

    def initialize(from: nil, to: nil, count: nil)
      @from = from
      @to = to
      @count = count
      raise UsageError, "--range #{self}: LAST is before FIRST" if from && to && to < from
      raise UsageError, "--range #{self}: COUNT must be at least 1" if count&.zero?
    end

    def to_s = count ? "-#{count}" : "#{from}-#{to}"
    def header = "bytes=#{self}"

    # How many bytes the range covers in a file of `size` bytes (nil when that can't be known).
    def length_for(size)
      return (to - from + 1 if from && to) if size.nil?
      return [count, size].min if count

      [to || (size - 1), size - 1].min - from + 1
    end

    # Where a partial copy goes, so it never stands in for the whole file:
    # rail.fgb -> rail.bytes-0-1023.fgb, rail.bytes-100-end.fgb, rail.bytes-last-500.fgb
    def local_path(path)
      ext = File.extname(path)
      "#{path.delete_suffix(ext)}.bytes-#{label}#{ext}"
    end

    private

    def label
      return "last-#{count}" if count

      to ? "#{from}-#{to}" : "#{from}-end"
    end
  end
end
