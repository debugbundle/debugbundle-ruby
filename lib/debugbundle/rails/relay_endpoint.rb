# frozen_string_literal: true

module DebugBundle
  module Rails
    class RelayEndpoint
      def initialize(app:, handler: nil)
        @app = app
        @handler = handler
      end

      def call(env)
        middleware.call(env)
      end

      private

      def middleware
        @middleware ||= DebugBundle::Rack::RelayMiddleware.new(nil, handler: @handler || DebugBundle::Rails.build_relay_handler(@app))
      end
    end

    def self.build_relay_handler(app)
      options = relay_options(app)
      return options.relay_handler if relay_option_present?(options, :relay_handler)

      Relay::Handler.new(
        project_mode: relay_option(options, :project_mode, :connected),
        project_token: relay_option(options, :project_token, ENV.fetch('DEBUGBUNDLE_TOKEN', nil)),
        endpoint: relay_option(options, :endpoint, DebugBundle::Config::DEFAULT_ENDPOINT),
        local_events_dir: relay_option(options, :local_events_dir, DebugBundle::Config::DEFAULT_LOCAL_EVENTS_DIR),
        spool_dir: relay_option(options, :spool_dir, DebugBundle::Config::DEFAULT_SPOOL_DIR),
        durable_write: relay_durable_write(options),
        service: relay_service_name(app, options),
        environment: relay_environment_name(options),
        allowed_origins: relay_option(options, :relay_allowed_origins, nil),
        max_body_bytes: relay_option(options, :relay_max_body_bytes, Relay::DEFAULT_MAX_BODY_BYTES),
        rate_limit_per_minute: relay_rate_limit(options),
        rate_limit_store: relay_option(options, :relay_rate_limit_store, nil),
        forward_transport: relay_option(options, :relay_forward_transport, nil)
      )
    end

    def self.relay_route_enabled?(app)
      options = relay_options(app)
      relay_option(options, :relay_enabled, true) != false
    end

    def self.relay_path(app)
      options = relay_options(app)
      path = relay_option(options, :relay_path, '').to_s
      path.empty? ? '/debugbundle/browser' : path
    end

    def self.relay_options(app)
      return nil unless app.respond_to?(:config)
      return nil unless app.config.respond_to?(:debugbundle)

      app.config.debugbundle
    end

    def self.relay_durable_write(options)
      relay_option(options, :relay_durable_write, true) != false
    end

    def self.relay_rate_limit(options)
      relay_option(options, :relay_rate_limit_per_minute, Relay::DEFAULT_RATE_LIMIT_PER_MINUTE)
    end

    def self.relay_service_name(app, options)
      service_name = relay_option(options, :service, nil)
      return service_name if service_name && !service_name.to_s.empty?

      if app.class.respond_to?(:module_parent_name)
        app_name = app.class.module_parent_name.to_s
        return app_name.underscore.tr('_', '-') unless app_name.empty?
      end

      Client::DEFAULT_SERVICE_NAME
    end

    def self.relay_environment_name(options)
      environment_name = relay_option(options, :environment, nil)
      return environment_name if environment_name && !environment_name.to_s.empty?
      return ::Rails.env if defined?(::Rails)

      Client::DEFAULT_ENVIRONMENT
    end

    def self.relay_option(options, name, default)
      return default if options.nil? || !options.respond_to?(name)

      value = options.public_send(name)
      value.nil? ? default : value
    end

    def self.relay_option_present?(options, name)
      !options.nil? && options.respond_to?(name) && !options.public_send(name).nil?
    end
  end
end
