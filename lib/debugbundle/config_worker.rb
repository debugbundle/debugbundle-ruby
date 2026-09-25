# frozen_string_literal: true

module DebugBundle
  # One owned config poller; a stalled fetch cannot hold the event sender.
  class ConfigWorker
    def initialize(next_wait_seconds:, &refresh)
      @next_wait_seconds = next_wait_seconds
      @refresh = refresh
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @requested = false
      @closed = false
      @thread = Thread.new { run }
    end

    def wake
      @mutex.synchronize do
        return if @closed

        @requested = true
        @condition.signal
      end
    end

    def close
      @mutex.synchronize do
        @closed = true
        @condition.broadcast
      end
    end

    private

    def run
      loop do
        begin
          @refresh.call
        rescue StandardError
          # A custom fetcher must not terminate the bounded poller.
        end
        break unless wait_for_next
      end
    end

    def wait_for_next
      delay = @next_wait_seconds.call
      @mutex.synchronize do
        return false if @closed

        unless @requested
          delay.nil? ? @condition.wait(@mutex) : @condition.wait(@mutex, [delay, 0].max)
        end
        @requested = false
        !@closed
      end
    rescue StandardError
      false
    end
  end
end
