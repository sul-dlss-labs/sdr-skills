# frozen_string_literal: true

# Runs on a DSA host via `bin/rails runner` (sdr-ops find). Read-only: Solr queries through DSA's SolrService and
# workflow-table reads, inside ActiveRecord's write prevention.
# Input (environment): SDR_OPS_FIND, JSON built by SdrOps::Find#build_params. Output: SDR_OPS_ROW lines.
params = JSON.parse(ENV.fetch('SDR_OPS_FIND'))
fields = params.fetch('fields')
error_re = params['error_match'] && Regexp.new(params['error_match'])
join = ->(value) { value.is_a?(Array) ? value.join(';') : value }
term = ->(field, value) { "{!term f=#{field}}#{value}" }
emit = ->(row) { puts "SDR_OPS_ROW #{JSON.generate(row)}" }

# Page through every matching document with a cursor.
solr_docs = lambda do |filters, field_list|
  Enumerator.new do |docs|
    cursor = '*'
    loop do
      response = SolrService.get('*:*', fq: filters, fl: field_list.uniq.join(','), rows: 1000, sort: 'id asc',
                                        cursorMark: cursor)
      response.dig('response', 'docs').each { |doc| docs << doc }
      next_cursor = response['nextCursorMark']
      break if next_cursor.nil? || next_cursor == cursor

      cursor = next_cursor
    end
  end
end

count = 0
ActiveRecord::Base.while_preventing_writes do
  if params['source'] == 'workflows'
    steps = WorkflowStep.where(workflow: params['workflow'], process: params['step'], active_version: true)
    steps = steps.where(status: params['status']) if params['status']
    steps = steps.to_a
    steps.select! { |step| error_re.match?(step.error_msg.to_s) } if error_re
    steps.each_slice(200) do |slice|
      docs = solr_docs.call(["{!terms f=id}#{slice.map(&:druid).join(',')}"], ['id', *fields]).index_by { it['id'] }
      slice.each do |step|
        doc = docs[step.druid] || {}
        emit.call({ 'druid' => step.druid.delete_prefix('druid:'), 'version' => step.version,
                    'workflow' => step.workflow, 'step' => step.process, 'status' => step.status,
                    'error_message' => step.error_msg, 'updated_at' => step.updated_at&.iso8601,
                    **fields.to_h { |field| [field, join.call(doc[field])] } })
        count += 1
      end
    end
  else
    filters = []
    filters << term.call('content_type_ssimdv', params['content_type']) if params['content_type']
    if params['workflow']
      value = [params['workflow'], params['step'], params['status']].compact.join(':')
      filters << term.call('wf_wps_ssimdv', value)
    end
    filters << term.call('member_of_collection_ssim', params['collection']) if params['collection']
    params.fetch('facets', {}).each { |field, value| filters << term.call(field, value) }
    abort 'sdr-ops find: give at least one filter' if filters.empty?

    field_list = ['id', *fields, ('wf_error_ssim' if error_re)].compact
    solr_docs.call(filters, field_list).each do |doc|
      next if error_re && Array(doc['wf_error_ssim']).none? { |message| error_re.match?(message) }

      emit.call({ 'druid' => doc['id'].delete_prefix('druid:'), **fields.to_h { |field| [field, join.call(doc[field])] } })
      count += 1
    end
  end
end
puts "SDR_OPS_RESULT #{JSON.generate(done: true, count:)}"
