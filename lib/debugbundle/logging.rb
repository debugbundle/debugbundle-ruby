# frozen_string_literal: true

require 'logger'

module DebugBundle
  module Logging
    RECURSION_GUARD_KEY = :__debugbundle_logger_capture_active__
    LOGGER_LEVEL_NAMES = {
      ::Logger::DEBUG => :debug,
      ::Logger::INFO => :info,
      ::Logger::WARN => :warning,
      ::Logger::ERROR => :error,
      ::Logger::FATAL => :fatal,
      ::Logger::UNKNOWN => :critical
    }.freeze

    def self.install_stdlib_logger(logger, client:)
      interceptor = Module.new do
        define_method(:add) do |severity, message = nil, progname = nil, &block|
          was_capturing = Thread.current[RECURSION_GUARD_KEY]
          unless was_capturing
            Thread.current[RECURSION_GUARD_KEY] = true
            resolved_message = message
            resolved_message = block.call if resolved_message.nil? && block
            resolved_message = progname if resolved_message.nil?

            client.capture_log(
              resolved_message.to_s,
              level: LOGGER_LEVEL_NAMES.fetch(severity || ::Logger::UNKNOWN, :warning),
              context: { logger_name: logger.progname }
            )
          end

          super(severity, message, progname, &block)
        ensure
          Thread.current[RECURSION_GUARD_KEY] = was_capturing
        end
      end

      logger.singleton_class.prepend(interceptor)
      interceptor
    end

    def self.install_semantic_logger(client:)
      return nil unless defined?(::SemanticLogger)
      return nil unless ::SemanticLogger.respond_to?(:add_appender)

      appender = SemanticLoggerAppender.new(client: client)
      ::SemanticLogger.add_appender(appender: appender)
      appender
    end

    class SemanticLoggerAppender
      def initialize(client: DebugBundle.client)
        @client = client
      end

      def log(log)
        was_capturing = Thread.current[RECURSION_GUARD_KEY]
        return if was_capturing

        Thread.current[RECURSION_GUARD_KEY] = true
        @client.capture_log(
          log.message,
          level: log.level || :info,
          context: {
            logger_name: log.name,
            payload: log.payload,
            tags: log.tags
          }
        )
      ensure
        Thread.current[RECURSION_GUARD_KEY] = was_capturing
      end
    end
  end
end
