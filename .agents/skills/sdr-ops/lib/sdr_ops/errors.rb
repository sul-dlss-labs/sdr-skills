# frozen_string_literal: true

module SdrOps
  class Error < StandardError; end

  # Bad command-line arguments or library usage.
  class UsageError < Error; end

  # Missing, expired, or mismatched credentials.
  class AuthError < Error; end

  # An ssh/remote-script failure.
  class RemoteError < Error; end

  # A precondition failed for one item; it is skipped and the batch continues.
  class Skip < Error; end

  # The object already has an open version that this run didn't open.
  class OpenVersionExists < Skip
    attr_reader :version, :description, :opened_by

    def initialize(druid:, version:, description:, opened_by:)
      @version = version
      @description = description
      @opened_by = opened_by
      super("#{druid} already has open version #{version} (#{description.inspect}, opened by #{opened_by || 'unknown'}). " \
            'sdr-ops only changes content in versions it opened in this run; resolve that version first ' \
            '(version close, version discard, or finish/skip its workflow).')
    end
  end
end
