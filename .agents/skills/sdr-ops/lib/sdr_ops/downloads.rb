# frozen_string_literal: true

module SdrOps
  # File downloads shared by `files fetch` and `clone`. Items are Hashes with :filename and :local_path, plus the
  # expected :md5 and optionally :sha1 and :size; every download is verified against whichever are present.
  module Downloads # rubocop:disable Metrics/ModuleLength
    # An HTTP 404.
    class NotFound < Error; end
    # An HTTP 401 or 403.
    class Forbidden < Error; end

    STACKS_CACHE_MINUTES = 10

    module_function

    def stacks_url(environment, druid, filename, version: nil)
      escaped = filename.split('/').map { ERB::Util.url_encode(it) }.join('/')
      bare = Druid.bare(druid)
      path = version ? "v2/file/#{bare}/version/#{version}/#{escaped}" : "file/#{bare}/#{escaped}"
      "#{environment.stacks_url}/#{path}"
    end

    # Shelved files from stacks over HTTP. Items marked :stacks_token (Stanford-only files) are sent with the stacks
    # service token from `login --stacks`; world-downloadable ones are fetched anonymously. Stacks counts each of
    # these as a download in its metrics.
    #
    # With `range:` (a ByteRange), only those bytes are requested. A partial copy can't be checked against cocina's
    # md5, so it's checked against cocina's size instead: the total stacks reports in Content-Range must match.
    def from_stacks(environment, druid, items, version: nil, token: nil, range: nil)
      items.each do |item|
        headers = item[:stacks_token] ? { 'Authorization' => "Bearer #{token || raise(AuthError, 'No stacks token')}" } : {}
        content_range = http(stacks_url(environment, druid, item[:filename], version:), item[:local_path],
                             headers:, range:)
        range ? verify_range!(item, range, content_range) : verify!(item)
      rescue NotFound => e
        raise explain_stacks_not_found(environment, druid, item[:filename], e)
      rescue Forbidden => e
        raise Error, "#{e.message}. A stacks service token has Stanford-level access only; if this file is " \
                     'Stanford-only, check that `login --stacks` is current. Otherwise use --source preservation.'
      end
    end

    # Stacks caches each object's public cocina for 10 minutes (stacks app/models/cocina.rb), so a file added in a
    # version published since stacks last served the object 404s until that copy expires. Say so when purl lists it.
    def explain_stacks_not_found(environment, druid, filename, error)
      published = json("#{environment.purl_url}/#{Druid.bare(druid)}.json")
      files = published&.dig('structural', 'contains')&.flat_map { it.dig('structural', 'contains') } || []
      return error unless files.any? { it['filename'] == filename }

      Error.new("Stacks returned 404 for #{filename}, but purl's published version #{published['version']} lists it. " \
                "Stacks caches each object's public cocina for #{STACKS_CACHE_MINUTES} minutes, so files from a " \
                'version published since stacks last served this object can 404 until that copy expires. ' \
                "Retry within #{STACKS_CACHE_MINUTES} minutes, or fetch preserved files with --source preservation.")
    rescue Error
      error
    end

    # Through a workspace host's robot app, which can reach preservation (prod preservation only accepts API
    # calls from SDR servers). See remote/fetch_preserved.rb.
    def from_preservation(transport, profile:, scratch_dir:, druid:, items:, version: nil)
      remote_root = "#{scratch_dir}/fetch-#{SecureRandom.hex(4)}"
      request = { druid:, version:, dest: remote_root, files: items.map { { filepath: it[:filename], md5: it[:md5] } } }
      records = transport.app_ruby(profile, File.join(REMOTE_DIR, 'fetch_preserved.rb'),
                                   env: { 'SDR_OPS_FETCH' => JSON.generate(request) })
      records.each do |record|
        item = items.find { it[:filename] == record['filepath'] }
        transport.get_file(profile, remote_path: record['path'], local_path: item[:local_path])
        verify!(item)
      end
    ensure
      transport.remove_remote(profile, remote_root)
    end

    # @return [Boolean] whether a local file already matches the item (so it needn't be downloaded again)
    def present?(item)
      File.file?(item[:local_path]) && mismatches(item).empty?
    end

    def verify!(item)
      problems = mismatches(item)
      return item[:verified] = true if problems.empty?

      FileUtils.rm_f(item[:local_path])
      raise Error, "#{item[:filename]}: downloaded #{problems.join(', ')}"
    end

    # A ranged download: the bytes written must be the ones asked for, and the whole file's size (from
    # Content-Range: bytes FIRST-LAST/TOTAL) must match cocina's.
    def verify_range!(item, range, content_range)
      total = content_range.to_s[%r{/(\d+)\z}, 1]&.to_i
      expected = range.length_for(total || item[:size]&.to_i)
      written = File.size(item[:local_path])
      problems = []
      problems << "no usable Content-Range (got #{content_range.inspect})" if total.nil?
      problems << "a file of #{total} bytes, but cocina says #{item[:size]}" if total && item[:size] && total != item[:size].to_i
      problems << "#{written} bytes for range #{range} (expected #{expected})" if expected && written != expected
      return item.merge!(verified: true, bytes: written, content_range:) if problems.empty?

      FileUtils.rm_f(item[:local_path])
      raise Error, "#{item[:filename]}: downloaded #{problems.join(', ')}"
    end

    def mismatches(item)
      path = item[:local_path]
      problems = { md5: Digest::MD5, sha1: Digest::SHA1 }.filter_map do |key, klass|
        next unless item[key]

        actual = klass.file(path).hexdigest
        "#{key} #{actual} doesn't match cocina (#{item[key]})" unless actual == item[key]
      end
      if item[:size] && File.size(path) != item[:size].to_i
        problems << "size #{File.size(path)} doesn't match cocina (#{item[:size]})"
      end
      problems
    end

    # Headers (e.g. Authorization) are only sent to the original host, never to a redirect elsewhere; a `range:`
    # (ByteRange) is sent to every hop. A redirect to stacks' login page means the file needs credentials that
    # weren't sent.
    #
    # @return [String, nil] the response's Content-Range header
    def http(url, local_path, headers: {}, range: nil, redirects: 5)
      uri = URI(url)
      FileUtils.mkdir_p(File.dirname(local_path))
      request_headers = range ? headers.merge('Range' => range.header) : headers
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.request(Net::HTTP::Get.new(uri, request_headers)) do |response|
          case response
          when Net::HTTPSuccess then return save_body(response, url, local_path, range)
          when Net::HTTPRedirection
            raise Error, "Too many redirects fetching #{url}" if redirects.zero?

            target = URI.join(url, response['location'])
            raise Forbidden, "#{url} redirected to a login page" if target.path.start_with?('/file/auth/', '/auth/')

            same_host = target.host == uri.host
            return http(target.to_s, local_path, headers: same_host ? headers : {}, range:, redirects: redirects - 1)
          when Net::HTTPRequestedRangeNotSatisfiable
            raise Error, "#{url}: range #{range} is outside the file (HTTP 416)"
          when Net::HTTPUnauthorized, Net::HTTPForbidden then raise Forbidden, "#{url} returned HTTP #{response.code}"
          when Net::HTTPNotFound then raise NotFound, "#{url} returned HTTP 404"
          else raise Error, "#{url} returned HTTP #{response.code}"
          end
        end
      end
    end

    # A ranged request must come back 206: a server that ignores Range and answers 200 would send the whole file,
    # so that's refused before the body is read.
    def save_body(response, url, local_path, range)
      if range && !response.is_a?(Net::HTTPPartialContent)
        raise Error, "#{url} ignored the Range request (HTTP #{response.code}); not downloading the whole file"
      end

      File.open(local_path, 'wb') { |file| response.read_body { |chunk| file.write(chunk) } }
      response['Content-Range']
    end

    # GET a JSON document. Returns nil for a 404.
    def json(url, headers: {})
      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.request(Net::HTTP::Get.new(uri, headers.merge('Accept' => 'application/json')))
      end
      return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)
      return if response.is_a?(Net::HTTPNotFound)

      raise Error, "#{url} returned HTTP #{response.code}"
    end
  end
end
