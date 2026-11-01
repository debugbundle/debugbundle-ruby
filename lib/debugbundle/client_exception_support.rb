# frozen_string_literal: true

module DebugBundle
  class Client
    module ExceptionSupport
      private

      def capture_exception_internal(error, context:, handled:, run_before_send:)
        return unless capture_enabled?
        return unless preflight_capacity?(3, 'exception')

        request_remote_config_poll_if_due

        merged_context = evidence_context(merge_context(context))
        payload = {
          'name' => safe_exception_name(error),
          'message' => safe_exception_message(error),
          'stack' => safe_exception_stack(error),
          'handled' => handled,
          'request' => request_payload(merged_context['request']),
          'response' => response_payload(merged_context['response']),
          'runtime' => runtime_payload
        }

        causes = exception_causes(error)
        retained = payload.slice('name', 'message', 'stack')
        payload['message'] = payload['name'] if payload['message'].strip.empty?
        payload['stack'] = "#{payload['name']}: #{payload['message']}" if payload['stack'].empty?

        probe_data = probe_snapshot
        payload['probe_data'] = probe_data unless probe_data.empty?

        extra_context = merged_context.dup
        extra_context['causes'] = causes unless causes.empty?

        event = base_event('backend_exception', payload, extra_context)

        event_payload = event.fetch('payload')
        suppression_key = [
          event['event_type'],
          event_payload['name'],
          event_payload['message'],
          event_payload['stack']
        ].join(':')
        return unless @suppression.should_capture(suppression_key, now: monotonic_now)

        event = enrich_exception(event, retained, causes, fatal: !run_before_send)
        enqueue_event(event, skip_before_send: !run_before_send)
      end
    end

    include ExceptionSupport
  end
end
