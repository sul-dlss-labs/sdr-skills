# frozen_string_literal: true

# Runs on a DSA host via `bin/rails runner` (sdr-ops login). Mints a short-lived personal token, signed the
# same way as DSA's `generate_token` task but with an expiry, which DSA's JWT check enforces.
# Inputs (environment): SDR_OPS_SUB (SUNet ID), SDR_OPS_TTL (seconds). Output: one SDR_OPS_RESULT line.
sub = ENV.fetch('SDR_OPS_SUB')
ttl = Integer(ENV.fetch('SDR_OPS_TTL'))
abort "sdr-ops: invalid subject #{sub.inspect}" unless sub.match?(/\A[a-z0-9]{2,16}\z/)
abort 'sdr-ops: TTL must be between 5 minutes and 12 hours' unless ttl.between?(300, 43_200)

now = Time.now.to_i
token = JWT.encode({ sub:, iat: now, exp: now + ttl, iss: 'sdr-ops' }, Settings.dor.hmac_secret, 'HS256')
puts "SDR_OPS_RESULT #{JSON.generate(token:, exp: now + ttl, cocina_models_version: Cocina::Models::VERSION)}"
