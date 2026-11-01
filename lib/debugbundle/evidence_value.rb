# frozen_string_literal: true

module DebugBundle
  # Copy only bounded native JSON values. No custom iterators, serializers,
  # default procs or coercions may run at the optional evidence boundary.
  module EvidenceValue
    INVALID = Object.new.freeze
    EXHAUSTED = Object.new.freeze
    NATIVE_CLASS = Object.instance_method(:class)
    NATIVE_EQUAL = Object.instance_method(:equal?)

    module_function

    def type?(value, type) = NATIVE_EQUAL.bind_call(NATIVE_CLASS.bind_call(value), type)

    def copy(value, symbol_keys: false)
      result = copy_with_budget(value, symbol_keys: symbol_keys)
      result.equal?(EXHAUSTED) ? INVALID : result
    end

    # Hooks must distinguish an invalid value from validation that stopped at
    # its resource limit; the latter must not restore pre-hook content.
    def copy_with_budget(value, symbol_keys: false, max_bytes: 262_144, max_string_bytes: 32_768)
      budget = { nodes: 4096, bytes: max_bytes, string_bytes: max_string_bytes, symbol_keys: symbol_keys }
      result = visit(value, 0, budget)
      budget[:exhausted] ? EXHAUSTED : result
    rescue StandardError
      INVALID
    end

    def options(value)
      visit(value, 0, { nodes: 4096, bytes: 262_144, symbols: true })
    rescue StandardError
      INVALID
    end

    def visit(value, depth, budget)
      budget[:nodes] -= 1
      return exhausted(budget) if depth > 16 || budget[:nodes].negative? || budget[:bytes].negative?
      return value if type?(value, NilClass) || type?(value, TrueClass) || type?(value, FalseClass)
      return copy_string(value, budget) if type?(value, String)

      if budget[:symbols] && type?(value, Symbol)
        return exhausted(budget) if Symbol.instance_method(:length).bind_call(value) > 32_768

        return copy_string(Symbol.instance_method(:to_s).bind_call(value), budget)
      end
      return value if type?(value, Integer) && value.bit_length <= 1024
      return value if type?(value, Float) && value.finite?
      return copy_array(value, depth, budget) if type?(value, Array)
      return copy_hash(value, depth, budget) if type?(value, Hash)

      INVALID
    end

    def exhausted(budget)
      budget[:exhausted] = true
      INVALID
    end

    def copy_string(value, budget)
      maximum = budget.fetch(:string_bytes, 32_768)
      return exhausted(budget) if String.instance_method(:bytesize).bind_call(value) > [maximum, budget[:bytes]].min

      text = String.new(value).encode(Encoding::UTF_8)
      budget[:bytes] -= text.bytesize
      return exhausted(budget) if text.bytesize > maximum || budget[:bytes].negative?

      text.valid_encoding? ? text : INVALID
    end

    def copy_array(value, depth, budget)
      return exhausted(budget) if Array.instance_method(:length).bind_call(value) > 256

      result = []
      Array.instance_method(:each).bind_call(value) do |item|
        child = visit(item, depth + 1, budget)
        return INVALID if child.equal?(INVALID)

        result << child
      end
      result
    end

    def copy_hash(value, depth, budget)
      return exhausted(budget) if Hash.instance_method(:size).bind_call(value) > 256

      result = {}
      Hash.instance_method(:each_pair).bind_call(value) do |key, item|
        if (budget[:symbols] || budget[:symbol_keys]) && type?(key, Symbol)
          return exhausted(budget) if Symbol.instance_method(:length).bind_call(key) > 32_768

          key = Symbol.instance_method(:to_s).bind_call(key)
        end
        return INVALID unless type?(key, String)

        name = copy_string(key, budget)
        child = visit(item, depth + 1, budget)
        return INVALID if name.equal?(INVALID) || child.equal?(INVALID)
        return INVALID if result.key?(name)

        result[name] = child
      end
      result
    end
  end
end
