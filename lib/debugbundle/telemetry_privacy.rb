# frozen_string_literal: true

require 'json'
require 'uri'

module DebugBundle
  # Mandatory bounded policy for application data; protocol-owned identifiers stay outside this projection.
  module TelemetryPrivacy
    REDACTED = '[REDACTED]'
    MAX_BYTES = 262_144
    FIELDS = %w[
      password secret token api_key apikey access_token refresh_token private_key passwd
      card_number credit_card cvv cvc pin expiry phone bearer session_id otp
      verification_code authorization cookie ssn client_secret x_api_key set_cookie
      proxy_authorization accessToken refreshToken privateKey clientSecret
    ].freeze
    ASSIGNMENT_VALUE_PATTERN = '(?:"[^"]*"|\'[^\']*\'|[^\s&,;]+)'
    DEFAULT_ASSIGNMENT_PATTERN = Regexp.new(
      "\\b(#{FIELDS.map { |field| Regexp.escape(field) }.join('|')})\\b([\"']?\\s*[:=]\\s*)#{ASSIGNMENT_VALUE_PATTERN}",
      Regexp::IGNORECASE
    )

    module_function

    def protect(value, additional_fields: [])
      raise ArgumentError, 'unsafe_input' if additional_fields.length > 128
      unless additional_fields.all? { |field| field.is_a?(String) && field.length.between?(1, 64) }
        raise ArgumentError, 'unsafe_input'
      end

      work = { nodes: 0, bytes: 0, seen: {}.compare_by_identity,
               fields: (FIELDS + additional_fields).map { |field| canonical(field) },
               extra: additional_fields,
               assignment_pattern: assignment_pattern(additional_fields) }
      result = visit(value, work, 0, true)
      raise ArgumentError, 'budget_exceeded' if JSON.generate(result).bytesize > MAX_BYTES

      result
    rescue JSON::GeneratorError, Encoding::InvalidByteSequenceError
      raise ArgumentError, 'unsafe_input'
    end

    def safe_event_identity?(event, additional_fields: [])
      correlation = event['correlation'] || {}
      return false unless correlation.is_a?(Hash) && correlation.size <= 8

      values = event.values_at('schema_version', 'sdk_name', 'sdk_version') + correlation.values
      values.all? do |value|
        value.nil? || (value.is_a?(String) && protect(value, additional_fields: additional_fields) == value)
      end
    end

    def canonical(value)
      value.downcase.gsub(/[^a-z0-9]/, '')
    end

    def assignment_pattern(additional_fields)
      return DEFAULT_ASSIGNMENT_PATTERN if additional_fields.empty?

      terms = (FIELDS + additional_fields).map { |field| Regexp.escape(field) }.join('|')
      Regexp.new("\\b(#{terms})\\b([\"']?\\s*[:=]\\s*)#{ASSIGNMENT_VALUE_PATTERN}", Regexp::IGNORECASE)
    end

    def sensitive_key?(key, fields)
      segments = key.gsub(/([a-z0-9])([A-Z])/, '\\1_\\2').downcase.split(/[^a-z0-9]+/)
      segments.each_index.any? do |start|
        combined = +''
        segments.drop(start).any? do |segment|
          combined << segment
          fields.include?(combined)
        end
      end
    end

    def visit(value, work, depth, structured)
      work[:nodes] += 1
      raise ArgumentError, 'budget_exceeded' if work[:nodes] > 4096
      return REDACTED if depth > 16

      case value
      when String then string(value, work, structured)
      when Hash, Array then collection(value, work, depth, structured)
      when NilClass, TrueClass, FalseClass, Integer then value
      when Float
        raise ArgumentError, 'unsafe_input' unless value.finite?

        value
      else
        raise ArgumentError, 'unsafe_input'
      end
    end

    def collection(value, work, depth, structured)
      marked = false
      return '[Circular]' if work[:seen].key?(value)
      return REDACTED if value.length > 256

      work[:seen][value] = true
      marked = true
      if value.is_a?(Array)
        value.map { |item| visit(item, work, depth + 1, structured) }
      else
        value.each_with_object({}) do |(key, nested), result|
          raise ArgumentError, 'unsafe_input' unless key.is_a?(String) || key.is_a?(Symbol)

          name = key.to_s
          next if name.bytesize > 128

          count_bytes(work, name)
          next if scrub_text(name, work) != name

          result[name] = sensitive_key?(name, work[:fields]) ? REDACTED : visit(nested, work, depth + 1, structured)
        end
      end
    ensure
      work[:seen].delete(value) if marked
    end

    def count_bytes(work, value)
      work[:bytes] += value.bytesize
      raise ArgumentError, 'budget_exceeded' if work[:bytes] > MAX_BYTES
    end

    def string(value, work, structured)
      raise ArgumentError, 'unsafe_input' unless value.valid_encoding?
      return REDACTED if value.bytesize > 16_384

      count_bytes(work, value)
      if structured && value.start_with?('{', '[')
        begin
          nested = JSON.parse(value, max_nesting: 17)
          return JSON.generate(visit(nested, work, 0, false)) if nested.is_a?(Hash) || nested.is_a?(Array)
        rescue JSON::ParserError
          # Malformed structured content with a credential label is withheld below.
        end
      end
      result = scrub_text(value, work)
      return REDACTED if result == value && value.start_with?('{', '[') &&
                         /(?:password|token|secret|authorization|cookie)["']?\s*[:=]/i.match?(value)

      result
    end

    def valid_card?(candidate)
      digits = candidate.delete(' -')
      return false unless digits.length.between?(13, 19) && digits.chars.uniq.length > 1

      digits.reverse.chars.each_with_index.sum do |char, index|
        number = char.to_i * (index.odd? ? 2 : 1)
        number > 9 ? number - 9 : number
      end.modulo(10).zero?
    end

    def scrub_text(value, work, scan_urls: true)
      return REDACTED if /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/i.match?(value) &&
                         !/-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/i.match?(value)

      result = value
      if /(?:password|token|secret|authorization|cookie)%3[ad]/i.match?(result)
        result = URI.decode_www_form_component(result)
      end
      pem = /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/i
      result = result.gsub(pem, REDACTED)
      result = result.gsub(/\b(Authorization|Proxy-Authorization|Cookie|Set-Cookie)\s*:\s*[^\r\n]*/i, '\\1: [REDACTED]')
      result = result.gsub(%r{\b(Bearer|Basic)\s+[A-Za-z0-9._~+/-]{6,}}i, '\\1 [REDACTED]')
      result = result.gsub(/\bdbundle_(?:proj|mem|probe|agent)_[A-Za-z0-9_-]+\b/, REDACTED)
      result = result.gsub(work[:assignment_pattern], '\\1\\2[REDACTED]')
      result = result.gsub(/(?<![A-Za-z0-9_-])(?:[0-9][ -]?){12,18}[0-9](?![A-Za-z0-9_-])/) do |candidate|
        valid_card?(candidate) ? REDACTED : candidate
      end
      return result unless scan_urls

      result.gsub(%r{\bhttps?://[^\s<>"']+}i) do |candidate|
        raw = candidate.sub(/[).,;]+\z/, '')
        scrub_url(raw, work) + candidate.delete_prefix(raw)
      end
    rescue URI::InvalidURIError, ArgumentError
      REDACTED
    end

    def scrub_url(raw, work)
      uri = URI.parse(raw)
      return REDACTED unless uri.host

      if uri.userinfo
        uri.user = 'REDACTED'
        uri.password = nil
      end
      uri.path = '/' if uri.path.empty?
      if uri.query
        uri.query = URI.encode_www_form(URI.decode_www_form(uri.query).filter_map do |key, value|
          next if key.bytesize > 128 || scrub_text(key, work, scan_urls: false) != key

          unsafe = sensitive_key?(key, work[:fields]) || scrub_text(value, work, scan_urls: false) != value
          [key, unsafe ? REDACTED : value]
        end)
      end
      uri.fragment = nil
      uri.to_s
    rescue URI::InvalidURIError
      REDACTED
    end
  end
end
