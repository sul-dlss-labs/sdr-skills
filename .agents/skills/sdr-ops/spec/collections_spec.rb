# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SdrOps::Collections do
  let(:druid) { CocinaHelpers::DRUID }
  let(:dsa) { FakeDsa.new.add(build_dro) }
  let(:context) { build_context(dsa:, execute: true, reason: 'Move to census collection') }

  it 'adds and removes membership inside a version the run opened' do
    context.versions.open(druid, description: 'Update collections') do |state|
      context.collections.add(druid, 'fd953pg7906')
      context.collections.remove(druid, CocinaHelpers::COLLECTION)
      expect(state.cocina.structural.isMemberOf).to eq ['druid:fd953pg7906']
    end
    expect(dsa.calls_for(:update).last.last[:description]).to eq 'Move to census collection'
  end

  it 'skips no-op changes' do
    expect do
      context.versions.open(druid, description: 'x') { context.collections.add(druid, CocinaHelpers::COLLECTION) }
    end.to raise_error(SdrOps::Skip, /already in/)
  end

  it 'needs a version this run opened' do
    expect { context.collections.add(druid, 'fd953pg7906') }.to raise_error(SdrOps::Skip, /no open version/)
  end
end
