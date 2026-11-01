# frozen_string_literal: true

module DebugBundle
  module EvidenceResources
    module_function

    def valid?(value)
      wire = EvidenceWire
      wire.closed(value, %w[version items]) && wire.integer(value['version'], 1, 1) &&
        value['items'].is_a?(Array) && value['items'].length.between?(1, 5) &&
        value['items'].all? { |item| valid_item?(item) } && EvidenceJson.bytes(value) <= 32_768
    end

    def valid_item?(item)
      wire = EvidenceWire
      return false unless item.is_a?(Hash) && wire.timestamp(item['observed_at']) && item.key?('source_url')
      return false unless item['source_url'].nil? || url?(item['source_url'])

      case item['kind']
      when 'timing' then valid_timing?(item)
      when 'csp' then valid_csp?(item)
      else false
      end
    end

    def valid_timing?(item)
      wire = EvidenceWire
      wire.closed(item,
                  %w[kind observed_at source_url availability response_status duration_ms transfer_size_bytes]) &&
        %w[observed unsupported no_match withheld ambiguous unknown].include?(item['availability']) &&
        (item['response_status'].nil? || wire.integer(item['response_status'], 100, 599)) &&
        (item['duration_ms'].nil? || wire.number(item['duration_ms'])) &&
        (item['transfer_size_bytes'].nil? || wire.integer(item['transfer_size_bytes'], 0))
    end

    def valid_csp?(item)
      wire = EvidenceWire
      wire.closed(item, %w[kind observed_at source_url effective_directive disposition document_status_code]) &&
        wire.text(item['effective_directive'], 64) && /\A[a-z-]{1,64}\z/.match?(item['effective_directive']) &&
        %w[enforce report].include?(item['disposition']) &&
        (item['document_status_code'].nil? || wire.integer(item['document_status_code'], 100, 599))
    end

    def url?(value)
      return false unless EvidenceWire.text(value, 2048) && !value.empty?
      return false if value.start_with?('//') || value.match?(/[\x00-\x20\x7f\\?#]/)
      return false unless value.start_with?('/') || value.match?(%r{\Ahttps?://}i)
      return true if value.start_with?('/')

      # URI validates an ASCII representation; retain the original resource identity.
      ascii = value.gsub(/[^\x00-\x7f]/) { |char| char.bytes.map { |byte| format('%%%02X', byte) }.join }
      uri = URI.parse(ascii)
      return false if !value.start_with?('/') && (uri.host.nil? || uri.host.empty?)

      [nil, ''].include?(uri.user) && [nil, ''].include?(uri.password) && uri.query.nil? && uri.fragment.nil?
    rescue URI::InvalidURIError
      false
    end
  end
end
