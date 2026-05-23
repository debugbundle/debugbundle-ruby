# frozen_string_literal: true

require 'base64'
require 'json'
require 'openssl'

module DebugBundle
  module TriggerToken
    HEADER_NAME = 'x-debugbundle-probe-trigger'
    QUERY_PARAMETER_NAME = '_debug_probe'
    TOKEN_PREFIX = 'dbundle_probe_'

    def self.resolve_request_directives(request:, trigger_token_key:)
      return [] if request.nil? || trigger_token_key.to_s.empty?

      token = extract_token(request)
      return [] unless token&.start_with?(TOKEN_PREFIX)

      payload_segment, signature_segment = split_token(token.delete_prefix(TOKEN_PREFIX))
      return [] unless payload_segment && signature_segment
      return [] unless valid_signature?(payload_segment, signature_segment, trigger_token_key)

      payload = decode_payload(payload_segment)
      return [] unless payload
      return [] if payload[:expires_at] <= Time.now.utc

      [
        RemoteConfig::Directive.new(
          id: payload[:activation_id],
          label_pattern: payload[:label_pattern],
          service: payload[:service],
          environment: payload[:environment],
          expires_at: payload[:expires_at]
        )
      ]
    end

    def self.extract_token(request)
      headers = request[:headers] || request['headers'] || {}
      header_token = extract_map_value(headers, HEADER_NAME, case_insensitive: true)
      return header_token if header_token

      query = request[:query] || request['query'] || {}
      extract_map_value(query, QUERY_PARAMETER_NAME, case_insensitive: false)
    end

    def self.split_token(token)
      separator_index = token.index('.')
      return [nil, nil] unless separator_index&.positive? && separator_index < (token.length - 1)

      [token[0...separator_index], token[(separator_index + 1)..]]
    end

    def self.decode_payload(payload_segment)
      decoded = base64url_decode(payload_segment)
      return nil unless decoded

      parsed = JSON.parse(decoded)
      return nil unless parsed.is_a?(Hash)

      activation_id = parsed['activation_id']
      label_pattern = parsed['label_pattern']
      service = parsed['service']
      environment = parsed['environment']
      expires_at = Time.iso8601(parsed['trigger_expires_at'])

      return nil if [activation_id, label_pattern, service, environment].any? { |value| value.to_s.empty? }

      {
        activation_id: activation_id,
        label_pattern: label_pattern,
        service: service,
        environment: environment,
        expires_at: expires_at
      }
    rescue JSON::ParserError, ArgumentError, TypeError
      nil
    end

    def self.valid_signature?(payload_segment, signature_segment, trigger_token_key)
      expected = OpenSSL::HMAC.digest('sha256', trigger_token_key, payload_segment)
      actual = base64url_decode_bytes(signature_segment)
      return false unless actual && actual.bytesize == expected.bytesize

      secure_compare(expected, actual)
    end

    def self.secure_compare(left, right)
      result = 0
      left.bytes.zip(right.bytes) do |left_byte, right_byte|
        result |= left_byte ^ right_byte
      end
      result.zero?
    end

    def self.extract_map_value(mapping, target_key, case_insensitive:)
      mapping.each do |key, value|
        matches = case_insensitive ? key.to_s.downcase == target_key.downcase : key.to_s == target_key
        next unless matches

        return value if value.is_a?(String) && !value.empty?
        return value.first if value.is_a?(Array) && value.first.is_a?(String) && !value.first.empty?
      end

      nil
    end

    def self.base64url_decode(value)
      decoded = base64url_decode_bytes(value)
      decoded&.force_encoding('UTF-8')
    end

    def self.base64url_decode_bytes(value)
      padded = value.dup
      remainder = padded.length % 4
      padded += '=' * (4 - remainder) if remainder.positive?
      Base64.urlsafe_decode64(padded)
    rescue ArgumentError
      nil
    end
  end
end
