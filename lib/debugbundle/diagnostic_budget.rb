# frozen_string_literal: true

require 'json'

module DebugBundle
  # Caller holds the destination's buffer mutex. Metadata and pending serialized
  # ownership share a 64 KiB budget; ACK/retry cannot renew an expired window.
  class DiagnosticBudget
    def initialize
      @windows = {}
      @pending = {}
      @held = 0
    end

    def accounted_bytes = @held + @windows.values.sum { |window| window[:cost] }

    def key(payload)
      scope = payload.fetch('scope')
      JSON.generate([payload.fetch('failure_ref'), scope.fetch('kind'), scope['operation_id'] || scope['page_id']])
    end

    def metadata_cost(scope, window) = JSON.generate([scope, window.except(:cost)]).bytesize

    def prune(now)
      @windows.delete_if { |_key, window| window[:pending].zero? && now >= window[:starts] + 300 }
    end

    def window(now)
      { starts: now, failure_at: nil, failure_id: nil, attempts: [], observations: 0,
        resource: false, ambiguous: false, pending: 0, cost: 0 }
    end

    def register_failure(payload, event_id, now)
      return false unless now.is_a?(Numeric) && now.finite?

      prune(now)
      scope = key(payload)
      previous = @windows[scope]
      if previous && previous[:failure_id] && previous[:failure_id] != event_id
        previous[:ambiguous] = true
        previous[:cost] = metadata_cost(scope, previous)
        return false
      end
      return false if previous.nil? && @windows.length >= 50

      value = previous ? previous.dup : window(now)
      value[:failure_id] = event_id
      value[:failure_at] ||= now
      store(scope, previous, value)
    end

    def store(scope, previous, value, extra = 0)
      value[:cost] = metadata_cost(scope, value)
      return false if accounted_bytes - (previous ? previous[:cost] : 0) + value[:cost] + extra > 65_536

      @windows[scope] = value
      !value[:ambiguous]
    end

    def reserve(event_id, payload, bytes, now)
      return false unless valid_size?(bytes) && now.is_a?(Numeric) && now.finite? && !@pending.key?(event_id)

      prune(now)
      scope = key(payload)
      previous = @windows[scope]
      return false if (previous.nil? && @windows.length >= 50) || (previous && previous[:ambiguous])

      value = previous ? previous.merge(attempts: previous[:attempts].dup) : window(now)
      return false if now < value[:starts] || now > (value[:failure_at] || value[:starts]) + 300
      return false if value[:observations] >= 20 || !admit_kind?(value, payload, now)

      value[:pending] += 1
      value[:observations] += 1
      cost = bytes + event_id.bytesize + scope.bytesize + 64
      return false unless store(scope, previous, value, cost)

      @pending[event_id] =
        { scope: scope, kind: payload['kind'], attempt: payload['attempt_id'], size: bytes, cost: cost }
      @held += cost
      true
    end

    def admit_kind?(value, payload, now)
      if payload['kind'] == 'recovery'
        attempt = payload['attempt_id']
        return false if !value[:attempts].include?(attempt) && value[:attempts].length >= 5

        value[:attempts] |= [attempt]
      else
        return false if value[:resource] || value[:failure_id] != payload['source_event_id']
        return false unless value[:failure_at] && now <= value[:failure_at] + 30

        value[:resource] = true
      end
      true
    end

    def replace(original_id, event_id, payload, bytes, now)
      entry = @pending[original_id]
      same_scope = entry && entry[:scope] == key(payload)
      unless same_scope && entry[:kind] == payload['kind'] && entry[:attempt] == payload['attempt_id']
        release([original_id])
        return reserve(event_id, payload, bytes, now)
      end
      if event_id != original_id
        if @pending.key?(event_id)
          release([original_id])
          return false
        end
        @pending[event_id] = @pending.delete(original_id)
        delta = event_id.bytesize - original_id.bytesize
        entry[:cost] += delta
        @held += delta
      end
      if !adjust(event_id, bytes) || !eligible(event_id, payload)
        release([event_id])
        return false
      end
      true
    end

    def adjust(event_id, bytes)
      entry = @pending[event_id]
      return false unless entry && valid_size?(bytes) && accounted_bytes + bytes - entry[:size] <= 65_536

      @held += bytes - entry[:size]
      entry[:cost] += bytes - entry[:size]
      entry[:size] = bytes
      true
    end

    def eligible(event_id, payload)
      entry = @pending[event_id]
      value = @windows[key(payload)]
      entry && entry[:scope] == key(payload) && value && !value[:ambiguous] &&
        (payload['kind'] == 'recovery' || value[:failure_id] == payload['source_event_id'])
    end

    def release(event_ids)
      event_ids.compact.uniq.each do |id|
        entry = @pending.delete(id)
        next unless entry

        @held -= entry[:cost]
        value = @windows[entry[:scope]]
        next unless value

        value[:pending] = [value[:pending] - 1, 0].max
        value[:cost] = metadata_cost(entry[:scope], value)
      end
    end

    def valid_size?(size) = size.is_a?(Integer) && size.between?(0, 65_536)
  end
end
