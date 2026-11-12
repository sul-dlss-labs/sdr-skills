# frozen_string_literal: true

module SdrOps
  # Druid parsing and workspace paths (same tree layout as druid-tools).
  module Druid
    PATTERN = /\A(?:druid:)?([b-df-hjkmnp-tv-z]{2})([0-9]{3})([b-df-hjkmnp-tv-z]{2})([0-9]{4})\z/

    module_function

    def valid?(value)
      PATTERN.match?(value.to_s.strip.downcase)
    end

    # @return [String] e.g. "druid:bc641kr2427"
    def normalize(value)
      "druid:#{bare(value)}"
    end

    # @return [String] e.g. "bc641kr2427"
    def bare(value)
      match = PATTERN.match(value.to_s.strip.downcase)
      raise UsageError, "Not a valid druid: #{value.inspect}" unless match

      match.captures.join
    end

    # @return [String] e.g. "bc/641/kr/2427/bc641kr2427"
    def tree(value)
      parts = PATTERN.match(value.to_s.strip.downcase)&.captures
      raise UsageError, "Not a valid druid: #{value.inspect}" unless parts

      [*parts, parts.join].join('/')
    end

    # @return [String] the druid's workspace content directory on SDR servers
    def workspace_content_dir(value)
      File.join(WORKSPACE_ROOT, tree(value), 'content')
    end
  end
end
