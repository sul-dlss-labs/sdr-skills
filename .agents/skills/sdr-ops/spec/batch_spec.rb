# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SdrOps::Batch do
  let(:dsa) { FakeDsa.new }
  let(:context) { build_context(dsa:, limit:, max_failures: 2) }
  let(:limit) { nil }
  let(:druids) { %w[bc641kr2427 bb330wn5590 bp688xp0355 bt034gr2053] }

  describe '.read' do
    it 'reads Argo-style CSVs (Druid column), sdr-ops find CSVs, and plain lists' do
      argo = File.join(@tmpdir, 'argo.csv')
      File.write(argo, "Druid,Title\nbc641kr2427,Railways\n")
      expect(described_class.read(argo)).to eq [{ 'druid' => 'druid:bc641kr2427', 'Druid' => 'bc641kr2427',
                                                  'Title' => 'Railways' }]

      list = File.join(@tmpdir, 'list.txt')
      File.write(list, "# affected\nbc641kr2427\n\ndruid:bb330wn5590\n")
      expect(described_class.read(list).map { it['druid'] }).to eq %w[druid:bc641kr2427 druid:bb330wn5590]
    end

    it 'rejects CSVs without a druid column and invalid druids' do
      path = File.join(@tmpdir, 'bad.csv')
      File.write(path, "title\nx\n")
      expect { described_class.read(path) }.to raise_error(SdrOps::UsageError, /no druid column/)
      expect { described_class.read(['not-a-druid']) }.to raise_error(SdrOps::UsageError)
    end
  end

  describe '#run' do
    it 'counts outcomes, and skipped items are not failures' do
      outcomes = { 'druid:bc641kr2427' => SdrOps::Skip.new('nope'), 'druid:bb330wn5590' => nil }
      summary = described_class.new(context).run(druids.first(2)) do |row, _ctx|
        error = outcomes[row['druid']]
        raise error if error
      end
      expect(summary[:batch]).to include(total: 2, ok: 1, skipped: 1)
    end

    it 'stops after consecutive errors' do
      seen = []
      summary = described_class.new(context).run(druids) do |row, _ctx|
        seen << row['druid']
        raise 'boom'
      end
      expect(seen.size).to eq 2
      expect(summary[:batch]).to include(error: 2, aborted: 1)
    end

    context 'with a limit' do
      let(:limit) { 1 }

      it 'only processes the first N' do
        seen = []
        described_class.new(context).run(druids) { |row, _| seen << row['druid'] }
        expect(seen).to eq ['druid:bc641kr2427']
      end
    end
  end
end
