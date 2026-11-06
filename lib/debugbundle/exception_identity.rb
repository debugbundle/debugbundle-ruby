# frozen_string_literal: true

require 'weakref'

module DebugBundle
  class ExceptionIdentity
    NATIVE_EQUAL = BasicObject.instance_method(:equal?)

    def initialize
      @entries = []
      @lock = Mutex.new
    end

    def admit?(error, scope, automatic, accepted: false)
      return true if scope.nil?
      return true unless @lock.try_lock

      begin
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @entries.reject! { |entry| !entry[0].weakref_alive? || now - entry[3] >= 30 }
        @entries.each do |entry|
          next unless NATIVE_EQUAL.bind_call(entry[0].__getobj__, error) && entry[1] == scope

          if !accepted && automatic != entry[2]
            @entries.delete(entry)
            return false
          end
          @entries.delete(entry) if accepted
        end
        if accepted
          @entries.shift if @entries.length >= 128
          @entries << [WeakRef.new(error), scope, automatic, now]
        end
        true
      rescue WeakRef::RefError
        true
      ensure
        @lock.unlock
      end
    end
  end
end
