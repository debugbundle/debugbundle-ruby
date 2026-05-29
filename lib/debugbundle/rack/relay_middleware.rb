# frozen_string_literal: true

require 'stringio'

module DebugBundle
  module Rack
    class RelayMiddleware
      def initialize(app = nil, handler: DebugBundle::Relay::Handler.new)
        @app = app
        @handler = handler
      end

      def call(env)
        response = @handler.handle(
          method: env['REQUEST_METHOD'],
          headers: relay_headers(env),
          body: env.fetch('rack.input', StringIO.new).read,
          ip_address: env['REMOTE_ADDR']
        )

        body = response.body ? JSON.generate(response.body) : ''
        [response.status, { 'Content-Type' => 'application/json' }.merge(response.headers || {}), [body]]
      end

      private

      def relay_headers(env)
        env.each_with_object({}) do |(key, value), headers|
          next unless key.start_with?('HTTP_') || %w[CONTENT_TYPE HOST REFERER].include?(key)

          normalized_key = key.sub(/^HTTP_/, '').downcase.tr('_', '-')
          headers[normalized_key] = value
        end
      end
    end
  end
end
