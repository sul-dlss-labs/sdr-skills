# frozen_string_literal: true

require 'tmpdir'
require 'webmock/rspec'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'sdr_ops'

Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |file| require file }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  config.include CocinaHelpers
  config.include ContextHelpers

  config.around do |example|
    Dir.mktmpdir('sdr-ops-spec') do |dir|
      @tmpdir = dir
      example.run
    end
  end
end
