# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SdrOps::Descriptive do
  let(:druid) { CocinaHelpers::DRUID }
  let(:dsa) { FakeDsa.new.add(build_dro) }
  let(:execute) { false }
  let(:context) { build_context(dsa:, execute:, reason: 'Trim title') }

  def trim_title
    context.descriptive.update(druid) { |description| description[:title].each { it[:value] = it[:value].strip } }
  end

  before do
    dro = dsa.record(druid).cocina
    titled = dro.new(description: dro.description.new(title: [{ value: 'Railways ' }]))
    dsa.record(druid).cocina = titled
  end

  it 'refuses outside a version this run opened' do
    expect { trim_title }.to raise_error(SdrOps::Skip, /no open version/)
  end

  it 'plans the change in a dry run, reporting the changed fields' do
    context.versions.open(druid, description: 'Trim title') { trim_title }

    row = emitted.find { it['action'] == 'description.update' }
    expect(row).to include('result' => 'planned')
    expect(row['details']['changes']).to eq('title[0].value' => ['Railways ', 'Railways'])
    expect(dsa.calls_for(:update)).to be_empty
  end

  context 'when executing' do
    let(:execute) { true }

    it 'saves the edited description with the user and description' do
      context.versions.open(druid, description: 'Trim title') { trim_title }

      update = dsa.calls_for(:update).first.last
      expect(update).to include(user_name: 'jdoe', description: 'Trim title')
      expect(update[:cocina].description.title.first.value).to eq 'Railways'
    end
  end

  it 'skips when the block changes nothing, and refuses invalid descriptions' do
    context.versions.open(druid, description: 'Trim title', keep_open: true)
    expect { context.descriptive.update(druid) { nil } }.to raise_error(SdrOps::Skip, /wouldn't change/)
    expect { context.descriptive.update(druid) { it.merge(title: [{ bogus: 1 }]) } }.to raise_error(SdrOps::UsageError)
  end
end
