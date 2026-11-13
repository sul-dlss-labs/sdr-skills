# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SdrOps::Transport do
  let(:shell) { FakeShell.new }
  let(:transport) { described_class.new(environment: SdrOps.environment('prod'), shell:) }

  it 'reads the SUNet ID from MIT or Heimdal klist output' do
    shell.respond('klist', stdout: "Credentials cache: API:1\n        Principal: jdoe@stanford.edu\n")
    expect(transport.kerberos_sunet).to eq 'jdoe'
    shell.respond('klist', stdout: "Default principal: JDOE@STANFORD.EDU\n")
    expect(transport.kerberos_sunet).to eq 'jdoe'
  end

  it 'runs remote scripts on the DSA host in a login shell, sending the script on stdin' do
    shell.respond('ssh', stdout: "noise\nSDR_OPS_ROW {\"druid\":\"bc641kr2427\"}\nSDR_OPS_RESULT {\"done\":true}\n")
    records = transport.dsa_runner(File.join(SdrOps::REMOTE_DIR, 'find.rb'), env: { 'SDR_OPS_FIND' => '{"a": "b c"}' })

    call = shell.calls.last
    expect(call[:argv].first(6)).to eq ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20',
                                        'dor_services@dor-services-app-prod-a.stanford.edu']
    remote = Shellwords.split(call[:argv].last)
    expect(remote.first(2)).to eq %w[bash -lc]
    expect(remote.last).to include('cd /opt/app/dor_services/dor_services/current', 'SDR_OPS_FIND=\\{\"a\":\\ \"b\\ c\"\\}',
                                   'RAILS_ENV=production', 'bin/rails runner')
    expect(call[:stdin]).to eq File.read(File.join(SdrOps::REMOTE_DIR, 'find.rb'))
    expect(records).to eq [{ 'druid' => 'bc641kr2427' }, { 'done' => true }]
  end

  it 'runs the stacks token script in the stacks app on the stacks host' do
    shell.respond('ssh', stdout: "SDR_OPS_RESULT {\"token\":\"x\"}\n")
    transport.stacks_runner(File.join(SdrOps::REMOTE_DIR, 'mint_stacks_token.rb'), env: { 'SDR_OPS_SUB' => 'jdoe' })

    call = shell.calls.last
    expect(call[:argv][5]).to eq 'stacks@sul-stacks-prod-a.stanford.edu'
    expect(Shellwords.split(call[:argv].last).last).to include('cd /opt/app/stacks/stacks/current', 'bin/rails runner')
  end

  it 'raises with the remote error when a script fails' do
    shell.respond('ssh', stderr: "boom\n", exitstatus: 1)
    expect { transport.dsa_runner(File.join(SdrOps::REMOTE_DIR, 'find.rb')) }.to raise_error(SdrOps::RemoteError, /boom/)
  end

  it 'uploads with scp in SFTP mode to a partial file, checks the md5 on the host, then moves it into place' do
    local = File.join(@tmpdir, 'rail.cpg')
    File.write(local, '936')
    remote = '/dor/workspace/bc/641/kr/2427/bc641kr2427/content/rail.cpg'
    transport.put_file('gis', local_path: local, remote_path: remote, md5: 'abc')

    mkdir, scp, verify = shell.calls.map { it[:argv] }
    expect(Shellwords.split(mkdir.last)).to eq ['bash', '-c', 'mkdir -p /dor/workspace/bc/641/kr/2427/bc641kr2427/content']
    expect(scp).to eq ['scp', '-s', '-q', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20', File.expand_path(local),
                       "lyberadmin@kurma-robots-prod-01.stanford.edu:#{remote}.sdr-ops-partial"]
    script = Shellwords.split(verify.last).last
    expect(script).to include("md5sum #{remote}.sdr-ops-partial", '[ "$sum" != abc ]',
                              "mv -f #{remote}.sdr-ops-partial #{remote}")
    expect(script.index("chmod 0644 #{remote}.sdr-ops-partial")).to be < script.index('mv -f')
  end

  describe '#make_readable' do
    let(:workspace) { "/dor/workspace/bc/641/kr/2427/bc641kr2427/content/it's.cpg" }
    let(:export) { '/dor/export/bc641kr2427/data/content/rail.cpg' }

    it 'adds group and other read on the workspace host, following symlinks, and reports modes' do
      shell.respond('ssh', stdout: "SDR_OPS_MODE file 600 644 #{workspace}\nSDR_OPS_MODE symlink 600 644 #{export}\n")
      modes = transport.make_readable('accession', [workspace, export], change: true)

      argv = shell.calls.last[:argv]
      expect(argv[5]).to eq 'lyberadmin@common-accessioning-prod-a.stanford.edu'
      script = Shellwords.split(argv.last).last
      expect(script).to include("for p in #{Shellwords.escape(workspace)} #{export}; do", 'chmod go+r "$p"',
                                'stat -L -c %a "$p"')
      expect(modes).to eq [{ path: workspace, kind: 'file', mode_before: '600', mode_after: '644' },
                           { path: export, kind: 'symlink', mode_before: '600', mode_after: '644' }]
    end

    it 'only reads modes when not changing them, and reports missing files' do
      shell.respond('ssh', stdout: "SDR_OPS_MODE missing - - #{export}\n")
      modes = transport.make_readable('accession', [export], change: false)

      expect(Shellwords.split(shell.calls.last[:argv].last).last).not_to include('chmod')
      expect(modes).to eq [{ path: export, kind: 'missing', mode_before: nil, mode_after: nil }]
    end

    it 'refuses paths outside the workspace and export roots' do
      %w[/etc/passwd /dor/workspace/../etc/passwd /dor/exporter/x].each do |path|
        expect { transport.make_readable('accession', [path], change: true) }.to raise_error(SdrOps::UsageError)
      end
      expect(shell.calls).to be_empty
    end
  end

  it 'stops before moving anything into place when the upload fails' do
    local = File.join(@tmpdir, 'rail.cpg')
    File.write(local, '936')
    shell.respond('scp', stderr: "Connection closed\n", exitstatus: 1)
    expect { transport.put_file('accession', local_path: local, remote_path: '/dor/workspace/x/content/f', md5: 'abc') }
      .to raise_error(SdrOps::RemoteError, /Upload of .* failed: Connection closed/)
    expect(shell.calls.size).to eq 2
  end

  it 'downloads with scp to an absolute local path, removing partial downloads on failure' do
    local = File.join(@tmpdir, 'dl', 'rail.dbf')
    transport.get_file('accession', remote_path: "/dor/workspace/x/content/it's here.dbf", local_path: local)
    expect(shell.calls.last[:argv].last(2))
      .to eq ["lyberadmin@common-accessioning-prod-a.stanford.edu:/dor/workspace/x/content/it's here.dbf", local]

    File.write(local, 'partial')
    shell.respond('scp', stderr: "No such file\n", exitstatus: 1)
    expect { transport.get_file('accession', remote_path: '/dor/workspace/x/content/f', local_path: local) }
      .to raise_error(SdrOps::RemoteError, /No such file/)
    expect(File.exist?(local)).to be false
  end

  it 'escapes awkward filenames' do
    transport.remote_md5('accession', "/dor/workspace/x/content/it's here.txt")
    expect(Shellwords.split(shell.calls.last[:argv].last).last).to include("it\\'s\\ here.txt")
  end
end
