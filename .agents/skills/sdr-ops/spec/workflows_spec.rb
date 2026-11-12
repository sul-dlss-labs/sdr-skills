# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SdrOps::Workflows do
  let(:druid) { CocinaHelpers::DRUID }
  let(:open) { true }
  let(:steps) do
    [{ name: 'fetch-files', status: 'completed', version: 2 },
     { name: 'create-derivatives', status: 'error', version: 2, error: 'not a valid UTF-8 string' },
     { name: 'start-accession-workflow', status: 'waiting', version: 2 }]
  end
  let(:dsa) do
    workflows = { 'gisDerivativeWF' => FakeDsa.workflow_xml(druid, 'gisDerivativeWF', steps) }
    events = [FakeDsa.new.event('version_open', who: 'asmith', version: '2')]
    FakeDsa.new.add(build_dro(version: 2), open:, description: 'Regenerate derivatives', workflows:, events:)
  end
  let(:execute) { true }
  let(:context) { build_context(dsa:, execute:, ticket: 'gis-robot-suite#1134') }

  describe '#run' do
    it 'creates the workflow for the current version, showing whose version it runs in' do
      context.workflows.run(druid, 'gisDerivativeWF', lane: 'low')

      expect(dsa.calls_for(:workflow_create).first.last).to eq(workflow: 'gisDerivativeWF', version: 2, lane_id: 'low')
      expect(emitted.last['details']).to include('version_description' => 'Regenerate derivatives', 'opened_by' => 'asmith')
    end

    context 'when the version is closed' do
      let(:open) { false }

      it 'refuses workflows that need an open version' do
        expect { context.workflows.run(druid, 'gisDerivativeWF') }.to raise_error(SdrOps::Skip, /needs version 2/)
      end
    end

    it 'points accessionWF at version close' do
      expect { context.workflows.run(druid, 'accessionWF') }.to raise_error(SdrOps::UsageError, /version close/)
    end
  end

  describe '#set and #reset' do
    it 'resets an errored step, guarded on its current status, with an attribution note' do
      context.workflows.reset(druid, 'gisDerivativeWF', 'create-derivatives')

      update = dsa.calls_for(:process_update).first.last
      expect(update).to include(step: 'create-derivatives', status: 'waiting', current_status: 'error')
      expect(update[:note]).to eq 'set create-derivatives to waiting by jdoe via sdr-ops; gis-robot-suite#1134'
    end

    it 'defaults the expected status to what it read, and skips when the step changed underneath' do
      context.workflows.set(druid, 'gisDerivativeWF', 'fetch-files', 'waiting')
      expect(dsa.calls_for(:process_update).first.last[:current_status]).to eq 'completed'

      expect { context.workflows.set(druid, 'gisDerivativeWF', 'fetch-files', 'waiting', expect: 'error') }
        .to raise_error(SdrOps::Skip, /no longer "error"/)
    end

    it 'skips steps that do not exist' do
      expect do
        context.workflows.set(druid, 'gisDerivativeWF', 'nope', 'waiting')
      end.to raise_error(SdrOps::Skip, /no gisDerivativeWF:nope/)
    end

    it 'rejects invalid statuses' do
      expect { context.workflows.set(druid, 'gisDerivativeWF', 'fetch-files', 'done') }.to raise_error(SdrOps::UsageError)
    end
  end

  describe '#skip_all' do
    it 'requires a note and attributes it' do
      expect { context.workflows.skip_all(druid, 'gisDerivativeWF', note: '') }.to raise_error(SdrOps::UsageError)

      context.workflows.skip_all(druid, 'gisDerivativeWF', note: 'derivatives not needed')
      expect(dsa.calls_for(:skip_all).first.last[:note])
        .to eq 'skipped all steps by jdoe via sdr-ops; derivatives not needed; gis-robot-suite#1134'
    end

    it 'does nothing in a dry run' do
      build_context(dsa:).workflows.skip_all(druid, 'gisDerivativeWF', note: 'x')
      expect(dsa.calls_for(:skip_all)).to be_empty
    end
  end

  describe '#check' do
    it 'reports an errored workflow with its message' do
      expect(context.workflows.check(druid, 'gisDerivativeWF:complete'))
        .to include(state: 'error', step: 'create-derivatives', error_message: 'not a valid UTF-8 string')
    end

    it 'reports a completed step, and pending for workflows not started' do
      expect(context.workflows.check(druid, 'gisDerivativeWF:fetch-files:complete')).to include(state: 'complete')
      expect(context.workflows.check(druid, 'accessionWF:complete')).to include(state: 'pending')
    end

    it 'rejects malformed conditions' do
      expect { context.workflows.check(druid, 'gisDerivativeWF') }.to raise_error(SdrOps::UsageError)
    end
  end
end
