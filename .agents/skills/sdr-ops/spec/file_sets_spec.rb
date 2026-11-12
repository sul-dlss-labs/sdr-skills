# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'File sets and moving files' do # rubocop:disable RSpec/DescribeClass
  let(:druid) { CocinaHelpers::DRUID }
  let(:execute) { false }
  let(:context) { build_context(dsa:, execute:) }
  # The layout of the problem geo objects: Data, Preview, Metadata.
  let(:dsa) do
    fs = lambda do |id, label, type, files|
      { type: Cocina::Models::FileSetType.public_send(type), externalIdentifier: id, label:, version: 1,
        structural: { contains: files } }
    end
    FakeDsa.new.add(build_dro(file_sets: [
                                fs.call('bc641kr2427_1', 'Data', :object, shapefile_hashes.first(2)),
                                fs.call('bc641kr2427_2', 'Preview', :preview, [file_hash('preview.jpg', mimetype: 'image/jpeg')]),
                                fs.call('bc641kr2427_3', 'Metadata', :object,
                                        [file_hash('rail.shp.xml', mimetype: 'application/xml')])
                              ]))
  end

  def layout(state)
    state.cocina.structural.contains.map { [it.label, it.structural.contains.map(&:filename)] }
  end

  def in_version(&)
    context.versions.open(druid, description: 'Rearrange file sets', &)
  end

  it 'lists file sets with their positions, types, and files' do
    expect(context.file_sets.list(druid).map { it.values_at(:position, :label, :type) })
      .to eq [[1, 'Data', 'object'], [2, 'Preview', 'preview'], [3, 'Metadata', 'object']]
  end

  describe 'Files#move' do
    it 'moves whole file sets into another, in order, keeping identifiers, and drops the emptied ones' do
      ids = all_files(dsa.record(druid).cocina).map(&:externalIdentifier)
      in_version do |state|
        context.files.move(druid, to: 'Data', from: %w[Preview Metadata], drop_empty_file_sets: true)
        expect(layout(state)).to eq [['Data', %w[rail.shp rail.dbf preview.jpg rail.shp.xml]]]
        expect(all_files(state.cocina).map(&:externalIdentifier)).to match_array(ids)
      end
      move = emitted.find { it['action'] == 'files.move' }
      expect(move['details']['before'].map { it['label'] }).to eq %w[Data Preview Metadata]
      expect(move['result']).to eq 'planned'
      expect(dsa.calls_for(:update)).to be_empty
    end

    it 'moves named files to a position, leaving emptied file sets unless asked' do
      in_version do |state|
        context.files.move(druid, ['preview.jpg'], to: 'Metadata', position: 1)
        expect(layout(state)).to eq [['Data', %w[rail.shp rail.dbf]], ['Preview', []], ['Metadata', %w[preview.jpg rail.shp.xml]]]
      end
    end

    it 'reorders files within a file set' do
      in_version do |state|
        context.files.move(druid, ['rail.dbf'], to: 'Data', position: 1)
        expect(layout(state).first).to eq ['Data', %w[rail.dbf rail.shp]]
      end
    end

    it 'refuses unknown files and file sets, and no-op moves' do
      in_version do
        expect { context.files.move(druid, ['nope.txt'], to: 'Data') }.to raise_error(SdrOps::Skip, /no file named/)
        expect { context.files.move(druid, ['rail.shp'], to: 'Nope') }.to raise_error(SdrOps::Skip, /no file set/)
        expect { context.files.move(druid, ['rail.shp'], to: 'Data', position: 1) }.to raise_error(SdrOps::Skip, /nothing/)
      end
    end
  end

  describe SdrOps::FileSets do
    it 'adds, renames, retypes, reorders, and removes file sets' do
      in_version do |state|
        context.file_sets.add(druid, label: 'Extras', type: 'file', position: 2)
        expect(layout(state).map(&:first)).to eq %w[Data Extras Preview Metadata]

        context.file_sets.update(druid, 'Data', label: 'Object', type: 'object')
        context.file_sets.order(druid, %w[Metadata Object Extras Preview])
        expect(layout(state).map(&:first)).to eq %w[Metadata Object Extras Preview]

        context.file_sets.remove(druid, ['Extras'])
        expect(layout(state).map(&:first)).to eq %w[Metadata Object Preview]
      end
    end

    it 'refuses to remove file sets with files unless asked, and then removes the files too' do
      in_version do |state|
        expect { context.file_sets.remove(druid, ['Preview']) }.to raise_error(SdrOps::Skip, /still contain files/)

        context.file_sets.remove(druid, ['Preview'], with_files: true)
        expect(all_files(state.cocina).map(&:filename)).not_to include('preview.jpg')
      end
    end

    it 'requires every file set to be named exactly once when reordering, and unique labels' do
      in_version do
        expect { context.file_sets.order(druid, %w[Data Preview]) }.to raise_error(SdrOps::UsageError, /exactly once/)
        expect { context.file_sets.add(druid, label: 'Data') }.to raise_error(SdrOps::Skip, /already has a file set/)
      end
    end

    it 'needs a version this run opened' do
      expect { context.file_sets.add(druid, label: 'X') }.to raise_error(SdrOps::Skip, /no open version/)
    end
  end

  describe 'CLI' do
    let(:out) { StringIO.new }
    let(:output) { SdrOps::Output.new(out:, err: StringIO.new) }

    def cli(*argv)
      argv = ['--env', 'stage', '--run', File.join(@tmpdir, 'run'), '--as', 'jdoe', *argv]
      SdrOps::CLI.start(argv, output:, client: dsa, transport: FakeTransport.new, credentials: FakeCredentials.new)
    end

    it 'collapses file sets for one object, or for every object in --druids' do
      code = cli('--execute', 'files', 'move', druid, '--from', 'Preview', '--from', 'Metadata', '--to', 'Data',
                 '--drop-empty-file-sets', '--open', 'Consolidate files into a single file set')
      expect(code).to eq 0
      cocina = dsa.calls_for(:update).last.last[:cocina]
      expect(cocina.structural.contains.map(&:label)).to eq ['Data']
      expect(dsa.calls_for(:open).last.last[:description]).to eq 'Consolidate files into a single file set'

      dsa.record(druid).openable = true # accessioning finished
      list = File.join(@tmpdir, 'druids.txt')
      File.write(list, "#{druid}\n")
      cli('--druids', list, 'filesets', 'set', 'Data', '--label', 'Object', '--open', 'Rename')
      expect(out.string.lines.map { JSON.parse(it) }.find { it['action'] == 'filesets.set' }).to include('result' => 'planned')
    end
  end
end
