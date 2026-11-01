# frozen_string_literal: true

module DebugBundle
  module FrameworkOperation
    def self.run(client, ...)
      # Custom clients implementing the older injection surface keep their
      # established application behavior without claiming scoped evidence.
      return yield unless client.respond_to?(:with_operation_context)

      client.with_operation_context(...)
    end
  end
end
