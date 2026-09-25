# frozen_string_literal: true

module DebugBundle
  class Client
    module QueueSupport
      private

      def preflight_capacity?(priority, kind)
        @buffer_mutex.synchronize do
          full = @buffer.length >= MAX_BUFFER_SIZE || @buffer_bytes >= MAX_BUFFER_BYTES
          evictable = @buffer_priority_counts.take(priority).sum - @inflight_priority_counts.take(priority).sum
          return true unless full && evictable.zero?

          record_pressure_kind_locked(kind, Time.now.utc.iso8601)
          false
        end
      end

      def enqueue_event(event, skip_before_send: false, record_pressure: true)
        event = protect_event(event)
        return unless event
        return unless sampled_in?

        event_size = JSON.generate(event).bytesize
        admitted, buffered = @buffer_mutex.synchronize do
          unless admit_event_locked?(event, event_size)
            record_pressure_drop_locked(event) if record_pressure
            next [false, @buffer.length]
          end

          @buffer << event
          @buffer_bytes += event_size
          @buffer_priority_counts[event_priority(event)] += 1
          @event_sizes[event['event_id']] = event_size
          @hook_bypass.add(event['event_id']) if skip_before_send
          [true, @buffer.length]
        end
        @delivery_worker&.wake if admitted && buffered >= config.batch_size
        admitted
      rescue JSON::GeneratorError, Encoding::InvalidByteSequenceError
        nil
      end

      def admit_event_locked?(event, event_size)
        return false if event_size > MAX_BUFFER_BYTES

        while @buffer.length >= MAX_BUFFER_SIZE || @buffer_bytes + event_size > MAX_BUFFER_BYTES
          index = evictable_event_index(event_priority(event))
          return false unless index

          removed = @buffer.delete_at(index)
          remove_event_ownership_locked(removed)
          record_pressure_drop_locked(removed)
        end
        true
      end

      def event_priority(event)
        return 3 if event['event_type'] == 'backend_exception'
        return 2 if event['event_type'] == 'error_suppressed'

        if event['event_type'] == 'request_event'
          status = event.dig('payload', 'response_status')
          return status.is_a?(Integer) && status >= 400 ? 2 : 1
        end
        return 1 unless event['event_type'] == 'log_event'

        level = normalize_level(event.dig('payload', 'level'))
        LOG_LEVEL_RANKS.fetch(level) >= LOG_LEVEL_RANKS.fetch(:error) ? 2 : 0
      end

      def pressure_class(event)
        return 'exception' if event['event_type'] == 'backend_exception'
        return 'request' if event['event_type'] == 'request_event'
        return 'other' unless event['event_type'] == 'log_event'

        normalize_level(event.dig('payload', 'level')).to_s
      end

      def record_pressure_drop_locked(event)
        record_pressure_kind_locked(pressure_class(event), event['occurred_at'])
      end

      def record_pressure_kind_locked(kind, occurred_at)
        state = (@pressure_drops[kind] ||= { count: 0, first_seen: occurred_at, last_seen: nil })
        state[:count] += 1
        state[:last_seen] = occurred_at
      end

      def append_pressure_aggregates
        pending = @buffer_mutex.synchronize { @pressure_drops.transform_values(&:dup) }
        pending.each do |kind, state|
          next unless state[:count].positive?
          next if @buffer_mutex.synchronize { @buffer.length >= MAX_BUFFER_SIZE }

          payload = {
            'fingerprint' => Digest::SHA256.hexdigest("ruby-queue-pressure:#{kind}"),
            'suppressed_count' => state[:count],
            'window_seconds' => 60,
            'first_seen' => state[:first_seen],
            'last_seen' => state[:last_seen],
            'reason' => 'queue_pressure',
            'level' => kind
          }
          next unless enqueue_event(base_event('error_suppressed', payload, {}), record_pressure: false)

          @buffer_mutex.synchronize do
            current = @pressure_drops[kind]
            current[:count] -= state[:count]
            current[:first_seen] = current[:last_seen] if current[:count].positive?
          end
        end
      end

      def remove_event_ownership_locked(event)
        event_id = event['event_id']
        @buffer_bytes -= @event_sizes.delete(event_id).to_i
        @buffer_priority_counts[event_priority(event)] -= 1
        @inflight_priority_counts[event_priority(event)] -= 1 if @inflight_event_ids.delete?(event_id)
        @hook_bypass.delete(event_id)
        @finalized_events.delete(event_id)
      end

      def evictable_event_index(priority)
        @buffer.index do |queued|
          !@inflight_event_ids.include?(queued['event_id']) && event_priority(queued) < priority
        end
      end

      def cache_finalized_event(event, finalized)
        # The original stays available for acknowledgement identity and retries, so
        # a distinct hook replacement owns additional bytes until removal.
        extra_bytes = finalized.equal?(event) ? 0 : JSON.generate(finalized).bytesize
        @buffer_mutex.synchronize do
          while @buffer_bytes + extra_bytes > MAX_BUFFER_BYTES
            index = evictable_event_index(event_priority(event))
            unless index
              record_pressure_drop_locked(event)
              return nil
            end
            removed = @buffer.delete_at(index)
            remove_event_ownership_locked(removed)
            record_pressure_drop_locked(removed)
          end
          @buffer_bytes += extra_bytes
          @event_sizes[event['event_id']] += extra_bytes
          @finalized_events[event['event_id']] = finalized
        end
      end

      def reserve_buffered_batch
        @buffer_mutex.synchronize do
          @inflight_event_ids = @buffer.to_set { |event| event['event_id'] }
          @inflight_priority_counts = @buffer_priority_counts.dup
          @buffer.dup
        end
      end

      def release_buffered_batch
        @buffer_mutex.synchronize do
          @inflight_event_ids.clear
          @inflight_priority_counts = [0, 0, 0, 0]
        end
      end

      def buffered_batch
        @buffer_mutex.synchronize { @buffer.dup }
      end

      def remove_buffered_events(events)
        event_ids = events.to_set { |event| event['event_id'] }
        @buffer_mutex.synchronize do
          @buffer.reject! do |event|
            next false unless event_ids.include?(event['event_id'])

            remove_event_ownership_locked(event)
            true
          end
        end
      end
    end
  end
end
