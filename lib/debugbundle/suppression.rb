# frozen_string_literal: true

require 'digest'
require 'time'

module DebugBundle
  module Suppression
    DUPLICATE_WINDOW_SECONDS = 30.0
    LOOP_WINDOW_SECONDS = 2.0
    LOOP_THRESHOLD = 10
    LOOP_RESET_AFTER_SECONDS = 60.0
    LOOP_CHECKPOINT_SECONDS = 30.0
    MAX_NORMAL_EVENTS_PER_WINDOW = 3

    State = Struct.new(
      :window_started_at,
      :emitted_count,
      :pending_suppressed_count,
      :pending_first_seen_at,
      :pending_last_seen_at,
      :last_aggregate_emitted_at,
      :loop_window_started_at,
      :loop_hit_count,
      :suppression_mode,
      :last_seen_at,
      keyword_init: true
    )

    class Tracker
      def initialize
        @states = {}
      end

      def should_capture(key, now:)
        state = (@states[key] ||= new_state(now))

        if state.suppression_mode && (now - state.last_seen_at) >= LOOP_RESET_AFTER_SECONDS
          @states[key] = new_state(now)
          state = @states[key]
        end

        if (now - state.window_started_at) >= DUPLICATE_WINDOW_SECONDS
          state.window_started_at = now
          state.emitted_count = 0
        end

        if (now - state.loop_window_started_at) >= LOOP_WINDOW_SECONDS
          state.loop_window_started_at = now
          state.loop_hit_count = 0
        end

        state.loop_hit_count += 1
        state.last_seen_at = now
        state.suppression_mode = true if state.loop_hit_count > LOOP_THRESHOLD

        if state.suppression_mode
          mark_suppressed(state, now)
          return false
        end

        if state.emitted_count < MAX_NORMAL_EVENTS_PER_WINDOW
          state.emitted_count += 1
          return true
        end

        mark_suppressed(state, now)
        false
      end

      def drain_aggregates(now:)
        @states.each_with_object([]) do |(key, state), aggregates|
          next if state.pending_suppressed_count.zero?
          next if state.pending_first_seen_at.nil? || state.pending_last_seen_at.nil?
          next if checkpoint_not_due?(state, now)

          aggregates << {
            'fingerprint' => Digest::SHA256.hexdigest(key),
            'suppressed_count' => state.pending_suppressed_count,
            'first_seen' => Time.at(state.pending_first_seen_at).utc.iso8601,
            'last_seen' => Time.at(state.pending_last_seen_at).utc.iso8601,
            'window_seconds' => DUPLICATE_WINDOW_SECONDS.to_i
          }

          state.pending_suppressed_count = 0
          state.pending_first_seen_at = nil
          state.pending_last_seen_at = nil
          state.last_aggregate_emitted_at = now
        end
      end

      private

      def new_state(now)
        State.new(
          window_started_at: now,
          emitted_count: 0,
          pending_suppressed_count: 0,
          pending_first_seen_at: nil,
          pending_last_seen_at: nil,
          last_aggregate_emitted_at: nil,
          loop_window_started_at: now,
          loop_hit_count: 0,
          suppression_mode: false,
          last_seen_at: now
        )
      end

      def mark_suppressed(state, now)
        state.pending_first_seen_at ||= state.window_started_at
        state.pending_suppressed_count += 1
        state.pending_last_seen_at = now
      end

      def checkpoint_not_due?(state, now)
        state.suppression_mode &&
          state.last_aggregate_emitted_at &&
          (now - state.last_aggregate_emitted_at) < LOOP_CHECKPOINT_SECONDS
      end
    end
  end
end
