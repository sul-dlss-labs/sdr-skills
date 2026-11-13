# frozen_string_literal: true

# Inspect and change objects in the Stanford Digital Repository (see lib/sdr_ops.rb).
module SdrOps
  # Where things live in each SDR environment. See references/environments.md.
  Environment = Data.define(:name, :dsa_url, :dsa_host, :workspace_hosts, :purl_url, :stacks_url, :stacks_host,
                            :argo_url) do
    def workspace_host(profile)
      workspace_hosts.fetch(profile) do
        raise UsageError, "Unknown --host #{profile.inspect}; expected one of #{workspace_hosts.keys.join(', ')}"
      end
    end
  end

  ENVIRONMENTS = {
    'prod' => Environment.new(
      name: 'prod',
      dsa_url: 'https://dor-services-prod-lb.stanford.edu',
      dsa_host: 'dor-services-app-prod-a.stanford.edu',
      workspace_hosts: { 'accession' => 'common-accessioning-prod-a.stanford.edu',
                         'gis' => 'kurma-robots-prod-01.stanford.edu' },
      purl_url: 'https://purl.stanford.edu',
      stacks_url: 'https://stacks.stanford.edu',
      stacks_host: 'sul-stacks-prod-a.stanford.edu',
      argo_url: 'https://argo.stanford.edu'
    ),
    'stage' => Environment.new(
      name: 'stage',
      dsa_url: 'https://dor-services-stage-lb.stanford.edu',
      dsa_host: 'dor-services-app-stage-a.stanford.edu',
      workspace_hosts: { 'accession' => 'common-accessioning-stage-a.stanford.edu',
                         'gis' => 'kurma-robots-stage-01.stanford.edu' },
      purl_url: 'https://sul-purl-stage.stanford.edu',
      stacks_url: 'https://stacks-stage.stanford.edu',
      stacks_host: 'sul-stacks-stage.stanford.edu',
      argo_url: 'https://argo-stage.stanford.edu'
    ),
    'qa' => Environment.new(
      name: 'qa',
      dsa_url: 'https://dor-services-qa-lb.stanford.edu',
      dsa_host: 'dor-services-app-qa-a.stanford.edu',
      workspace_hosts: { 'accession' => 'common-accessioning-qa-a.stanford.edu',
                         'gis' => 'kurma-robots-qa-01.stanford.edu' },
      # QA uses stage purl and stacks; the access team doesn't maintain a QA environment.
      purl_url: 'https://sul-purl-stage.stanford.edu',
      stacks_url: 'https://stacks-stage.stanford.edu',
      stacks_host: 'sul-stacks-stage.stanford.edu',
      argo_url: 'https://argo-qa.stanford.edu'
    )
  }.freeze

  DSA_USER = 'dor_services'
  DSA_APP_DIR = '/opt/app/dor_services/dor_services/current'
  STACKS_USER = 'stacks'
  STACKS_APP_DIR = '/opt/app/stacks/stacks/current'
  WORKSPACE_USER = 'lyberadmin'
  APP_DIRS = {
    'accession' => '/opt/app/lyberadmin/common-accessioning/current',
    'gis' => '/opt/app/lyberadmin/gis-robot-suite/current'
  }.freeze
  WORKSPACE_ROOT = '/dor/workspace'

  def self.environment(name)
    ENVIRONMENTS.fetch(name.to_s) do
      raise UsageError, "--env must be one of #{ENVIRONMENTS.keys.join(', ')} (got #{name.inspect})"
    end
  end
end
