# frozen_string_literal: true

require_relative 'debugbundle/redaction'
require_relative 'debugbundle/acknowledgement'
require_relative 'debugbundle/before_send'
require_relative 'debugbundle/rack/middleware'
require_relative 'debugbundle/logging'
require_relative 'debugbundle/remote_config'
require_relative 'debugbundle/relay'
require_relative 'debugbundle/rails/relay_endpoint'
require_relative 'debugbundle/sidekiq/server_middleware'
require_relative 'debugbundle/suppression'
require_relative 'debugbundle/transport'
require_relative 'debugbundle/trigger_token'
require_relative 'debugbundle/client'
require_relative 'debugbundle/config'
require_relative 'debugbundle/version'

require_relative 'debugbundle/rails' if defined?(Rails::Railtie)

module DebugBundle
  class << self
    def init(**options)
      self.client = Client.new(**options)
      client.capture_exceptions
      client
    end

    def client
      @client ||= Client.new
    end

    attr_writer :client

    def capture_exception(error, context: nil)
      client.capture_exception(error, context: context)
    end

    def capture_error(error, context: nil)
      client.capture_error(error, context: context)
    end

    def capture_log(message, level: :warning, context: nil)
      client.capture_log(message, level: level, context: context)
    end

    def capture_request(request, response, context: nil)
      client.capture_request(request, response, context: context)
    end

    def capture_message(message, level: nil, context: nil)
      client.capture_message(message, level: level, context: context)
    end

    def set_context(key, value)
      client.set_context(key, value)
    end

    def probe(label, data = nil, heavy: false, &block)
      client.probe(label, data, heavy: heavy, &block)
    end

    def capture_exceptions
      client.capture_exceptions
    end

    def capture_at_exit
      client.capture_at_exit
    end

    def with_exception_capture(context: nil, &block)
      client.with_exception_capture(context: context, &block)
    end

    def capture_logger(logger = ::Logger.new($stdout))
      client.capture_logger(logger)
    end

    def capture_semantic_logger
      client.capture_semantic_logger
    end

    def flush
      client.flush
    end

    def status
      client.status
    end

    def last_event_at
      client.last_event_at
    end
  end
end
