# frozen_string_literal: true

require 'debugbundle/framework_operation'

module DebugBundle
  module Sidekiq
    class ServerMiddleware
      def initialize(options = nil, client: nil)
        resolved_options = options.is_a?(Hash) ? options : {}
        @client = client || resolved_options[:client] || resolved_options['client'] || DebugBundle.client
      end

      def call(_worker, job, queue)
        FrameworkOperation.run(@client, kind: 'job', correlation: { trace_id: job['trace_id'] }) do
          yield
        rescue StandardError => e
          @client.capture_exception(
            e,
            context: {
              queue: queue,
              job: {
                class: job['class'],
                queue: job['queue'] || queue,
                jid: job['jid'],
                retry_count: job['retry_count'] || job['retry'],
                args_summary: Array(job['args']).first(5).map { |value| value.class.name }
              },
              job_id: job['jid'],
              trace_id: job['trace_id']
            },
            handled: false
          )
          raise
        end
      end
    end
  end
end
