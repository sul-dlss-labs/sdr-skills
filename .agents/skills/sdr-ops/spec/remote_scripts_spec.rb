# frozen_string_literal: true

require 'spec_helper'
require 'jwt'
require 'active_support/core_ext/enumerable'

# The remote scripts run inside DSA (`bin/rails runner`) or a robot app's bundle. These specs load them with
# stand-ins for the server-side constants they use.
RSpec.describe 'remote scripts' do # rubocop:disable RSpec/DescribeClass
  def run_script(name, env)
    script = File.join(SdrOps::REMOTE_DIR, name)
    original = env.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    env.each { |key, value| ENV[key] = value }
    out = StringIO.new
    $stdout = out
    $stderr = StringIO.new
    load script
    out.string
  ensure
    $stdout = STDOUT
    $stderr = STDERR
    original&.each { |key, value| ENV[key] = value }
  end

  def records(output, prefix)
    output.lines.select { it.start_with?(prefix) }.map { JSON.parse(it.delete_prefix(prefix)) }
  end

  describe 'mint_token.rb' do
    let(:secret) { 'not-the-real-secret' }

    before do
      stub_const('Settings', Struct.new(:dor).new(Struct.new(:hmac_secret).new(secret)))
    end

    it 'mints an HS256 token with sub and exp that DSA-style decoding accepts' do
      output = run_script('mint_token.rb', 'SDR_OPS_SUB' => 'jdoe', 'SDR_OPS_TTL' => '3600')
      result = records(output, 'SDR_OPS_RESULT ').first

      claims = JWT.decode(result['token'], secret, true, algorithm: 'HS256').first
      expect(claims).to include('sub' => 'jdoe', 'iss' => 'sdr-ops')
      expect(claims['exp'] - claims['iat']).to eq 3600
      expect(result['cocina_models_version']).to eq Cocina::Models::VERSION
    end

    it 'refuses long TTLs and odd subjects' do
      expect { run_script('mint_token.rb', 'SDR_OPS_SUB' => 'jdoe', 'SDR_OPS_TTL' => '86400') }.to raise_error(SystemExit)
      expect { run_script('mint_token.rb', 'SDR_OPS_SUB' => 'x; rm', 'SDR_OPS_TTL' => '3600') }.to raise_error(SystemExit)
    end
  end

  describe 'mint_stacks_token.rb' do
    let(:secret) { 'not-the-real-secret' }

    def settings(value) = Struct.new(:service_token).new(Struct.new(:hmac_secret).new(value))

    it "mints an HS256 service token with an expiry, signed with stacks' service token secret" do
      stub_const('Settings', settings(secret))
      output = run_script('mint_stacks_token.rb', 'SDR_OPS_SUB' => 'jdoe', 'SDR_OPS_TTL' => '3600')
      result = records(output, 'SDR_OPS_RESULT ').first

      claims = JWT.decode(result['token'], secret, true, algorithm: 'HS256').first
      expect(claims).to include('sub' => 'jdoe', 'iss' => 'sdr-ops')
      expect(claims['exp'] - claims['iat']).to eq 3600
    end

    it 'refuses when stacks has no service token secret, without printing anything secret' do
      stub_const('Settings', settings(nil))
      expect { run_script('mint_stacks_token.rb', 'SDR_OPS_SUB' => 'jdoe', 'SDR_OPS_TTL' => '3600') }
        .to raise_error(SystemExit)
    end
  end

  describe 'find.rb' do
    let(:solr_calls) { [] }
    let(:docs) do
      [{ 'id' => 'druid:bc641kr2427', 'display_title_ss' => 'Railways',
         'wf_error_ssim' => ['gisDerivativeWF:create-derivatives:not a valid UTF-8 string'] },
       { 'id' => 'druid:bb330wn5590', 'display_title_ss' => 'Municipios', 'wf_error_ssim' => ['other:thing:boom'] }]
    end

    before do
      calls = solr_calls
      solr_docs = docs
      stub_const('SolrService', Class.new do
        define_singleton_method(:get) do |query, args|
          calls << [query, args]
          { 'response' => { 'docs' => solr_docs }, 'nextCursorMark' => args[:cursorMark] }
        end
      end)
      writes_prevented = []
      stub_const('ActiveRecord::Base', Class.new do
        define_singleton_method(:while_preventing_writes) do |&block|
          writes_prevented << true
          block.call
        end
        define_singleton_method(:writes_prevented) { writes_prevented }
      end)
    end

    it 'filters Solr with term queries, inside write prevention, and matches error text' do
      params = { source: 'solr', workflow: 'gisDerivativeWF', step: 'create-derivatives', status: 'error',
                 content_type: 'geo', collection: 'druid:nz187ct8959', facets: {}, error_match: 'UTF-8',
                 fields: %w[display_title_ss] }
      output = run_script('find.rb', 'SDR_OPS_FIND' => JSON.generate(params))

      _query, args = solr_calls.first
      expect(args[:fq]).to eq ['{!term f=content_type_ssimdv}geo',
                               '{!term f=wf_wps_ssimdv}gisDerivativeWF:create-derivatives:error',
                               '{!term f=member_of_collection_ssim}druid:nz187ct8959']
      expect(args[:fl]).to eq 'id,display_title_ss,wf_error_ssim'
      expect(records(output, 'SDR_OPS_ROW ')).to eq [{ 'druid' => 'bc641kr2427', 'display_title_ss' => 'Railways' }]
      expect(ActiveRecord::Base.writes_prevented).to eq [true]
    end

    it 'reads the workflow table and joins titles from Solr' do
      step = Struct.new(:druid, :version, :workflow, :process, :status, :error_msg, :updated_at)
                   .new('druid:bc641kr2427', 2, 'gisDerivativeWF', 'create-derivatives', 'error', 'not a valid UTF-8 string', nil)
      relation = Class.new do
        define_method(:initialize) { |rows| @rows = rows }
        define_method(:where) { |**| self }
        define_method(:to_a) { @rows }
      end
      stub_const('WorkflowStep', Class.new { define_singleton_method(:where) { |**| relation.new([step]) } })
      params = { source: 'workflows', workflow: 'gisDerivativeWF', step: 'create-derivatives', status: 'error',
                 error_match: 'UTF-8', facets: {}, fields: %w[display_title_ss] }
      output = run_script('find.rb', 'SDR_OPS_FIND' => JSON.generate(params))

      expect(records(output, 'SDR_OPS_ROW ').first)
        .to include('druid' => 'bc641kr2427', 'version' => 2, 'error_message' => 'not a valid UTF-8 string',
                    'display_title_ss' => 'Railways')
      expect(solr_calls.first.last[:fq]).to eq ['{!terms f=id}druid:bc641kr2427']
    end
  end

  describe 'fetch_preserved.rb' do
    it 'refuses to boot without a ROBOT_ENVIRONMENT from the login profile' do
      expect { run_script('fetch_preserved.rb', 'ROBOT_ENVIRONMENT' => '') }.to raise_error(SystemExit)
    end

    it 'downloads into the scratch directory through the configured preservation client' do
      app = File.join(@tmpdir, 'app')
      FileUtils.mkdir_p(File.join(app, 'config'))
      File.write(File.join(app, 'config', 'boot.rb'), '# stands in for the robot app boot')
      downloads = []
      objects = Object.new
      objects.define_singleton_method(:content_to_file) do |**args|
        downloads << args
        File.write(args[:destination_filepath], 'bytes')
      end
      client = Class.new do
        define_singleton_method(:configure) { |**| nil }
        define_singleton_method(:objects) { objects }
      end
      stub_const('Preservation::Client', client)
      stub_const('Settings', Struct.new(:preservation_catalog).new(Struct.new(:url, :token).new('https://pres', 't')))
      dest = "/tmp/sdr-ops-spec-#{SecureRandom.hex(4)}"
      request = { druid: 'druid:bc641kr2427', version: nil, dest:, files: [{ filepath: 'rail.dbf', md5: 'abc' }] }

      output = Dir.chdir(app) do
        run_script('fetch_preserved.rb', 'ROBOT_ENVIRONMENT' => 'production', 'SDR_OPS_FETCH' => JSON.generate(request))
      end

      expect(downloads.first).to include(druid: 'druid:bc641kr2427', filepath: 'rail.dbf', expected_md5: 'abc',
                                         destination_filepath: "#{dest}/rail.dbf")
      expect(records(output, 'SDR_OPS_ROW ').first).to include('filepath' => 'rail.dbf', 'size' => 5)
    ensure
      FileUtils.rm_rf(dest) if dest
    end
  end
end
