# frozen_string_literal: true

require 'debugbundle/diagnostic_budget'
require 'debugbundle/evidence_delivery'
require 'debugbundle/exception_evidence'
require 'debugbundle/operation_context'
require 'debugbundle/event_batch'

module DebugBundle
  class Client
    module EvidenceSupport
      def with_operation_context(kind:, name: nil, limit_ms: nil, correlation: nil)
        ensure_current_process!
        unless @closed
          lease = @operations.begin_scope(kind: kind, name: name, limit_ms: limit_ms, correlation: correlation)
        end
        yield
      ensure
        @operations.end_scope(lease)
      end

      def capture_recovery(observation = nil, context: nil, **options)
        return unless capture_enabled? && recovery_allowed?

        return if observation && !options.empty?

        input = EvidenceValue.options(observation || options)
        payload = EvidenceWire.recovery(input, @operations.scope)
        return unless payload

        event = base_event('diagnostic_context', payload, merge_context(context))
        return unless EvidenceWire.valid_optional?(event)

        enqueue_event(event)
      rescue StandardError
        nil
      end

      private

      def apply_before_send(event)
        protected = protect_event(event)
        return nil unless protected

        prepared = BeforeSend.apply(protected, config.before_send)
        return nil unless prepared

        result = protect_event(prepared)
        return result if prepared.equal?(protected)

        result if result && BeforeSend.valid?(result)
      end

      def protect_event(event)
        protected = protect_event_fields(event)
        return fit_protected_event(protected) if protected && EvidenceWire.valid_optional?(protected)

        legacy = EvidenceWire.without_optional(event)
        fit_protected_event(legacy && protect_event_fields(legacy))
      rescue StandardError
        legacy = EvidenceWire.without_optional(event)
        fit_protected_event(legacy && protect_event_fields(legacy))
      end

      def fit_protected_event(event)
        return event if @transport.is_a?(Transport::FileTransport)

        EventBatch.fit(event)
      end

      def initialize_evidence
        @evidence = EvidenceDelivery.new(config.evidence_capabilities)
        @operations = OperationContext.new
        @diagnostics = DiagnosticBudget.new
      end

      def recovery_allowed?
        config.capture_recovery_observations && @evidence.supports?('recovery_v1') &&
          @capture_policy.preset != 'minimal' && @capture_policy.capture_diagnostic_context != false
      end

      def evidence_context(context)
        return context unless @evidence.supports?('recovery_v1') || @evidence.supports?('resource_observations_v1')

        reference = EvidenceWire.capture_reference(context, @operations.scope)
        reference ? context.except('failure_ref', 'evidence_scope').merge('evidence_reference' => reference) : context
      end

      def enrich_exception(event, retained, causes, fatal:)
        return event unless config.capture_exception_evidence && @evidence.supports?('exception_evidence_v1')

        metadata = {}
        execution = @operations.snapshot
        metadata['execution'] = execution if execution
        reference = EvidenceWire.reference(event.dig('context', 'evidence_reference'))
        metadata['evidence_reference'] = reference if reference
        maximum = (fatal ? 4096 : 32_768) - EvidenceJson.bytes(metadata) - 32
        graph = ExceptionEvidence.from_retained(root: retained, causes: causes, fatal: fatal, budget_bytes: maximum)
        event['payload']['exception_evidence'] = graph if graph
        event['payload']['execution'] = execution if execution
        event
      rescue StandardError
        event
      end

      def filter_evidence(event)
        features = @evidence.features
        features -= ['exception_evidence_v1'] unless config.capture_exception_evidence
        EvidenceWire.supported(event, features)
      end

      def reserve_diagnostic_locked(event, bytes)
        event['event_type'] != 'diagnostic_context' ||
          (recovery_allowed? && event.dig('payload', 'kind') == 'recovery' &&
            @diagnostics.reserve(event['event_id'], event['payload'], bytes, now.to_f))
      end

      def reconcile_diagnostic(original, replacement)
        @buffer_mutex.synchronize do
          original_id = original['event_type'] == 'diagnostic_context' ? original['event_id'] : nil
          if replacement['event_type'] == 'diagnostic_context'
            return false unless recovery_allowed? && replacement.dig('payload', 'kind') == 'recovery'

            payload = replacement['payload']
            size = JSON.generate(replacement).bytesize
            return original_id ? @diagnostics.replace(original_id, replacement['event_id'], payload, size,
                                                      now.to_f) : @diagnostics.reserve(replacement['event_id'],
                                                                                       payload, size, now.to_f)
          end
          @diagnostics.release([original_id]) if original_id
          if %w[backend_exception frontend_exception].include?(replacement['event_type'])
            reference = EvidenceWire.reference(replacement.dig('context', 'evidence_reference'))
            if reference
              @diagnostics.register_failure(reference, replacement['event_id'],
                                            Time.iso8601(replacement['occurred_at']).to_f)
            end
          end
          true
        end
      end

      def release_diagnostics_locked(event, finalized = nil)
        ids = []
        ids << event['event_id'] if event['event_type'] == 'diagnostic_context'
        ids << finalized['event_id'] if finalized && finalized['event_type'] == 'diagnostic_context'
        @diagnostics.release(ids)
      end

      def downgrade_evidence_errors(batch, decision, lost)
        return [] unless lost

        decision.fetch(:terminal_errors).filter_map do |index, reason|
          next unless reason == 'invalid_event'

          original = batch.fetch(index)
          finalized = @buffer_mutex.synchronize { @finalized_events[original['event_id']] || original }
          next unless %w[backend_exception frontend_exception].include?(finalized['event_type'])

          reduced = filter_evidence(finalized)
          next if reduced == finalized

          original if cache_finalized_event(original, reduced)
        end
      end
    end

    include EvidenceSupport
  end
end
