# frozen_string_literal: true

if defined?(Rails::Railtie)
  module DebugBundle
    module Rails
      class Railtie < ::Rails::Railtie
        config.debugbundle = ActiveSupport::OrderedOptions.new

        initializer 'debugbundle.configure' do |app|
          options = app.config.debugbundle
          next if options.respond_to?(:enabled) && options.enabled == false

          client = DebugBundle.init(
            project_token: options.project_token || ENV.fetch('DEBUGBUNDLE_TOKEN', nil),
            service: options.service || app.class.module_parent_name.underscore.tr('_', '-'),
            environment: options.environment || ::Rails.env,
            project_mode: options.project_mode || :connected,
            local_events_dir: options.local_events_dir || DebugBundle::Config::DEFAULT_LOCAL_EVENTS_DIR,
            endpoint: options.endpoint || DebugBundle::Config::DEFAULT_ENDPOINT,
            redact_fields: Array(options.redact_fields) + Array(app.config.filter_parameters)
          )

          app.middleware.use(DebugBundle::Rack::Middleware, client: client)
          if DebugBundle::Rails.relay_route_enabled?(app)
            app.routes.append do
              match DebugBundle::Rails.relay_path(app),
                    to: DebugBundle::Rails::RelayEndpoint.new(app: app),
                    via: :options
              post DebugBundle::Rails.relay_path(app), to: DebugBundle::Rails::RelayEndpoint.new(app: app)
            end
          end
          DebugBundle.capture_logger(::Rails.logger) if ::Rails.logger
          DebugBundle.capture_semantic_logger if defined?(::SemanticLogger)
        end
      end
    end
  end
end
