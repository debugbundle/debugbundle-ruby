# frozen_string_literal: true

require 'debugbundle/evidence_delivery'
require 'debugbundle/event_batch'

module DebugBundle
  module Relay
    class Forwarder
      def initialize(transport, token, evidence)
        @transport = transport
        @token = token
        @evidence = evidence
      end

      # The second result permits marking a spool delivered only after complete
      # canonical acceptance. Legacy custom-transport acceptance stays compatible.
      def send(events, discover:)
        return [false, false] unless @token.is_a?(String) && !@token.empty?

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        complete = true
        features = EvidenceWire::FEATURES.dup
        owned = events.map { |event| event.merge('project_token' => @token) }
        EventBatch.chunks(owned).each do |chunk|
          chunk = chunk.map { |event| EvidenceWire.supported(event, @evidence.features) }
          return [false, false] if chunk.any?(&:nil?)

          return [false, false] if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          success, canonical = send_chunk(chunk, discover: discover, deadline: deadline)
          features &= @evidence.features
          @evidence.restrict(features)
          return [false, false] unless success && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

          complete &&= canonical
        end
        [true, complete]
      rescue StandardError
        [false, false]
      end

      def send_chunk(events, discover:, deadline:)
        required = discover || @transport.is_a?(Transport::HttpTransport)
        response, ack, lost = forward(events, required, deadline)
        return [false, false] unless response && ack
        return [true, false] if ack[:kind] == :legacy
        return [false, false] unless ack[:kind] == :acknowledged
        return [true, true] if ack[:accepted] == events.length
        return [false, false] unless lost

        retry_events = ack.fetch(:terminal_errors).filter_map do |index, reason|
          original = events.fetch(index)
          next unless reason == 'invalid_event' && original['event_type'] == 'frontend_exception'

          reduced = EvidenceWire.supported(original, @evidence.features)
          reduced if reduced != original
        end
        return [false, false] if retry_events.empty?

        _reply, retry_ack, = forward(retry_events, true, deadline)
        complete = retry_ack && retry_ack[:kind] == :acknowledged &&
                   ack[:accepted] + retry_ack[:accepted] == events.length
        [!!complete, !!complete]
      rescue StandardError
        [false, false]
      end

      def forward(events, required, deadline)
        return [nil, nil, false] if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        owned = events.map { |event| event.merge('project_token' => @token) }
        request = { project_token: @token, events: owned }
        request[:deadline] = deadline if @transport.is_a?(Transport::HttpTransport)
        response = Transport.coerce_result(@transport.call(request))
        return [nil, nil, false] unless response.status_code.between?(200, 299)

        ack = Acknowledgement.decide(response.body, events.length, required: required)
        lost = @evidence.observe(response.body, required: required, valid: ack[:kind] == :acknowledged)
        [response, ack, lost]
      end
    end
  end
end
