# frozen_string_literal: true

require 'json'
require 'debugbundle/evidence_wire'

module DebugBundle
  module EventBatch
    MAX_BODY_BYTES = 256 * 1024
    WRAPPER_BYTES = 13 # {"events":[]} plus a conservative comma allowance
    MAX_EVENT_BYTES = MAX_BODY_BYTES - WRAPPER_BYTES

    module_function

    def bytes(event) = JSON.generate(event).bytesize
    def fits?(event) = bytes(event) <= MAX_EVENT_BYTES

    # Added metadata must not strand a primary that fits on the legacy wire.
    # A historically open same-named custom context value remains untouched.
    def fit(event)
      return nil unless event
      return event if fits?(event)

      reduced = EvidenceWire.without_optional(event) || event
      if EvidenceWire.reference(reduced.dig('context', 'evidence_reference'))
        reduced = reduced.merge('context' => reduced['context'].except('evidence_reference'))
      end
      reduced if reduced != event && fits?(reduced)
    end

    def chunks(events)
      result = [[]]
      size = WRAPPER_BYTES
      events.each do |event|
        cost = bytes(event) + (result.last.empty? ? 0 : 1)
        raise ArgumentError, 'event exceeds the ingestion request limit' unless fits?(event)

        if size + cost > MAX_BODY_BYTES
          result << []
          size = WRAPPER_BYTES
          cost -= 1
        end
        result.last << event
        size += cost
      end
      result
    end
  end
end
