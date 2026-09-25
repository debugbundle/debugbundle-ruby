# frozen_string_literal: true

module DebugBundle
  # One owned sender and one coalesced wakeup, including interval delivery.
  class DeliveryWorker
    MAX_WAITERS = 64
    EXPLICIT_WAIT_SECONDS = 5

    def initialize(interval:, before_work:, &deliver)
      @interval = interval
      @before_work = before_work
      @deliver = deliver
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @waiters = []
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

    def flush
      ticket = { done: false, result: false }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + EXPLICIT_WAIT_SECONDS
      @mutex.synchronize do
        return false if @closed || @waiters.length >= MAX_WAITERS

        @waiters << ticket
        @requested = true
        @condition.signal
        until ticket[:done]
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if remaining <= 0

          @condition.wait(@mutex, remaining)
        end
        ticket[:result]
      end
    end

    def close
      @mutex.synchronize do
        @closed = true
        @waiters.each { |ticket| ticket[:done] = true }
        @waiters.clear
        @condition.broadcast
      end
    end

    private

    def run
      @before_work.call
    rescue StandardError
      # A failed config fetch must not terminate the sender.
    ensure
      loop do
        tickets = wait_for_work
        break if tickets.nil?

        result = perform_work
        finish_waiters(tickets, result)
      end
    end

    def wait_for_work
      @mutex.synchronize do
        @condition.wait(@mutex, @interval) unless @requested || @closed
        return nil if @closed

        @requested = false
        tickets = @waiters
        @waiters = []
        tickets
      end
    end

    def perform_work
      @before_work.call
      @deliver.call
    rescue StandardError
      false
    end

    def finish_waiters(tickets, result)
      @mutex.synchronize do
        tickets.each do |ticket|
          ticket[:done] = true
          ticket[:result] = result
        end
        @condition.broadcast
      end
    end
  end
end
