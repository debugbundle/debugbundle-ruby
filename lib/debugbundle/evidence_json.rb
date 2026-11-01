# frozen_string_literal: true

require 'json'
require 'debugbundle/evidence_value'

module DebugBundle
  module EvidenceJson
    module_function

    def bytes(value)
      owned = EvidenceValue.copy(value)
      owned.equal?(EvidenceValue::INVALID) ? 32_769 : count(owned)
    rescue StandardError
      32_769
    end

    def count(value)
      case value
      when Hash
        2 + [0, value.length - 1].max + value.sum { |key, item| count(key) + 1 + count(item) }
      when Array
        2 + [0, value.length - 1].max + value.sum { |item| count(item) }
      when Integer, Float then number_bytes(value)
      else JSON.generate(value).bytesize
      end
    end

    def number_bytes(value)
      return value.to_s.length if value.is_a?(Integer) && value.abs <= 9_007_199_254_740_991

      number = value.to_f
      return 32_769 unless number.finite?
      return 1 if number.zero?

      mantissa, exponent = number.abs.to_s.downcase.split('e', 2)
      raw = mantissa.delete('.')
      leading = raw.length - raw.sub(/\A0+/, '').length
      digits = raw.sub(/\A0+/, '').sub(/0+\z/, '')
      position = mantissa.split('.', 2).first.length + (exponent || '0').to_i - leading
      power = position - 1
      length = if power.between?(-6, 20)
                 decimal_bytes(position, digits.length)
               else
                 digits.length + (digits.length > 1 ? 1 : 0) + 2 + power.abs.to_s.length
               end
      length + (number.negative? ? 1 : 0)
    end

    def decimal_bytes(position, digits)
      return 2 - position + digits if position <= 0

      [position, digits].max + (position < digits ? 1 : 0)
    end
  end
end
