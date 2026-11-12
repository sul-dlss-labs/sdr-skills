# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SdrOps::Find do
  let(:transport) { FakeTransport.new }
  let(:context) { build_context(dsa: FakeDsa.new, transport:) }
  let(:find) { described_class.new(context) }

  it 'sends validated parameters to the DSA host and drops the trailer record' do
    transport.script_results = [{ 'druid' => 'bc641kr2427', 'status' => 'error' }, { 'done' => true, 'count' => 1 }]
    rows = find.run(source: 'workflows', workflow: 'gisDerivativeWF', step: 'create-derivatives', status: 'error',
                    error_match: 'not a valid UTF-8')

    expect(rows).to eq [{ 'druid' => 'bc641kr2427', 'status' => 'error' }]
    params = JSON.parse(transport.scripts.first[:env]['SDR_OPS_FIND'])
    expect(params).to include('source' => 'workflows', 'workflow' => 'gisDerivativeWF', 'step' => 'create-derivatives',
                              'error_match' => 'not a valid UTF-8', 'fields' => described_class::DEFAULT_FIELDS)
  end

  it 'rejects bad combinations and unsafe field names' do
    expect { find.run(source: 'workflows', workflow: 'gisDerivativeWF') }.to raise_error(SdrOps::UsageError, /--step/)
    expect { find.run(status: 'error') }.to raise_error(SdrOps::UsageError)
    expect { find.run(content_type: 'geo', fields: ['id;drop']) }.to raise_error(SdrOps::UsageError, /field name/)
  end

  it 'builds the equivalent Argo report download URL' do
    url = find.argo_url(workflow: 'gisDerivativeWF', step: 'create-derivatives', status: 'error', content_type: 'geo')
    expect(url).to start_with('https://argo-stage.stanford.edu/report/download?')
    expect(url).to include('f%5Bwf_wps_ssimdv%5D%5B%5D=gisDerivativeWF%3Acreate-derivatives%3Aerror',
                           'f%5Bcontent_type_ssimdv%5D%5B%5D=geo', 'fields=druid_bare_ssi,display_title_ss')
  end

  it 'writes CSV with a druid column that Batch can read back' do
    path = File.join(@tmpdir, 'not-yet', 'items.csv')
    described_class.write([{ 'druid' => 'bc641kr2427', 'version' => 2 }], out: path, format: 'csv')
    expect(SdrOps::Batch.read(path).first).to include('druid' => 'druid:bc641kr2427', 'version' => '2')
  end
end
