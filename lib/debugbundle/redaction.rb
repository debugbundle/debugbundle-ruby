# frozen_string_literal: true

require 'date'

module DebugBundle
  module Redaction
    REDACTED_VALUE = '[REDACTED]'
    CIRCULAR_VALUE = '[Circular]'
    TRUNCATED_DEPTH_VALUE = '[Truncated:depth]'
    TRUNCATED_COLLECTION_VALUE = '[Truncated:collection]'
    DEFAULT_MAX_DEPTH = 5
    DEFAULT_MAX_STRING_LENGTH = 1_024
    DEFAULT_MAX_ARRAY_LENGTH = 50
    DEFAULT_MAX_HASH_KEYS = 50
    DEFAULT_SENSITIVE_FIELDS = %w[
      password
      secret
      token
      api_key
      apikey
      access_token
      refresh_token
      private_key
      passwd
      card_number
      credit_card
      cvv
      cvc
      pin
      expiry
      phone
      bearer
      session_id
      otp
      verification_code
      authorization
      cookie
      ssn
    ].freeze

    class Redactor
      def initialize(
        sensitive_fields: DEFAULT_SENSITIVE_FIELDS,
        max_depth: DEFAULT_MAX_DEPTH,
        max_string_length: DEFAULT_MAX_STRING_LENGTH,
        max_array_length: DEFAULT_MAX_ARRAY_LENGTH,
        max_hash_keys: DEFAULT_MAX_HASH_KEYS
      )
        @sensitive_terms = sensitive_fields.map { |field| compile_sensitive_term(field) }
        @max_depth = max_depth
        @max_string_length = max_string_length
        @max_array_length = max_array_length
        @max_hash_keys = max_hash_keys
      end

      def redact_value(value)
        sanitize(value, depth: 0, seen: {}.compare_by_identity)
      end

      private

      def sanitize(value, depth:, seen:)
        return TRUNCATED_DEPTH_VALUE if depth >= @max_depth

        case value
        when NilClass, TrueClass, FalseClass, Numeric
          value
        when String
          truncate_string(value)
        when Symbol
          truncate_string(value.to_s)
        when Time, DateTime
          value.iso8601
        when Array
          return CIRCULAR_VALUE if circular?(value, seen)

          mark_seen(value, seen)
          value.first(@max_array_length).map { |item| sanitize(item, depth: depth + 1, seen: seen) }.tap do |items|
            items << TRUNCATED_COLLECTION_VALUE if value.length > @max_array_length
          end
        when Hash
          return CIRCULAR_VALUE if circular?(value, seen)

          mark_seen(value, seen)
          sanitize_hash(value, depth: depth + 1, seen: seen)
        else
          if value.respond_to?(:to_h)
            sanitize(value.to_h, depth: depth + 1, seen: seen)
          elsif value.respond_to?(:to_hash)
            sanitize(value.to_hash, depth: depth + 1, seen: seen)
          else
            truncate_string(value.to_s)
          end
        end
      end

      def sanitize_hash(value, depth:, seen:)
        value.each_with_index.with_object({}) do |((key, nested_value), index), result|
          break result if index >= @max_hash_keys

          key_string = key.to_s
          result[key_string] =
            sensitive_key?(key_string) ? REDACTED_VALUE : sanitize(nested_value, depth: depth, seen: seen)
        end.tap do |result|
          result['__truncated__'] = TRUNCATED_COLLECTION_VALUE if value.size > @max_hash_keys
        end
      end

      def truncate_string(value)
        return value if value.length <= @max_string_length

        value[0, @max_string_length] + TRUNCATED_COLLECTION_VALUE
      end

      def sensitive_key?(key)
        segments, joined = normalize_key(key)

        @sensitive_terms.any? do |term|
          joined == term[:joined] || contains_contiguous_segments?(segments, term[:segments])
        end
      end

      def contains_contiguous_segments?(segments, target_segments)
        return false if target_segments.empty? || segments.empty? || target_segments.length > segments.length

        segments.each_index.any? do |index|
          segments[index, target_segments.length] == target_segments
        end
      end

      def normalize_key(key)
        underscored = key.to_s.gsub(/([a-z\d])([A-Z])/, '\\1_\\2').downcase
        segments = underscored.split(/[^a-z0-9]+/).reject(&:empty?)
        [segments, segments.join]
      end

      def compile_sensitive_term(term)
        segments, joined = normalize_key(term)
        { segments: segments, joined: joined }
      end

      def circular?(value, seen)
        seen.key?(value)
      end

      def mark_seen(value, seen)
        seen[value] = true
      end
    end
  end
end
