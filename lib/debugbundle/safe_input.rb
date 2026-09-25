# frozen_string_literal: true

require 'uri'

module DebugBundle
  # Built-in scalar extraction for capture paths that must not run application renderers.
  module SafeInput
    module_function

    def key(value)
      is_a = Object.instance_method(:is_a?)
      return String.instance_method(:[]).bind_call(value, 0, 128) if is_a.bind_call(value, String)
      return Symbol.instance_method(:to_s).bind_call(value)[0, 128] if is_a.bind_call(value, Symbol)

      if is_a.bind_call(value, Integer) && Integer.instance_method(:bit_length).bind_call(value) <= 512
        return Integer.instance_method(:to_s).bind_call(value)
      end

      nil
    rescue StandardError
      nil
    end

    def request_path(value)
      return '/' unless Object.instance_method(:is_a?).bind_call(value, String)

      raw = String.instance_method(:[]).bind_call(value, 0, 2_048)
      begin
        uri = URI.parse(raw)
        return uri.path if uri.path && !uri.path.empty?
      rescue URI::InvalidURIError
        # Fall through to the bounded path-only fallback.
      end
      fallback = raw.split('?', 2).first.to_s.split('#', 2).first
      fallback.start_with?('/') && !fallback.empty? ? fallback : '/'
    rescue StandardError
      '/'
    end
  end
end
