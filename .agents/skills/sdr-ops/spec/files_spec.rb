# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SdrOps::Files do
  let(:druid) { CocinaHelpers::DRUID }
  let(:dsa) { FakeDsa.new.add(build_dro) }
  let(:transport) { FakeTransport.new }
  let(:execute) { false }
  let(:context) { build_context(dsa:, transport:, execute:, reason: 'Add code page file', ticket: 'gis-robot-suite#1134') }
  let(:workspace_cpg) { '/dor/workspace/bc/641/kr/2427/bc641kr2427/content/rail.cpg' }

  def add_cpg
    context.files.add(druid, filename: 'rail.cpg', content: '936', like: 'rail.dbf', mimetype: 'text/plain')
  end

  describe '#add' do
    it 'refuses to change an object outside a version this run opened' do
      expect { add_cpg }.to raise_error(SdrOps::Skip, /no open version/)
    end

    context 'when dry run, inside a version the run opened' do
      it 'plans the file with attributes copied from the sibling, without uploading or saving' do
        context.versions.open(druid, description: 'Add code page file') { add_cpg }

        add = emitted.find { it['action'] == 'files.add' }
        file = add['details']['file']
        expect(file).to include('filename' => 'rail.cpg', 'hasMimeType' => 'text/plain', 'size' => 3, 'use' => 'master',
                                'version' => 2, 'sdrGeneratedText' => false,
                                'access' => { 'view' => 'stanford', 'download' => 'stanford',
                                              'controlledDigitalLending' => false })
        expect(file['administrative']).to eq('publish' => true, 'sdrPreserve' => true, 'shelve' => true)
        expect(file['hasMessageDigests']).to include({ 'type' => 'md5', 'digest' => Digest::MD5.hexdigest('936') })
        expect(file['externalIdentifier']).to match(%r{\Ahttps://cocina.sul.stanford.edu/file/bc641kr2427-abc123/[0-9a-f-]{36}\z})
        expect(add['details']).to include('workspace_path' => workspace_cpg, 'upload' => 'planned',
                                          'description' => 'Add code page file; gis-robot-suite#1134')
        expect(transport.puts).to be_empty
        expect(dsa.calls_for(:update)).to be_empty
      end
    end

    context 'when executing' do
      let(:execute) { true }

      it 'uploads the bytes, verifies them, then saves the cocina with the user and description' do
        context.versions.open(druid, description: 'Add code page file') { add_cpg }

        expect(transport.puts).to eq [{ profile: 'accession', remote_path: workspace_cpg,
                                        md5: Digest::MD5.hexdigest('936'), bytes: '936' }]
        update = dsa.calls_for(:update).first.last
        expect(update).to include(user_name: 'jdoe', description: 'Add code page file; gis-robot-suite#1134')
        expect(all_files(update[:cocina]).map(&:filename)).to include('rail.cpg')
        expect(all_files(update[:cocina]).size).to eq 5
        expect(dsa.calls_for(:close).size).to eq 1
      end

      it 'skips the upload when identical bytes are already in the workspace' do
        transport.remote_md5s[workspace_cpg] = Digest::MD5.hexdigest('936')
        context.versions.open(druid, description: 'Add code page file') { add_cpg }

        expect(transport.puts).to be_empty
        expect(emitted.find { it['action'] == 'files.add' }['details']['upload']).to eq 'already-present'
      end

      it 'refuses to overwrite different bytes already in the workspace' do
        transport.remote_md5s[workspace_cpg] = 'something-else'
        expect { context.versions.open(druid, description: 'x') { add_cpg } }
          .to raise_error(SdrOps::Skip, /already has a different/)
      end
    end

    it 'refuses a filename the object already has' do
      expect do
        context.versions.open(druid, description: 'x') do
          context.files.add(druid, filename: 'rail.dbf', content: 'x', like: 'rail.shp')
        end
      end.to raise_error(SdrOps::Skip, /use replace/)
    end

    it 'requires the administrative flags when there is no sibling to copy from' do
      expect do
        context.versions.open(druid, description: 'x') { context.files.add(druid, filename: 'readme.txt', content: 'x') }
      end.to raise_error(SdrOps::UsageError, /--preserve, --shelve, and --publish/)
    end

    it 'rejects unsafe filenames' do
      expect do
        context.versions.open(druid, description: 'x') do
          context.files.add(druid, filename: '../x', content: 'x', like: 'rail.dbf')
        end
      end.to raise_error(SdrOps::UsageError, /Unsafe filename/)
    end
  end

  describe '#add with explicit attributes' do
    it 'uses explicit access, sdrGeneratedText, and short file set type names' do
      context.versions.open(druid, description: 'x') do |state|
        context.files.add(druid, filename: 'preview.jpg', content: 'jpg', new_file_set: 'Preview', file_set_type: 'preview',
                                 mimetype: 'image/jpeg', use: 'master', preserve: true, shelve: true, publish: true,
                                 access: { view: 'world', download: 'world' }, sdr_generated_text: true)
        preview = state.cocina.structural.contains.last
        expect(preview.type).to eq Cocina::Models::FileSetType.preview
        file = preview.structural.contains.first
        expect(file.access.to_h).to include(view: 'world', download: 'world')
        expect(file.sdrGeneratedText).to be true
      end
    end

    it 'rejects unknown file set types and invalid access' do
      context.versions.open(druid, description: 'x') do
        expect do
          context.files.add(druid, filename: 'a.txt', content: 'a', new_file_set: 'X', file_set_type: 'bogus',
                                   preserve: true, shelve: true, publish: true)
        end
          .to raise_error(SdrOps::UsageError, /File set type must be one of/)
        expect do
          context.files.add(druid, filename: 'a.txt', content: 'a', like: 'rail.dbf',
                                   access: { view: 'stanford', download: 'world' })
        end
          .to raise_error(SdrOps::UsageError, /Invalid cocina: .*access/)
      end
    end
  end

  describe '#replace / #remove / #set' do
    it 'replaces digests and size but keeps the identifier' do
      original = all_files(dsa.record(druid).cocina).find { it.filename == 'rail.prj' }
      context.versions.open(druid, description: 'x') do |state|
        context.files.replace(druid, 'rail.prj', content: 'GEOGCS[]')
        replaced = all_files(state.cocina).find { it.filename == 'rail.prj' }
        expect(replaced.externalIdentifier).to eq original.externalIdentifier
        expect(replaced.size).to eq 8
      end
    end

    it 'removes files' do
      context.versions.open(druid, description: 'x') do |state|
        context.files.remove(druid, ['rail.fgb'])
        expect(all_files(state.cocina).map(&:filename)).not_to include('rail.fgb')
      end
    end

    it 'changes attributes, and can remove the use' do
      context.versions.open(druid, description: 'x') do |state|
        context.files.set(druid, 'rail.prj', mimetype: 'application/octet-stream', use: 'none')
        file = all_files(state.cocina).find { it.filename == 'rail.prj' }
        expect(file.hasMimeType).to eq 'application/octet-stream'
        expect(file.use).to be_nil
      end
    end

    it 'requires workspace bytes before turning preservation on' do
      expect do
        context.versions.open(druid, description: 'x') { context.files.set(druid, 'rail.fgb', preserve: true) }
      end.to raise_error(SdrOps::Skip, /needs rail.fgb in the workspace/)
    end
  end

  describe '#make_readable' do
    let(:workspace_dbf) { '/dor/workspace/bc/641/kr/2427/bc641kr2427/content/rail.dbf' }
    let(:export_dbf) { '/dor/export/bc641kr2427/data/content/rail.dbf' }

    it 'reports the current modes of the workspace and export copies in a dry run, without needing a version' do
      transport.modes = { workspace_dbf => %w[600 644], export_dbf => %w[600 644] }
      context.files.make_readable(druid, ['rail.dbf'])

      expect(transport.mode_changes).to eq [{ profile: 'accession', paths: [workspace_dbf, export_dbf], change: false }]
      row = emitted.last
      expect(row).to include('action' => 'files.make_readable', 'result' => 'planned')
      expect(row['details']['modes'].map { it['mode_before'] }).to eq %w[600 600]
    end

    context 'when executing' do
      let(:execute) { true }

      it 'changes the modes, leaving out the export bag with export: false' do
        transport.modes = { workspace_dbf => %w[600 644] }
        context.files.make_readable(druid, ['rail.dbf'], export: false)

        expect(transport.mode_changes.last).to include(paths: [workspace_dbf], change: true)
        expect(emitted.last).to include('result' => 'ok')
      end

      it 'fails when a file is still unreadable afterwards' do
        transport.modes = { workspace_dbf => %w[600 600] }
        expect { context.files.make_readable(druid, ['rail.dbf']) }.to raise_error(SdrOps::Error, /still not readable/)
      end
    end

    it "skips when none of the copies exist, or the object doesn't have the file" do
      expect { context.files.make_readable(druid, ['rail.dbf']) }.to raise_error(SdrOps::Skip, /none of/)
      expect { context.files.make_readable(druid, ['nope.cpg']) }.to raise_error(SdrOps::Skip, /no file named/)
    end
  end

  describe '#fetch' do
    let(:execute) { true }

    it 'fetches preserved files through the workspace host and verifies their md5s' do
      transport.script_results = [{ 'filepath' => 'rail.dbf', 'path' => '/tmp/sdr-ops-jdoe-run/fetch-x/rail.dbf' }]
      transport.downloads['/tmp/sdr-ops-jdoe-run/fetch-x/rail.dbf'] = 'rail.dbf'
      context.files.fetch(druid, ['rail.dbf'], to: File.join(@tmpdir, 'dl'))

      expect(transport.scripts.first).to include(profile: 'accession', script: 'fetch_preserved.rb')
      request = JSON.parse(transport.scripts.first[:env]['SDR_OPS_FETCH'])
      expect(request['files']).to eq [{ 'filepath' => 'rail.dbf', 'md5' => Digest::MD5.hexdigest('rail.dbf') }]
      expect(File.read(File.join(@tmpdir, 'dl', 'rail.dbf'))).to eq 'rail.dbf'
      expect(transport.removed.first).to start_with('/tmp/sdr-ops-jdoe-run/fetch-')
    end

    it 'rejects a download whose md5 does not match cocina' do
      transport.script_results = [{ 'filepath' => 'rail.dbf', 'path' => '/tmp/x/rail.dbf' }]
      transport.downloads['/tmp/x/rail.dbf'] = 'corrupted'
      expect { context.files.fetch(druid, ['rail.dbf'], to: File.join(@tmpdir, 'dl')) }
        .to raise_error(SdrOps::Error, /downloaded md5 .* doesn't match cocina/)
    end

    it 'only plans in a dry run' do
      dry = build_context(dsa:, transport:)
      dry.files.fetch(druid)
      expect(transport.scripts).to be_empty
      expect(emitted.last['details']['files'].map { it['filename'] }).to eq %w[rail.shp rail.dbf rail.prj]
    end

    context 'when stacks returns 404 for a world-downloadable file' do
      let(:dsa) do
        files = shapefile_hashes.map { it.merge(access: { view: 'world', download: 'world' }) }
        FakeDsa.new.add(build_dro(files:))
      end
      let(:published) { Cocina::Models.without_metadata(dsa.record(druid).cocina).to_json }

      before { stub_request(:get, 'https://stacks-stage.stanford.edu/file/bc641kr2427/rail.fgb').to_return(status: 404) }

      it "explains stacks' cocina cache when purl's published version lists the file" do
        stub_request(:get, 'https://sul-purl-stage.stanford.edu/bc641kr2427.json').to_return(body: published)
        expect { context.files.fetch(druid, ['rail.fgb'], source: 'stacks', to: File.join(@tmpdir, 'dl')) }
          .to raise_error(SdrOps::Error, /purl's published version 1 lists it.*caches each object's public cocina for 10 minutes/)
      end

      it 'reports a plain 404 when the file is not in the published version' do
        stub_request(:get, 'https://sul-purl-stage.stanford.edu/bc641kr2427.json').to_return(status: 404)
        expect { context.files.fetch(druid, ['rail.fgb'], source: 'stacks', to: File.join(@tmpdir, 'dl')) }
          .to raise_error(SdrOps::Downloads::NotFound, /returned HTTP 404/)
      end
    end

    context 'with Stanford-only files on stacks' do
      let(:stacks_token) { 'header.payload.signature' }
      let(:context) do
        build_context(dsa:, transport:, execute: true, credentials: FakeCredentials.new(stacks_token:))
      end
      let(:dsa) do
        files = shapefile_hashes.map { it[:filename] == 'rail.shp' ? it.merge(access: { view: 'world', download: 'world' }) : it }
        FakeDsa.new.add(build_dro(files:))
      end
      let(:dl) { File.join(@tmpdir, 'dl') }

      it 'sends the stacks service token for them, and only for them' do
        stanford = stub_request(:get, 'https://stacks-stage.stanford.edu/file/bc641kr2427/rail.fgb')
                   .with(headers: { 'Authorization' => "Bearer #{stacks_token}" }).to_return(body: 'rail.fgb')
        world = stub_request(:get, 'https://stacks-stage.stanford.edu/file/bc641kr2427/rail.shp')
                .with { !it.headers.key?('Authorization') }.to_return(body: 'rail.shp')
        context.files.fetch(druid, ['rail.fgb', 'rail.shp'], source: 'stacks', to: dl)

        expect([stanford, world]).to all(have_been_made)
        expect(File.read(File.join(dl, 'rail.fgb'))).to eq 'rail.fgb'
        expect(emitted.last['details']['files'].to_h { [it['filename'], it['stacks_token']] })
          .to eq('rail.fgb' => true, 'rail.shp' => false)
        expect(@out.string + @err.string).not_to include(stacks_token)
      end

      it 'explains a 403' do
        stub_request(:get, 'https://stacks-stage.stanford.edu/file/bc641kr2427/rail.fgb').to_return(status: 403)
        expect { context.files.fetch(druid, ['rail.fgb'], source: 'stacks', to: dl) }
          .to raise_error(SdrOps::Error, /HTTP 403.*Stanford-level access only/)
      end

      it 'treats a redirect to the login page as refused, and never sends the token to another host' do
        stub_request(:get, 'https://stacks-stage.stanford.edu/file/bc641kr2427/rail.fgb')
          .to_return(status: 302, headers: { 'Location' => '/file/auth/bc641kr2427/rail.fgb' })
        expect { context.files.fetch(druid, ['rail.fgb'], source: 'stacks', to: dl) }
          .to raise_error(SdrOps::Error, /redirected to a login page/)

        stub_request(:get, 'https://stacks-stage.stanford.edu/file/bc641kr2427/rail.dbf')
          .to_return(status: 302, headers: { 'Location' => 'https://elsewhere.example.com/rail.dbf' })
        elsewhere = stub_request(:get, 'https://elsewhere.example.com/rail.dbf')
                    .with { !it.headers.key?('Authorization') }.to_return(body: 'rail.dbf')
        context.files.fetch(druid, ['rail.dbf'], source: 'stacks', to: dl)
        expect(elsewhere).to have_been_made
      end

      it 'needs `login --stacks` first' do
        context = build_context(dsa:, transport:, execute: true)
        expect { context.files.fetch(druid, ['rail.fgb'], source: 'stacks', to: dl) }
          .to raise_error(SdrOps::AuthError, /login --stacks/)
      end

      it 'plans without a token in a dry run' do
        build_context(dsa:, transport:).files.fetch(druid, ['rail.fgb'], source: 'stacks', to: dl)
        expect(a_request(:get, /stacks/)).not_to have_been_made
      end

      context 'with a byte range' do
        let(:size) do
          dsa.record(druid).cocina.structural.contains.flat_map { it.structural.contains }.find { it.filename == 'rail.fgb' }.size
        end

        it 'requests just those bytes, with the token, and saves them under a name that says so' do
          part = stub_request(:get, 'https://stacks-stage.stanford.edu/file/bc641kr2427/rail.fgb')
                 .with(headers: { 'Authorization' => "Bearer #{stacks_token}", 'Range' => 'bytes=0-3' })
                 .to_return(status: 206, body: 'rail', headers: { 'Content-Range' => "bytes 0-3/#{size}" })
          context.files.fetch(druid, ['rail.fgb'], source: 'stacks', to: dl, range: '0-3')

          expect(part).to have_been_made
          expect(File.read(File.join(dl, 'rail.bytes-0-3.fgb'))).to eq 'rail'
          expect(File).not_to exist(File.join(dl, 'rail.fgb'))
          report = emitted.last
          expect(report['args']['range']).to eq '0-3'
          expect(report['details']['files'].first).to include('range' => '0-3', 'range_bytes' => 4)
          expect(report['details']['total_bytes']).to eq 4
          expect(@out.string + @err.string).not_to include(stacks_token)
        end

        it 'refuses a server that ignores the range, rather than downloading the whole file' do
          stub_request(:get, 'https://stacks-stage.stanford.edu/file/bc641kr2427/rail.fgb')
            .to_return(status: 200, body: 'the whole file')
          expect { context.files.fetch(druid, ['rail.fgb'], source: 'stacks', to: dl, range: '0-3') }
            .to raise_error(SdrOps::Error, /ignored the Range request \(HTTP 200\)/)
          expect(Dir.glob(File.join(dl, '*'))).to be_empty
        end

        it "checks the file's total size against cocina, since there's no md5 to check" do
          stub_request(:get, 'https://stacks-stage.stanford.edu/file/bc641kr2427/rail.fgb')
            .to_return(status: 206, body: 'rail', headers: { 'Content-Range' => "bytes 0-3/#{size + 1}" })
          expect { context.files.fetch(druid, ['rail.fgb'], source: 'stacks', to: dl, range: '0-3') }
            .to raise_error(SdrOps::Error, /a file of #{size + 1} bytes, but cocina says #{size}/)
          expect(File).not_to exist(File.join(dl, 'rail.bytes-0-3.fgb'))
        end

        it 'keeps the range across a redirect to another host, but not the token' do
          stub_request(:get, 'https://stacks-stage.stanford.edu/file/bc641kr2427/rail.fgb')
            .to_return(status: 302, headers: { 'Location' => 'https://elsewhere.example.com/rail.fgb' })
          elsewhere = stub_request(:get, 'https://elsewhere.example.com/rail.fgb')
                      .with(headers: { 'Range' => 'bytes=-2' }) { !it.headers.key?('Authorization') }
                      .to_return(status: 206, body: 'gb', headers: { 'Content-Range' => "bytes #{size - 2}-#{size - 1}/#{size}" })
          context.files.fetch(druid, ['rail.fgb'], source: 'stacks', to: dl, range: '-2')
          expect(elsewhere).to have_been_made
          expect(File.read(File.join(dl, 'rail.bytes-last-2.fgb'))).to eq 'gb'
        end

        it 'plans the byte count in a dry run, without a request' do
          build_context(dsa:, transport:).files.fetch(druid, ['rail.fgb'], source: 'stacks', to: dl, range: '2-')
          expect(a_request(:get, /stacks/)).not_to have_been_made
          expect(emitted.last['details']['files'].first)
            .to include('range' => '2-', 'range_bytes' => size - 2, 'local_path' => File.join(dl, 'rail.bytes-2-end.fgb'))
        end

        it 'works only with --source stacks, and only with a well-formed range' do
          expect { context.files.fetch(druid, ['rail.fgb'], source: 'preservation', range: '0-3') }
            .to raise_error(SdrOps::UsageError, /only with --source stacks/)
          %w[abc 5-1 -0].each do |bad|
            expect { context.files.fetch(druid, ['rail.fgb'], source: 'stacks', to: dl, range: bad) }
              .to raise_error(SdrOps::UsageError, /--range/)
          end
        end
      end
    end

    it 'refuses stacks downloads of files that are location-restricted or not shelved' do
      location_based = file_hash('rail.dbf', mimetype: 'application/vnd.dbf')
                       .merge(access: { view: 'stanford', download: 'location-based', location: 'spec' })
      unshelved = file_hash('rail.shp', mimetype: 'application/vnd.shp', shelve: false)
      dsa = FakeDsa.new.add(build_dro(files: [location_based, unshelved]))
      context = build_context(dsa:, transport:, execute: true)
      expect { context.files.fetch(druid, ['rail.dbf'], source: 'stacks') }
        .to raise_error(SdrOps::Skip, /isn't downloadable from stacks .*download: location-based/)
      expect { context.files.fetch(druid, ['rail.shp'], source: 'stacks') }.to raise_error(SdrOps::Skip, /shelve: false/)
    end
  end

  describe '.resource_id_from' do
    it 'derives the resource id the way DSA does' do
      expect(described_class.resource_id_from('https://cocina.sul.stanford.edu/fileSet/bc641kr2427-abc-123')).to eq 'abc-123'
      expect(described_class.resource_id_from('bc641kr2427_1')).to eq 'bc641kr2427_1'
    end
  end
end
