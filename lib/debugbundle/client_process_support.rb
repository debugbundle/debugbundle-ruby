# frozen_string_literal: true

module DebugBundle
  class Client
    module ProcessSupport
      private

      def ensure_current_process!
        current_pid = Process.pid
        return if @owner_pid == current_pid

        inherited_policy = @capture_policy
        inherited_probes_enabled = @remote_config.probes_enabled
        # A fork inherits buffers, locks, and an unusable sender thread. Reset them
        # before touching any inherited synchronization object or captured event.
        @buffer = []
        @buffer_bytes = 0
        @buffer_priority_counts = [0, 0, 0, 0]
        @inflight_event_ids = Set.new
        @inflight_priority_counts = [0, 0, 0, 0]
        @event_sizes = {}
        @pressure_drops = {}
        @hook_bypass = Set.new
        @finalized_events = {}
        @buffer_mutex = Mutex.new
        @flush_mutex = Mutex.new
        @probe_buffers = {}
        @context = {}
        @suppression = Suppression::Tracker.new
        @last_event_at = nil
        @retry_at = nil
        @consecutive_failures = 0
        @acknowledgement_state = nil
        @next_remote_config_poll_at = nil
        @remote_config_etag = nil
        @remote_config = RemoteConfig::Snapshot.default
        @remote_config.probes_enabled = inherited_probes_enabled
        @capture_policy = @config_fetcher ? inherited_policy : @remote_config.capture_policy
        @remote_config.capture_policy = @capture_policy
        @initial_remote_config_pending = !@config_fetcher.nil?
        @delivery_worker = nil
        @config_worker = nil
        @owner_pid = current_pid
        return unless config.enabled? && config.configured?

        @delivery_worker = DeliveryWorker.new(
          interval: config.flush_interval,
          before_work: -> {},
          &method(:flush_now)
        )
        if @config_fetcher
          @config_worker = ConfigWorker.new(
            next_wait_seconds: method(:next_remote_config_wait_seconds),
            &method(:refresh_remote_config_on_worker)
          )
        end
      rescue StandardError
        # Capture must remain best-effort if a child cannot start a sender.
        @delivery_worker = nil
        @config_worker = nil
      end
    end
  end
end
