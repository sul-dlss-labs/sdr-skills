# frozen_string_literal: true

# Runs on a stacks host via `bin/rails runner` (sdr-ops login --stacks). Mints a short-lived service token, signed
# the same way as stacks' `generate_token` task but with an expiry, which stacks' JWT check enforces. Stacks gives
# service users the same access as Stanford users (stacks app/models/user.rb).
# Inputs (environment): SDR_OPS_SUB (SUNet ID), SDR_OPS_TTL (seconds). Output: one SDR_OPS_RESULT line.
sub = ENV.fetch('SDR_OPS_SUB')
ttl = Integer(ENV.fetch('SDR_OPS_TTL'))
abort "sdr-ops: invalid subject #{sub.inspect}" unless sub.match?(/\A[a-z0-9]{2,16}\z/)
abort 'sdr-ops: TTL must be between 5 minutes and 12 hours' unless ttl.between?(300, 43_200)

secret = Settings.service_token.hmac_secret
abort 'sdr-ops: stacks has no service token secret configured on this host' if secret.to_s.empty?

now = Time.now.to_i
token = JWT.encode({ sub:, iat: now, exp: now + ttl, iss: 'sdr-ops' }, secret, 'HS256')
puts "SDR_OPS_RESULT #{JSON.generate(token:, exp: now + ttl)}"
