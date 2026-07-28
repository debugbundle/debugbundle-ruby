# frozen_string_literal: true

module DebugBundle
  class Config
    DEFAULT_ENDPOINT = 'https://api.debugbundle.com/v1/events'
    DEFAULT_PROJECT_MODE = :connected
    DEFAULT_BATCH_SIZE = 25
    DEFAULT_FLUSH_INTERVAL = 5
    DEFAULT_SAMPLE_RATE = 1.0
    DEFAULT_LOG_LEVEL = :warning
    DEFAULT_LOCAL_EVENTS_DIR = '.debugbundle/local/events'
    DEFAULT_SPOOL_DIR = '.debugbundle/local/browser-relay-spool'
    DEFAULT_RELAY_RATE_LIMIT_PER_MINUTE = 60
    DEFAULT_MAX_PROBE_LABELS = 50
    DEFAULT_MAX_PROBE_ENTRIES_PER_LABEL = 10
    DEFAULT_PROBE_FLUSH_ON_ERROR = true
    DEFAULT_PROBES_POLL_INTERVAL = 60
    DEFAULT_REDACT_FIELDS = [].freeze

    VALID_PROJECT_MODES = %i[connected local_only].freeze
    VALID_STATUSES = %i[healthy degraded disconnected].freeze

    attr_reader :project_token,
                :enabled,
                :environment,
                :service,
                :endpoint,
                :project_mode,
                :local_events_dir,
                :spool_dir,
                :batch_size,
                :flush_interval,
                :sample_rate,
                :log_level,
                :relay_enabled,
                :relay_rate_limit_per_minute,
                :relay_durable_write,
                :redact_fields,
                :max_probe_labels,
                :max_probe_entries_per_label,
                :probe_flush_on_error,
                :probes_poll_interval,
                :before_send

    def initialize(
      project_token: nil,
      enabled: true,
      environment: nil,
      service: nil,
      endpoint: DEFAULT_ENDPOINT,
      project_mode: DEFAULT_PROJECT_MODE,
      local_events_dir: DEFAULT_LOCAL_EVENTS_DIR,
      spool_dir: DEFAULT_SPOOL_DIR,
      batch_size: DEFAULT_BATCH_SIZE,
      flush_interval: DEFAULT_FLUSH_INTERVAL,
      sample_rate: DEFAULT_SAMPLE_RATE,
      log_level: DEFAULT_LOG_LEVEL,
      relay_enabled: true,
      relay_rate_limit_per_minute: DEFAULT_RELAY_RATE_LIMIT_PER_MINUTE,
      relay_durable_write: true,
      redact_fields: DEFAULT_REDACT_FIELDS,
      max_probe_labels: DEFAULT_MAX_PROBE_LABELS,
      max_probe_entries_per_label: DEFAULT_MAX_PROBE_ENTRIES_PER_LABEL,
      probe_flush_on_error: DEFAULT_PROBE_FLUSH_ON_ERROR,
      probes_poll_interval: DEFAULT_PROBES_POLL_INTERVAL,
      before_send: nil
    )
      @project_token = project_token
      @enabled = enabled
      @environment = environment
      @service = service
      @endpoint = endpoint
      @project_mode = normalize_project_mode(project_mode)
      @local_events_dir = local_events_dir
      @spool_dir = spool_dir
      @batch_size = normalize_positive_integer(batch_size, DEFAULT_BATCH_SIZE)
      @flush_interval = normalize_positive_number(flush_interval, DEFAULT_FLUSH_INTERVAL)
      @sample_rate = normalize_sample_rate(sample_rate)
      @log_level = log_level
      @relay_enabled = relay_enabled
      @relay_rate_limit_per_minute = normalize_positive_integer(
        relay_rate_limit_per_minute,
        DEFAULT_RELAY_RATE_LIMIT_PER_MINUTE
      )
      @relay_durable_write = relay_durable_write
      @redact_fields = normalize_redact_fields(redact_fields)
      @max_probe_labels = normalize_positive_integer(max_probe_labels, DEFAULT_MAX_PROBE_LABELS)
      @max_probe_entries_per_label = normalize_positive_integer(
        max_probe_entries_per_label,
        DEFAULT_MAX_PROBE_ENTRIES_PER_LABEL
      )
      @probe_flush_on_error = probe_flush_on_error
      @probes_poll_interval = normalize_positive_number(probes_poll_interval, DEFAULT_PROBES_POLL_INTERVAL)
      @before_send = before_send.respond_to?(:call) ? before_send : nil
      freeze
    end

    def enabled?
      enabled
    end

    def configured?
      !project_token.to_s.empty?
    end

    private

    def normalize_project_mode(value)
      normalized = value.to_s.strip.downcase.tr('-', '_').to_sym
      return normalized if VALID_PROJECT_MODES.include?(normalized)

      DEFAULT_PROJECT_MODE
    end

    def normalize_positive_integer(value, fallback)
      integer = Integer(value)
      integer.positive? ? integer : fallback
    rescue ArgumentError, TypeError
      fallback
    end

    def normalize_positive_number(value, fallback)
      number = Float(value)
      number.positive? ? number : fallback
    rescue ArgumentError, TypeError
      fallback
    end

    def normalize_sample_rate(value)
      number = Float(value)
      number.clamp(0.0, 1.0)
    rescue ArgumentError, TypeError
      DEFAULT_SAMPLE_RATE
    end

    def normalize_redact_fields(value)
      Array(value).filter_map do |entry|
        case entry
        when String, Symbol
          entry.to_s
        when Regexp
          entry.source
        end
      end.freeze
    end
  end
end
