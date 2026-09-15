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
        %i[add log].each do |method_name|
          define_method(method_name) do |severity, message = nil, progname = nil, &block|
            normalized_severity = severity || ::Logger::UNKNOWN
            # Match Logger's early return, including Rails' thread-local level.
            disabled = normalized_severity < level || (is_a?(::Logger) && instance_variable_get(:@logdev).nil?)
            next super(severity, message, progname, &block) if disabled || Thread.current[RECURSION_GUARD_KEY]

            resolved_message = message
            resolved_message = progname.nil? ? self.progname : progname if message.nil?
            result = if message.nil? && block
                       super(severity, message, progname) { resolved_message = block.call }
                     else
                       super(severity, message, progname)
                     end
            DebugBundle::Logging.capture_stdlib(client, resolved_message, normalized_severity, self.progname)
            result
          end
        end
      end

      logger.singleton_class.prepend(interceptor)
      interceptor
    end

    def self.capture_stdlib(client, message, severity, progname)
      was_capturing = Thread.current[RECURSION_GUARD_KEY]
      Thread.current[RECURSION_GUARD_KEY] = true
      client.capture_log(
        message.to_s,
        level: LOGGER_LEVEL_NAMES.fetch(severity, :warning),
        context: { logger_name: progname }
      )
    rescue StandardError
      # SDK failures must not change the result of the application's logger.
      nil
    ensure
      Thread.current[RECURSION_GUARD_KEY] = was_capturing
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
