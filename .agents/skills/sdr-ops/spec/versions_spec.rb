# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SdrOps::Versions do
  let(:dsa) { FakeDsa.new.add(build_dro) }
  let(:execute) { false }
  let(:context) { build_context(dsa:, execute:) }
  let(:druid) { CocinaHelpers::DRUID }

  describe '#adopt' do
    let(:dsa) do
      FakeDsa.new.add(build_dro(version: 3), open: true, description: 'Unzip data.zip',
                                             events: [FakeDsa.new.event('version_open', who: 'gis-robot-suite', version: '3')])
    end

    def adopt(**)
      context.versions.adopt(druid, opened_by: 'gis-robot-suite', description: /\AUnzip data\.zip/, **)
    end

    it 'refuses a version opened by someone else or with another description' do
      expect { context.versions.adopt(druid, opened_by: 'asmith', description: 'Unzip data.zip') }
        .to raise_error(SdrOps::Skip, /isn't the version to adopt/)
      expect { context.versions.adopt(druid, opened_by: 'gis-robot-suite', description: 'Unzip') }
        .to raise_error(SdrOps::Skip, /isn't the version to adopt/)
      expect { context.files.remove(druid, ['rail.shp']) }.to raise_error(SdrOps::OpenVersionExists)
    end

    context 'when dry run' do
      it 'plans the adoption, after which content changes are planned in that version' do
        adopt
        context.files.remove(druid, ['rail.shp'])

        expect(emitted.map { [it['action'], it['result']] }).to eq [%w[version.adopt planned], %w[files.remove planned]]
        expect(context.ledger.opened_versions(druid)).to be_empty
        expect(dsa.calls_for(:update)).to be_empty
      end
    end

    context 'when executing' do
      let(:execute) { true }

      it 'records the adoption, so a later pass recognises the version as its own' do
        adopt
        expect(context.ledger.opened_versions(druid)).to eq [3]
        expect(context.state(druid, refresh: true)).to be_own_version
        expect(adopt).to be_own_version # adopting again is a no-op
        expect(emitted.count { it['action'] == 'version.adopt' }).to eq 1
      end
    end
  end

  describe '#open' do
    context 'when dry run' do
      it 'plans the open without calling DSA, and later calls see the planned version' do
        context.versions.open(druid, description: 'Add code page file') do |state|
          expect(state.version).to eq 2
          expect(state).to be_own_version
        end

        expect(dsa.calls_for(:open)).to be_empty
        expect(dsa.calls_for(:close)).to be_empty
        expect(emitted.map { it['action'] }).to eq %w[version.open version.close]
        expect(emitted.map { it['result'] }).to all(eq 'planned')
      end
    end

    context 'when executing' do
      let(:execute) { true }

      it 'opens with the user name, records it in the ledger, and closes after the block' do
        context.versions.open(druid, description: 'Add code page file') { nil }

        expect(dsa.calls_for(:open).first.last).to eq(description: 'Add code page file', opening_user_name: 'jdoe')
        expect(dsa.calls_for(:close).first.last).to include(user_name: 'jdoe', start_accession: true)
        expect(context.ledger.opened_versions(druid)).to eq [2]
      end

      it 'leaves the version open with keep_open, and the run recognises it as its own' do
        context.versions.open(druid, description: 'Regenerate derivatives', keep_open: true) { nil }

        expect(dsa.calls_for(:close)).to be_empty
        expect(context.state(druid, refresh: true)).to be_own_version
      end

      it 'leaves the version open if the block raises' do
        expect { context.versions.open(druid, description: 'x') { raise 'boom' } }.to raise_error('boom')
        expect(dsa.calls_for(:close)).to be_empty
      end
    end

    context 'when the object already has an open version' do
      let(:dsa) do
        dro = build_dro(version: 3)
        FakeDsa.new.add(dro, open: true, description: 'Regenerate derivatives',
                             events: [FakeDsa.new.event('version_open', who: 'asmith', version: '3')])
      end

      it 'stops with the version, its description, and who opened it' do
        expect { context.versions.open(druid, description: 'Add code page file') }
          .to raise_error(SdrOps::OpenVersionExists) { |error|
            expect(error.message).to include('open version 3', 'Regenerate derivatives', 'asmith')
          }
      end
    end

    it 'skips objects that are not openable' do
      dsa.record(druid).openable = false
      expect { context.versions.open(druid, description: 'x') }.to raise_error(SdrOps::Skip, /isn't openable/)
    end

    it 'refuses changes when the bundle has a different cocina-models version from DSA' do
      context = build_context(dsa:, credentials: FakeCredentials.new(drift: true))
      expect { context.versions.open(druid, description: 'x') }.to raise_error(SdrOps::Error, /cocina-models/)
    end
  end

  describe '#close' do
    let(:execute) { true }
    let(:dsa) { FakeDsa.new.add(build_dro(version: 2), open: true, description: 'Fix things') }

    it 'closes an open version (whoever opened it) with optional parameters' do
      context.versions.close(druid, accession: false, user_versions: 'none', lane: 'low')

      expect(dsa.calls_for(:close).first.last)
        .to eq(user_name: 'jdoe', start_accession: false, user_versions: 'none', lane_id: 'low')
    end

    it 'skips when the object is not closeable' do
      dsa.record(druid).closeable = false
      expect { context.versions.close(druid) }.to raise_error(SdrOps::Skip, /can't be closed/)
    end

    it 'rejects unknown user-version modes' do
      expect { context.versions.close(druid, user_versions: 'bogus') }.to raise_error(SdrOps::UsageError)
    end
  end

  describe '#discard' do
    let(:dsa) do
      closed = build_dro(version: 1)
      dsa = FakeDsa.new.add(closed)
      dsa.object(druid).version.open(description: 'Experiment', opening_user_name: 'jdoe')
      record = dsa.record(druid)
      record.cocina = record.cocina.new(access: { view: 'world', download: 'world' })
      record.workflows['gisDerivativeWF'] =
        FakeDsa.workflow_xml(druid, 'gisDerivativeWF', [{ name: 'create-derivatives', status: 'error', version: 2 }])
      dsa
    end

    it 'shows what would be lost and which workflows discard leaves behind, without discarding' do
      context.versions.discard(druid)

      details = emitted.last['details']
      expect(details['would_lose']['sections_changed']).to include('access')
      expect(details['left_behind']).to eq [{ 'workflow' => 'gisDerivativeWF', 'incomplete_steps' => ['create-derivatives'] }]
      expect(dsa.calls_for(:discard)).to be_empty
    end

    it 'discards when executing' do
      build_context(dsa:, execute: true).versions.discard(druid)
      expect(dsa.calls_for(:discard).size).to eq 1
    end
  end
end
