# frozen_string_literal: true

module DebugBundle
  # Native HTTP adapters request identity encoding and stream existing replies.
  # This cap precedes JSON parsing; no extra discovery request is introduced.
  module BoundedHttpResponse
    class LimitExceeded < StandardError; end

    module_function

    def read(deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5)
      body = +''
      response = yield lambda { |chunk|
        raise LimitExceeded if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise LimitExceeded if body.bytesize + chunk.bytesize > 262_144

        body << chunk
      }
      raise LimitExceeded if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      [response, body]
    end
  end
end
