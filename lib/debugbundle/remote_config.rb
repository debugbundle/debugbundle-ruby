# frozen_string_literal: true

require 'time'

module DebugBundle
  module RemoteConfig
    CapturePolicy = Struct.new(
      :preset,
      :capture_logs,
      :capture_request_events,
      :capture_breadcrumbs,
      :capture_probe_events,
      :immediate_client_error_statuses,
      keyword_init: true
    )

    Directive = Struct.new(:id, :label_pattern, :service, :environment, :expires_at, keyword_init: true) do
      def active?(label:, service:, environment:, now:)
        return false if expires_at <= now
        return false unless match_scope?(self.service, service)
        return false unless match_scope?(self.environment, environment)

        match_label?(label_pattern, label)
      end

      private

      def match_scope?(pattern, value)
        pattern == '*' || pattern == value
      end

      def match_label?(pattern, label)
        return true if pattern == '*'

        if pattern.end_with?('.*')
          prefix = pattern.delete_suffix('.*')
          return label == prefix || label.start_with?("#{prefix}.")
        end

        pattern == label
      end
    end

    Snapshot = Struct.new(
      :probes_enabled,
      :remote_probes_enabled,
      :directives,
      :poll_interval_seconds,
      :capture_policy,
      :trigger_token_key,
      keyword_init: true
    ) do
      def self.default
        new(
          probes_enabled: true,
          remote_probes_enabled: false,
          directives: [],
          poll_interval_seconds: 60,
          capture_policy: RemoteConfig.balanced_capture_policy,
          trigger_token_key: nil
        )
      end
    end

    def self.minimal_capture_policy
      CapturePolicy.new(
        preset: 'minimal',
        capture_logs: 'error',
        capture_request_events: 'failures_only',
        capture_breadcrumbs: 'local_only',
        capture_probe_events: 'buffer_only',
        immediate_client_error_statuses: []
      )
    end

    def self.balanced_capture_policy
      CapturePolicy.new(
        preset: 'balanced',
        capture_logs: 'warning',
        capture_request_events: 'failures_only',
        capture_breadcrumbs: 'exception_only',
        capture_probe_events: 'buffer_only',
        immediate_client_error_statuses: []
      )
    end

    def self.parse(payload, fallback_poll_interval_seconds)
      return nil unless payload.is_a?(Hash)

      capture_policy =
        parse_capture_policy(payload['capture_policy'] || payload[:capture_policy]) || balanced_capture_policy
      directives = Array(payload['active_probes'] || payload[:active_probes]).filter_map do |entry|
        parse_directive(entry)
      end

      poll_interval_ms = payload['poll_interval_ms'] || payload[:poll_interval_ms]
      poll_interval_seconds = if poll_interval_ms.to_i.positive?
                                [(poll_interval_ms.to_i / 1000), 1].max
                              else
                                fallback_poll_interval_seconds
                              end

      Snapshot.new(
        probes_enabled: payload['probes_enabled'] != false && payload[:probes_enabled] != false,
        remote_probes_enabled: payload['remote_probes_enabled'] == true || payload[:remote_probes_enabled] == true,
        directives: directives,
        poll_interval_seconds: poll_interval_seconds,
        capture_policy: capture_policy,
        trigger_token_key: payload['trigger_token_key'] || payload[:trigger_token_key]
      )
    end

    def self.parse_capture_policy(payload)
      return nil unless payload.is_a?(Hash)

      CapturePolicy.new(
        preset: payload['preset'] || payload[:preset] || 'balanced',
        capture_logs: payload['capture_logs'] || payload[:capture_logs] || 'warning',
        capture_request_events:
          payload['capture_request_events'] || payload[:capture_request_events] || 'failures_only',
        capture_breadcrumbs: payload['capture_breadcrumbs'] || payload[:capture_breadcrumbs] || 'exception_only',
        capture_probe_events: payload['capture_probe_events'] || payload[:capture_probe_events] || 'buffer_only',
        immediate_client_error_statuses: Array(
          payload['immediate_client_error_statuses'] || payload[:immediate_client_error_statuses]
        ).grep(Integer)
      )
    end

    def self.parse_directive(payload)
      return nil unless payload.is_a?(Hash)

      expires_at_value = payload['expires_at'] || payload[:expires_at]
      expires_at = parse_time(expires_at_value)
      return nil unless expires_at

      Directive.new(
        id: payload['id'] || payload[:id],
        label_pattern: payload['label_pattern'] || payload[:label_pattern],
        service: payload['service'] || payload[:service] || '*',
        environment: payload['environment'] || payload[:environment] || '*',
        expires_at: expires_at
      )
    end

    def self.parse_time(value)
      return nil unless value.is_a?(String) && !value.empty?

      Time.iso8601(value)
    rescue ArgumentError
      nil
    end
  end
end
