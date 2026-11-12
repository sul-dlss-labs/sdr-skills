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
    expect(Shellwords.split(verify.last).last).to include("md5sum #{remote}.sdr-ops-partial", '[ "$sum" != abc ]',
                                                          "mv -f #{remote}.sdr-ops-partial #{remote}")
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
