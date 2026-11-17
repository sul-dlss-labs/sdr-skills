# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SdrOps::CLI do
  let(:druid) { CocinaHelpers::DRUID }
  let(:dsa) { FakeDsa.new.add(build_dro) }
  let(:transport) { FakeTransport.new }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:output) { SdrOps::Output.new(out:, err:) }

  def cli(*argv)
    argv = ['--run', File.join(@tmpdir, 'run'), '--as', 'jdoe', *argv]
    described_class.start(argv, output:, client: dsa, transport:, credentials: FakeCredentials.new)
  end

  def rows = out.string.lines.map { JSON.parse(it) }

  it 'requires --env' do
    expect(cli('status', druid)).to eq 2
    expect(err.string).to include('--env is required')
  end

  it 'accepts global options after the command' do
    expect(cli('status', druid, '--env', 'stage')).to eq 0
    expect(rows.first).to include('druid' => druid, 'version' => 1, 'open' => false)
  end

  it 'adds a file in its own version as a dry run by default' do
    path = File.join(@tmpdir, 'rail.cpg')
    File.write(path, '936')
    code = cli('--env', 'stage', 'files', 'add', druid, path, '--like', 'rail.dbf', '--open', 'Add code page file')

    expect(code).to eq 0
    expect(rows.map { it['action'] }.compact).to eq %w[version.open files.add version.close]
    expect(dsa.calls_for(:update)).to be_empty
    expect(err.string).to include('DRY RUN')
  end

  it 'stops on an object that already has an open version, with exit 0 and a stopped result' do
    dsa.record(druid).open = true
    path = File.join(@tmpdir, 'rail.cpg')
    File.write(path, '936')
    cli('--env', 'stage', '--execute', 'files', 'add', druid, path, '--like', 'rail.dbf', '--open', 'Add code page file')

    expect(rows.find { it['result'] == 'stopped' }['message']).to include('already has open version 1')
    expect(dsa.calls_for(:open)).to be_empty
  end

  it "renames an open version from an earlier invocation in the run, and stops on someone else's" do
    cli('--env', 'stage', '--execute', 'version', 'open', druid, '--description', 'Regenerate derivatives')
    expect(cli('--env', 'stage', '--execute', 'version', 'rename', druid, '--description', 'Add code page file')).to eq 0
    expect(dsa.record(druid).description).to eq 'Add code page file'

    dsa.record(druid).version = 3 # not a version the run opened
    cli('--env', 'stage', '--execute', 'version', 'rename', druid, '--description', 'Something else')
    expect(rows.find { it['result'] == 'stopped' }['message']).to include('already has open version 3')
    expect(dsa.calls_for(:update_description).size).to eq 1
    expect(cli('--env', 'stage', 'version', 'rename', druid)).to eq 2
  end

  it 'requires --open when the run has no version of its own' do
    cli('--env', 'stage', 'files', 'remove', druid, 'rail.fgb')
    expect(rows.find { it['result'] == 'skipped' }['message']).to include('pass --open')
  end

  it 'runs a workflow for several druids from a file' do
    dsa.record(druid).open = true
    list = File.join(@tmpdir, 'druids.txt')
    File.write(list, "#{druid}\n")
    expect(cli('--env', 'stage', '--execute', '--druids', list, 'workflow', 'run', 'gisDerivativeWF', '--lane', 'low')).to eq 0
    expect(dsa.calls_for(:workflow_create).size).to eq 1
  end

  it 'plans remote exec without running it' do
    expect(cli('--env', 'stage', '--host', 'gis', 'exec', '--', 'uv', 'run', 'x.py')).to eq 0
    expect(rows.last).to include('action' => 'exec', 'result' => 'planned', 'host' => 'kurma-robots-stage-01.stanford.edu')
  end

  it 'runs a generated script with the context and remaining arguments' do
    script = File.join(@tmpdir, 'script.rb')
    File.write(script, <<~RUBY)
      SdrOps.batch(ARGV.fetch(0)) { |row, sdr| sdr.output.emit({ seen: row['druid'], execute: sdr.execute? }) }
    RUBY
    list = File.join(@tmpdir, 'druids.txt')
    File.write(list, "#{druid}\n")
    expect(cli('--env', 'stage', 'run', script, list, '--limit', '1')).to eq 0
    expect(rows.first).to eq('seen' => druid, 'execute' => false)
  end

  it 'registers a test object as a dry run by default, then for real with --execute' do
    expect(cli('--env', 'stage', 'register', '--title', 'Test', '--apo', 'rz685py5647', '--tag', 'Project : x')).to eq 0
    expect(rows.last).to include('action' => 'object.register', 'result' => 'planned')
    expect(err.string).to include('nothing was registered')

    expect(cli('--env', 'stage', '--execute', 'register', '--title', 'Test', '--apo', 'rz685py5647', '--accession')).to eq 0
    expect(rows.map { it['action'] }.last(2)).to eq %w[object.register version.close]
  end

  it 'requires a title and an APO to register' do
    expect(cli('--env', 'stage', 'register', '--title', 'Test')).to eq 2
  end
end
