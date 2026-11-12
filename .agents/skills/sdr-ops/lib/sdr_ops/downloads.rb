# frozen_string_literal: true

module SdrOps
  # File downloads shared by `files fetch` and `clone`. Items are Hashes with :filename and :local_path, plus the
  # expected :md5 and optionally :sha1 and :size; every download is verified against whichever are present.
  module Downloads
    module_function

    def stacks_url(environment, druid, filename, version: nil)
      escaped = filename.split('/').map { ERB::Util.url_encode(it) }.join('/')
      bare = Druid.bare(druid)
      path = version ? "v2/file/#{bare}/version/#{version}/#{escaped}" : "file/#{bare}/#{escaped}"
      "#{environment.stacks_url}/#{path}"
    end

    # Only works for shelved, world-downloadable files; stanford-only files need a browser session on stacks.
    def from_stacks(environment, druid, items, version: nil)
      items.each do |item|
        http(stacks_url(environment, druid, item[:filename], version:), item[:local_path])
        verify!(item)
      end
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

    def http(url, local_path, redirects: 5)
      uri = URI(url)
      FileUtils.mkdir_p(File.dirname(local_path))
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.request(Net::HTTP::Get.new(uri)) do |response|
          case response
          when Net::HTTPSuccess
            File.open(local_path, 'wb') { |file| response.read_body { |chunk| file.write(chunk) } }
          when Net::HTTPRedirection
            raise Error, "Too many redirects fetching #{url}" if redirects.zero?

            return http(URI.join(url, response['location']).to_s, local_path, redirects: redirects - 1)
          else
            raise Error, "#{url} returned HTTP #{response.code}"
          end
        end
      end
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
