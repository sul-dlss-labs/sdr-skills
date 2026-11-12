# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SdrOps::Cloner do
  let(:source_druid) { 'druid:bb330wn5590' }
  let(:apo) { 'rz685py5647' }
  let(:dsa) { FakeDsa.new }
  let(:transport) { FakeTransport.new }
  let(:prod_transport) { FakeTransport.new }
  let(:execute) { true }
  let(:context) { build_context(dsa:, transport:, execute:, transports: { 'prod' => prod_transport }) }
  let(:world) { { view: 'world', download: 'world' } }
  # Three file sets like the real object: Data, Preview, Metadata. One stanford-only preserved file (preservation)
  # and, optionally, one stanford-only unpreserved derivative (unavailable).
  let(:extra_files) { [] }
  let(:source) do
    bare = source_druid.delete_prefix('druid:')
    fs = lambda do |n, label, type, files|
      { type: Cocina::Models::FileSetType.public_send(type), externalIdentifier: "#{bare}_#{n}", label:, version: 5,
        structural: { contains: files } }
    end
    dro = build_dro(druid: source_druid, version: 5, file_sets: [
                      fs.call(1, 'Data', :object, [file_hash('rail.shp', mimetype: 'application/vnd.shp', **world),
                                                   file_hash('rail.dbf', mimetype: 'application/vnd.dbf')]),
                      fs.call(2, 'Preview', :preview, [file_hash('preview.jpg', mimetype: 'image/jpeg', **world)]),
                      fs.call(3, 'Metadata', :object, [file_hash('rail.shp.xml', mimetype: 'application/xml', **world),
                                                       *extra_files])
                    ])
    JSON.parse(Cocina::Models.without_metadata(dro).to_json)
  end

  before do
    stub_request(:get, 'https://purl.stanford.edu/bb330wn5590.json').to_return(body: source.to_json)
    %w[rail.shp preview.jpg rail.shp.xml].each do |name|
      stub_request(:get, "https://stacks.stanford.edu/file/bb330wn5590/#{name}").to_return(body: name)
    end
    prod_transport.script_results = [{ 'filepath' => 'rail.dbf', 'path' => '/tmp/sdr-ops-jdoe-run/fetch-x/rail.dbf' }]
    prod_transport.downloads['/tmp/sdr-ops-jdoe-run/fetch-x/rail.dbf'] = 'rail.dbf'
  end

  def clone(**)
    context.cloner.clone_from(source_druid, apo:, **)
  end

  context 'when dry run' do
    let(:execute) { false }

    it 'shows the plan and validates the registration without downloading or creating anything' do
      expect(clone).to be_nil

      plan = emitted.find { it['action'] == 'clone.plan' }['details']
      layout = plan['layout'].map { it.values_at('label', 'type') }
      expect(layout).to eq [%w[Data object], %w[Preview preview], %w[Metadata object]]
      expect(plan['files'].to_h { it.values_at('filename', 'via') })
        .to eq('rail.shp' => 'stacks', 'rail.dbf' => 'preservation', 'preview.jpg' => 'stacks', 'rail.shp.xml' => 'stacks')
      expect(emitted.find { it['action'] == 'object.register' }['result']).to eq 'planned'
      expect(dsa.calls).to be_empty
      expect(a_request(:get, /stacks.stanford.edu/)).not_to have_been_made
    end
  end

  it 'recreates the layout, attributes, and bytes in one update, then accessions version 1' do
    clone_druid = clone(tags: ['Project : sdr-ops testing'])

    request = dsa.calls_for(:register).first.last[:request]
    expect(request.type).to eq Cocina::Models::ObjectType.geo
    expect(request.description.title.first.value).to eq 'Railways: China, 2010'
    expect(request.access.view).to eq 'stanford'
    expect(dsa.calls_for(:tags_create).first.last[:tags])
      .to eq ['Registered By : jdoe', 'sdr-ops : clone of prod druid:bb330wn5590', 'Project : sdr-ops testing']

    content = SdrOps::Druid.workspace_content_dir(clone_druid)
    expected_paths = %w[rail.shp rail.dbf preview.jpg rail.shp.xml].map { "#{content}/#{it}" }
    expect(transport.puts.map { it[:remote_path] }).to match_array(expected_paths)
    expect(prod_transport.scripts.first).to include(script: 'fetch_preserved.rb')
    expect(JSON.parse(prod_transport.scripts.first[:env]['SDR_OPS_FETCH'])['version']).to eq 5

    updates = dsa.calls_for(:update)
    expect(updates.size).to eq 1
    file_sets = updates.first.last[:cocina].structural.contains
    expect(file_sets.map { [it.label, it.type.split('/').last, it.structural.contains.map(&:filename)] })
      .to eq [['Data', 'object', %w[rail.shp rail.dbf]], ['Preview', 'preview', ['preview.jpg']],
              ['Metadata', 'object', ['rail.shp.xml']]]
    dbf = file_sets.first.structural.contains.last
    expect(dbf.externalIdentifier).to start_with("https://cocina.sul.stanford.edu/file/#{SdrOps::Druid.bare(clone_druid)}-")
    expect(dbf.access.view).to eq 'stanford'
    expect(updates.first.last[:description]).to eq 'Clone of prod druid:bb330wn5590'
    expect(dsa.calls_for(:close).size).to eq 1
  end

  it 'leaves version 1 open with keep_open' do
    clone(keep_open: true)
    expect(dsa.calls_for(:close)).to be_empty
  end

  it 'checks every download and creates nothing if one is wrong' do
    stub_request(:get, 'https://stacks.stanford.edu/file/bb330wn5590/preview.jpg').to_return(body: 'corrupt')
    expect { clone }.to raise_error(SdrOps::Error, /preview.jpg: downloaded/)
    expect(dsa.calls_for(:register)).to be_empty
  end

  context 'when a file is neither preserved nor world-downloadable' do
    let(:extra_files) { [file_hash('rail-fgdc.xml', mimetype: 'application/xml', use: 'derivative', preserve: false)] }

    it 'stops unless told to leave it out' do
      expect { clone }.to raise_error(SdrOps::Skip, /can't fetch rail-fgdc.xml/)

      clone(skip_unavailable: true)
      filenames = all_files(dsa.calls_for(:update).first.last[:cocina]).map(&:filename)
      expect(filenames).not_to include('rail-fgdc.xml')
    end
  end

  it 'only creates clones in stage or qa, from a different environment' do
    prod = build_context(dsa:, env: 'prod')
    expect { prod.cloner.clone_from(source_druid, apo:) }.to raise_error(SdrOps::UsageError, /not prod/)
    expect { clone(from: 'stage') }.to raise_error(SdrOps::UsageError, /must differ/)
  end

  it 'tells you to use the DSA source for objects that are not published' do
    stub_request(:get, 'https://purl.stanford.edu/bb330wn5590.json').to_return(status: 404)
    expect { clone }.to raise_error(SdrOps::Skip, /--source dsa/)
  end
end
