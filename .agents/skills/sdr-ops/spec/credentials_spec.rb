# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SdrOps::Credentials do
  def jwt(claims)
    encode = ->(hash) { Base64.urlsafe_encode64(JSON.generate(hash), padding: false) }
    "#{encode.call(alg: 'HS256')}.#{encode.call(claims)}.c2lnbmF0dXJl"
  end

  let(:environment) { SdrOps.environment('stage') }
  let(:keychain) do
    Class.new do
      attr_reader :store_calls

      def initialize = (@store_calls = [])
      def store(service, account, secret) = (@store_calls << [service, account]) && (@secret = secret)
      def fetch(_service) = @secret
      def delete(_service) = (@secret = nil)
    end.new
  end
  let(:credentials) { described_class.new(environment:, keychain:, state_dir: File.join(@tmpdir, 'state')) }
  let(:token) { jwt(sub: 'jdoe', exp: Time.now.to_i + 3600) }
  let(:transport) do
    FakeTransport.new.tap { |t| t.script_results = [{ 'token' => token, 'cocina_models_version' => Cocina::Models::VERSION }] }
  end

  it 'parses TTLs within bounds' do
    expect(described_class.parse_ttl('8h')).to eq 28_800
    expect(described_class.parse_ttl('90m')).to eq 5400
    expect { described_class.parse_ttl('13h') }.to raise_error(SdrOps::UsageError)
    expect { described_class.parse_ttl('1m') }.to raise_error(SdrOps::UsageError)
  end

  it 'mints a token on the DSA host, stores it in the keychain, and never reports it' do
    summary = credentials.login(sunet: 'jdoe', transport:, ttl: 3600)

    expect(transport.scripts.first).to eq(profile: :dsa, script: 'mint_token.rb',
                                          env: { 'SDR_OPS_SUB' => 'jdoe', 'SDR_OPS_TTL' => 3600 })
    expect(keychain.store_calls).to eq [%w[sdr-ops-stage-dsa jdoe]]
    expect(credentials.token!).to eq token
    expect(JSON.generate(summary)).not_to include(token)
    expect(File.read(File.join(@tmpdir, 'state', 'stage.json'))).not_to include(token)
    expect(summary).to include(sub: 'jdoe', expired: false)
  end

  it 'rejects tokens minted for someone else' do
    transport.script_results = [{ 'token' => jwt(sub: 'someone', exp: Time.now.to_i + 3600) }]
    expect { credentials.login(sunet: 'jdoe', transport:) }.to raise_error(SdrOps::RemoteError, /unexpected claims/)
  end

  it 'fails fast when the token is missing or expired' do
    expect { credentials.token! }.to raise_error(SdrOps::AuthError, /Not logged in/)
    keychain.store('sdr-ops-stage-dsa', 'jdoe', jwt(sub: 'jdoe', exp: Time.now.to_i - 10))
    expect { credentials.token! }.to raise_error(SdrOps::AuthError, /expired/)
  end

  describe 'stacks service tokens' do
    let(:keychain) do
      Class.new do
        attr_reader :store_calls

        def initialize = (@store_calls = []) && (@secrets = {})
        def store(service, account, secret) = (@store_calls << [service, account]) && (@secrets[service] = secret)
        def fetch(service) = @secrets[service]
        def delete(service) = @secrets.delete(service)
      end.new
    end

    it 'mints one on the stacks host and keeps it apart from the DSA token' do
      credentials.login(sunet: 'jdoe', transport:)
      stacks = jwt(sub: 'jdoe', exp: Time.now.to_i + 3600)
      transport.script_results = [{ 'token' => stacks }]
      summary = credentials.login_stacks(sunet: 'jdoe', transport:, ttl: 3600)

      expect(transport.scripts.last).to eq(profile: :stacks, script: 'mint_stacks_token.rb',
                                           env: { 'SDR_OPS_SUB' => 'jdoe', 'SDR_OPS_TTL' => 3600 })
      expect(keychain.store_calls.last).to eq %w[sdr-ops-stage-stacks jdoe]
      expect(credentials.stacks_token!).to eq stacks
      expect(credentials.token!).to eq token
      expect(summary).to include(sub: 'jdoe', expired: false, stacks_expires_at: a_string_matching(/\A\d{4}-/))
      expect(credentials.state['dsa_cocina_models_version']).to eq Cocina::Models::VERSION
      expect(JSON.generate(summary) + File.read(File.join(@tmpdir, 'state', 'stage.json'))).not_to include(stacks)
    end

    it 'says how to get one when it is missing or expired' do
      expect { credentials.stacks_token! }.to raise_error(SdrOps::AuthError, /No stage stacks token: run .*login --stacks/)
      keychain.store('sdr-ops-stage-stacks', 'jdoe', jwt(sub: 'jdoe', exp: Time.now.to_i - 10))
      expect { credentials.stacks_token! }.to raise_error(SdrOps::AuthError, /stacks token has expired/)
    end

    it 'logs out of both' do
      keychain.store('sdr-ops-stage-dsa', 'jdoe', token)
      keychain.store('sdr-ops-stage-stacks', 'jdoe', token)
      credentials.logout
      expect([keychain.fetch('sdr-ops-stage-dsa'), keychain.fetch('sdr-ops-stage-stacks')]).to eq [nil, nil]
    end
  end

  it 'detects cocina-models drift from the version DSA reported at login' do
    transport.script_results = [{ 'token' => token, 'cocina_models_version' => '0.1.0' }]
    credentials.login(sunet: 'jdoe', transport:)
    expect(credentials.cocina_drift?).to be true
  end

  describe SdrOps::Keychain::MacOS do
    it 'passes the secret on stdin, not as an argument' do
      shell = FakeShell.new
      described_class.new(shell).store('sdr-ops-stage-dsa', 'jdoe', token)
      add = shell.calls.last
      expect(add[:argv]).to eq %w[security -i]
      expect(add[:stdin]).to include("-w #{token}")
      expect(shell.calls.flat_map { it[:argv] }).not_to include(token)
    end
  end
end
