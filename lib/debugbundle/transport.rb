# frozen_string_literal: true

require 'json'
require 'net/http'
require 'securerandom'
require 'uri'
require 'time'
require 'fileutils'
require 'debugbundle/bounded_http_response'

module DebugBundle
  module Transport
    RETRY_AFTER_CAP_SECONDS = 300

    Result = Struct.new(:status_code, :retry_after_seconds, :body, :written_file_path, keyword_init: true)

    def self.sdk_config_endpoint(events_endpoint)
      uri = URI.parse(events_endpoint)
      normalized_path = uri.path.to_s.sub(%r{/+$}, '')
      uri.path = if normalized_path.end_with?('/sdk/config')
                   normalized_path
                 elsif normalized_path.end_with?('/events')
                   normalized_path.sub(%r{/events\z}, '/sdk/config')
                 else
                   "#{normalized_path}/sdk/config"
                 end
      uri.query = nil
      uri.fragment = nil
      uri.to_s
    rescue URI::InvalidURIError
      events_endpoint.to_s.sub(%r{/events\z}, '/sdk/config')
    end

    def self.coerce_result(result)
      return result if result.is_a?(Result)

      raise TypeError, 'unsupported transport result' unless result.respond_to?(:status_code)

      Result.new(
        status_code: result.status_code.to_i,
        retry_after_seconds: result.respond_to?(:retry_after_seconds) ? result.retry_after_seconds : nil,
        body: result.respond_to?(:body) ? result.body : nil
      )
    end

    class HttpTransport
      def initialize(endpoint)
        @uri = URI.parse(endpoint)
      end

      def call(request)
        deadline = request.fetch(:deadline) { Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5 }
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return Result.new(status_code: 500) unless remaining.positive?

        body = JSON.generate(events: request.fetch(:events))
        return Result.new(status_code: 413) if body.bytesize > 262_144

        http = Net::HTTP.new(@uri.host, @uri.port)
        http.use_ssl = @uri.scheme == 'https'
        http.open_timeout = remaining
        http.read_timeout = remaining

        response, raw = BoundedHttpResponse.read(deadline: deadline) do |consume|
          http.post(
            @uri.request_uri,
            body,
            {
              'Authorization' => "Bearer #{request.fetch(:project_token)}",
              'Content-Type' => 'application/json',
              'Accept-Encoding' => 'identity',
              'X-DebugBundle-Evidence' => '1'
            }, &consume
          )
        end

        Result.new(
          status_code: response.code.to_i,
          retry_after_seconds: parse_retry_after(response['Retry-After']),
          body: parse_body(raw)
        )
      rescue StandardError
        Result.new(status_code: 500)
      end

      private

      def parse_body(body)
        return nil if body.to_s.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        body
      end

      def parse_retry_after(value)
        return nil if value.nil? || value.strip.empty?

        seconds = Float(value, exception: false)
        seconds = Time.httpdate(value) - Time.now if seconds.nil?
        return nil unless seconds.finite?

        seconds.clamp(0, RETRY_AFTER_CAP_SECONDS).to_i
      rescue ArgumentError, TypeError
        nil
      end
    end

    class HttpConfigFetcher
      def initialize(endpoint, project_token:, sdk_name:, sdk_version:)
        @uri = URI.parse(Transport.sdk_config_endpoint(endpoint))
        @project_token = project_token
        @sdk_name = sdk_name
        @sdk_version = sdk_version
      end

      def call(etag = nil)
        http = Net::HTTP.new(@uri.host, @uri.port)
        http.use_ssl = @uri.scheme == 'https'
        http.open_timeout = 5
        http.read_timeout = 5

        request = Net::HTTP::Get.new(@uri.request_uri, 'Accept-Encoding' => 'identity')
        request['Authorization'] = "Bearer #{@project_token}"
        request['Accept'] = 'application/json'
        request['X-DebugBundle-SDK'] = @sdk_name
        request['X-DebugBundle-SDK-Version'] = @sdk_version
        request['If-None-Match'] = etag if etag
        request['X-DebugBundle-Evidence'] = '1'

        response, raw = BoundedHttpResponse.read do |consume|
          http.request(request) { |reply| reply.read_body(&consume) }
        end
        body = raw.empty? ? {} : JSON.parse(raw)
        { status_code: response.code.to_i, etag: response['ETag'], body: body }
      rescue StandardError
        { status_code: 500, body: {} }
      end
    end

    class FileTransport
      FILE_MODE = 0o600
      DIRECTORY_MODE = 0o700

      def initialize(directory)
        @raw_directory = directory.to_s
        @directory = File.expand_path(directory)
      end

      def call(request)
        ensure_secure_directory!(@directory)

        timestamp = Time.now.utc.strftime('%Y%m%dT%H%M%S')
        service_fragment = request.fetch(:service_name, 'service').to_s.gsub(/[^a-zA-Z0-9_-]+/, '-')
        token_fragment = SecureRandom.hex(12)
        temp_path = File.join(@directory, "#{timestamp}-#{token_fragment}.tmp")
        final_path = File.join(@directory, "#{timestamp}-#{token_fragment}-#{service_fragment}.events.json")

        payload = JSON.generate(
          request.fetch(:events)
        )

        write_secure_file(temp_path, payload)
        reject_symlink!(final_path)
        File.rename(temp_path, final_path)
        File.chmod(FILE_MODE, final_path)

        Result.new(status_code: 202, written_file_path: final_path)
      rescue StandardError
        Result.new(status_code: 500)
      ensure
        File.delete(temp_path) if defined?(temp_path) && temp_path && File.exist?(temp_path)
      end

      def mark_delivered(path)
        ensure_secure_directory!(@directory)
        return false unless File.dirname(File.expand_path(path)) == @directory && path.end_with?('.events.json')
        return false unless File.file?(path) && !File.symlink?(path)

        write_secure_file("#{path}.delivered", '')
        true
      rescue StandardError
        false
      end

      private

      def ensure_secure_directory!(directory)
        parent = File.dirname(directory)
        raise ArgumentError, 'invalid directory' if @raw_directory.split(%r{[\\/]+}).include?('..')
        raise ArgumentError, 'invalid directory' if directory.include?('..')

        ensure_existing_path_is_not_symlink!(parent)
        FileUtils.mkdir_p(directory, mode: DIRECTORY_MODE)
        ensure_existing_path_is_not_symlink!(directory)
        File.chmod(DIRECTORY_MODE, directory)
      end

      def ensure_existing_path_is_not_symlink!(path)
        current = File.expand_path(path)

        loop do
          break unless File.exist?(current)

          reject_symlink!(current)
          parent = File.dirname(current)
          break if parent == current

          current = parent
        end
      end

      def reject_symlink!(path)
        return unless File.exist?(path)

        raise IOError, 'symlink_path_rejected' if File.lstat(path).symlink?
      end

      def write_secure_file(path, payload)
        flags = File::WRONLY | File::CREAT | File::EXCL
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags, FILE_MODE) do |handle|
          handle.write(payload)
          handle.flush
          handle.fsync
        end
      end
    end
  end
end
