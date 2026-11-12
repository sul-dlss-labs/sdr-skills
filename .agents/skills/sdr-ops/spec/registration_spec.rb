# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SdrOps::Registration do
  let(:dsa) { FakeDsa.new }
  let(:execute) { true }
  let(:context) { build_context(dsa:, execute:) }
  let(:apo) { 'rz685py5647' }

  def register(**)
    context.registration.register(title: 'sdr-ops test object', apo:, **)
  end

  context 'when dry run' do
    let(:execute) { false }

    it 'plans the request, tags, and workflow without calling DSA' do
      expect(register(type: 'geo', collection: 'nz187ct8959', tags: ['Project : sdr-ops testing'])).to be_nil

      row = emitted.last
      expect(row).to include('action' => 'object.register', 'result' => 'planned')
      expect(row['args']['source_id']).to match(/\Asdr-ops:jdoe-\d{8}T\d{6}\z/)
      expect(row['args']['tags']).to eq ['Registered By : jdoe', 'Project : sdr-ops testing']
      request = row['details']['request']
      expect(request).to include('type' => Cocina::Models::ObjectType.geo, 'version' => 1)
      expect(request['administrative']).to eq('hasAdminPolicy' => 'druid:rz685py5647')
      expect(request['structural']['isMemberOf']).to eq ['druid:nz187ct8959']
      expect(dsa.calls).to be_empty
    end
  end

  it 'registers like Argo does: user name, Registered By tag, registrationWF for version 1' do
    druid = register(source_id: 'sdr-ops:test-1')

    expect(dsa.calls_for(:register).first.last).to include(user_name: 'jdoe')
    expect(dsa.calls_for(:register).first.last[:request].identification.sourceId).to eq 'sdr-ops:test-1'
    expect(dsa.calls_for(:tags_create).first.last).to eq(tags: ['Registered By : jdoe'])
    expect(dsa.calls_for(:workflow_create).first.last).to eq(workflow: 'registrationWF', version: 1, lane_id: 'default')
    expect(dsa.calls_for(:close)).to be_empty
    expect(context.ledger.opened_versions(druid)).to eq [1]
  end

  it "owns the new object's version 1, so files can be added before accessioning" do
    druid = register
    context.files.add(druid, filename: 'readme.txt', content: 'hi', new_file_set: 'Files', preserve: true,
                             shelve: true, publish: true)
    context.versions.close(druid)

    expect(all_files(dsa.record(druid).cocina).map(&:filename)).to eq ['readme.txt']
    expect(dsa.calls_for(:close).size).to eq 1
  end

  it 'closes version 1 straight away with accession: true, attributing version 1 to the registrant' do
    register(accession: true)

    expect(dsa.calls_for(:close).first.last).to include(user_name: 'jdoe', start_accession: true)
    expect(emitted.last['details']).to eq('opened_by' => 'jdoe')
  end

  it 'registers with a full description and geographic metadata (e.g. copied from another object)' do
    description = { title: [{ value: 'Municipal Boundaries' }], note: [{ value: 'copied' }],
                    language: [{ code: 'por', source: { code: 'iso639-2b' } }] }
    register_with = context.registration.register(apo:, description:, geographic: { iso19139: '<rdf:RDF/>' }, type: 'geo')
    request = dsa.calls_for(:register).first.last[:request]
    expect(request.description.note.first.value).to eq 'copied'
    expect(request.geographic.iso19139).to eq '<rdf:RDF/>'
    expect(register_with).to start_with('druid:')
  end

  it 'rejects unknown types, missing titles, and invalid access' do
    expect { register(type: 'collection') }.to raise_error(SdrOps::UsageError, /--type must be one of/)
    expect { context.registration.register(title: ' ', apo:) }.to raise_error(SdrOps::UsageError, /title/)
    expect { register(view: 'everyone') }.to raise_error(SdrOps::UsageError, /--view must be one of/)
    expect { register(view: 'stanford', download: 'world') }.to raise_error(SdrOps::UsageError, /Invalid registration/)
  end
end
