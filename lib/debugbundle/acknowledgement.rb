# frozen_string_literal: true

module DebugBundle
  module Acknowledgement
    RETRYABLE_REASONS = %w[
      rate_limited
      monthly_quota_exceeded
      analytics_quota_exceeded
    ].freeze
    FIELDS = %w[accepted rejected errors].freeze

    module_function

    def decide(body, batch_length)
      return { kind: :legacy } unless body.is_a?(Hash) && FIELDS.any? { |field| body.key?(field) }
      return protocol_failure unless FIELDS.all? { |field| body.key?(field) }

      accepted = body['accepted']
      rejected = body['rejected']
      errors = body['errors']
      return protocol_failure unless count?(accepted) && count?(rejected) && errors.is_a?(Array)
      return protocol_failure unless accepted + rejected == batch_length && errors.length == rejected

      seen = {}
      retryable_indices = []
      terminal_errors = []
      errors.each do |error|
        return protocol_failure unless error.is_a?(Hash)

        index = error['index']
        reason = error['reason']
        return protocol_failure unless index.is_a?(Integer) && index.between?(0, batch_length - 1)
        return protocol_failure unless reason.is_a?(String) && !reason.empty? && !seen[index]

        seen[index] = true
        if RETRYABLE_REASONS.include?(reason)
          retryable_indices << index
        else
          terminal_errors << [index, reason]
        end
      end

      {
        kind: :acknowledged,
        accepted: accepted,
        retryable_indices: retryable_indices,
        terminal_errors: terminal_errors
      }
    end

    def count?(value)
      value.is_a?(Integer) && value >= 0
    end

    def protocol_failure
      { kind: :protocol_failure }
    end
  end
end
