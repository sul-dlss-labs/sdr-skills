# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'sdr-ops basics' do
  describe SdrOps::Druid do
    it 'normalizes druids and builds workspace paths' do
      expect(described_class.normalize('BC641KR2427')).to eq 'druid:bc641kr2427'
      expect(described_class.workspace_content_dir('druid:bc641kr2427')).to eq '/dor/workspace/bc/641/kr/2427/bc641kr2427/content'
      expect { described_class.normalize('bc641kr242') }.to raise_error(SdrOps::UsageError)
    end
  end

  describe SdrOps::Ledger do
    it "only treats real (not dry-run) opens in this environment as the run's own versions" do
      ledger = described_class.new(path: File.join(@tmpdir, 'ledger.jsonl'), run_id: 'r', env: 'stage', as: 'jdoe')
      ledger.record(druid: 'druid:bc641kr2427', action: 'version.open', result: 'ok', dry_run: false, after: { version: 3 })
      ledger.record(druid: 'druid:bc641kr2427', action: 'version.open', result: 'planned', dry_run: true, after: { version: 4 })
      other = described_class.new(path: ledger.path, run_id: 'r', env: 'prod', as: 'jdoe')
      expect(ledger.opened_versions('druid:bc641kr2427')).to eq [3]
      expect(other.opened_versions('druid:bc641kr2427')).to eq []
    end
  end

  describe SdrOps::Inspect do
    it 'summarizes status, including who opened the version' do
      dsa = FakeDsa.new.add(build_dro(version: 2), open: true, description: 'Regenerate derivatives',
                                                   events: [FakeDsa.new.event('version_open', who: 'asmith', version: '2')])
      status = build_context(dsa:).read.status('bc641kr2427')
      expect(status).to include(version: 2, open: true, opened_by: 'asmith', opened_by_this_run: false,
                                collections: ['druid:nz187ct8959'], title: 'Railways: China, 2010')
    end
  end

  describe 'remote scripts' do
    it 'are valid Ruby' do
      Dir[File.join(SdrOps::REMOTE_DIR, '*.rb')].each do |script|
        _out, err, status = Open3.capture3(RbConfig.ruby, '-c', script)
        expect(status).to be_success, "#{script}: #{err}"
      end
    end
  end

  it 'never needs a token in a dry run of a script-free command when a client is injected' do
    expect { build_context(dsa: FakeDsa.new).client }.not_to raise_error
  end
end
