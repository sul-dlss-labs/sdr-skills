# frozen_string_literal: true

require 'base64'
require 'csv'
require 'digest'
require 'erb'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'securerandom'
require 'shellwords'
require 'tempfile'
require 'time'

require 'cocina/models'
require 'cocina_display' # cocina-models' description validators use it but don't require it
require 'dor/services/client'

require_relative 'sdr_ops/errors'
require_relative 'sdr_ops/environments'
require_relative 'sdr_ops/druid'
require_relative 'sdr_ops/output'
require_relative 'sdr_ops/shell'
require_relative 'sdr_ops/ledger'
require_relative 'sdr_ops/transport'
require_relative 'sdr_ops/credentials'
require_relative 'sdr_ops/object_state'
require_relative 'sdr_ops/context'
require_relative 'sdr_ops/inspect'
require_relative 'sdr_ops/find'
require_relative 'sdr_ops/versions'
require_relative 'sdr_ops/workflows'
require_relative 'sdr_ops/files'
require_relative 'sdr_ops/collections'
require_relative 'sdr_ops/registration'
require_relative 'sdr_ops/batch'
require_relative 'sdr_ops/cli'

# Inspect and change objects in the Stanford Digital Repository.
# See SKILL.md for how agents use this, and DESIGN.md at the repository root for why it works this way.
module SdrOps
  SKILL_ROOT = File.expand_path('..', __dir__)
  REMOTE_DIR = File.join(SKILL_ROOT, 'remote')

  class << self
    attr_writer :context

    # The context set up by `sdr-ops run` for a generated script.
    def context
      @context || raise(UsageError, 'No sdr-ops context: run scripts with `sdr-ops --env ENV run SCRIPT.rb`')
    end

    # Process a batch of druids (a file path, an array of druids, or an array of row hashes).
    # Yields each row (a Hash with a normalized 'druid') and the context.
    def batch(input, &)
      Batch.new(context).run(input, &)
    end
  end
end
