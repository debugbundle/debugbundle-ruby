# frozen_string_literal: true

require 'json'
require 'debugbundle/evidence_wire'

module DebugBundle
  # A small closed interpreter for the vendored accepting Draft 7 contract.
  # No remote refs, application serializers or runtime dependency are needed.
  # Unknown schema keywords fail closed when a future contract is generated.
  class CanonicalEventSchema
    KEYWORDS = %w[$schema $id $comment $ref type anyOf const enum properties required additionalProperties
                  items minimum maximum exclusiveMinimum minLength maxLength minItems maxItems format pattern].freeze
    TYPES = %w[null boolean number integer string array object].freeze
    LOAD_MUTEX = Mutex.new

    def self.valid?(value)
      unless defined?(@engine)
        LOAD_MUTEX.synchronize do
          unless defined?(@engine)
            begin
              @engine = new(JSON.parse(File.read(File.join(__dir__, 'event-envelope.schema.json'))))
            rescue StandardError
              @engine = nil
            end
          end
        end
      end
      !!(@engine && @engine.accepts?(value))
    rescue StandardError
      false
    end

    def initialize(schema)
      @root = schema
      @references = {}
      @patterns = {}
      compile(schema)
    end

    def compile(node)
      return if [true, false].include?(node)

      raise ArgumentError, 'unsupported schema keyword' unless (node.keys - KEYWORDS).empty?
      raise ArgumentError, 'unsupported schema type' unless (Array(node['type']) - TYPES).empty?
      raise ArgumentError, 'unsupported schema format' unless [nil, 'uuid', 'date-time'].include?(node['format'])

      @patterns[node['pattern']] ||= Regexp.new(node['pattern']) if node.key?('pattern')
      resolve(node['$ref']) if node.key?('$ref')
      node.fetch('properties', {}).each_value { |child| compile(child) }
      node.fetch('anyOf', []).each { |child| compile(child) }
      %w[items additionalProperties].each { |key| compile(node[key]) if node.key?(key) }
    end

    def resolve(reference)
      raise ArgumentError, 'external schema ref' unless reference.start_with?('#/')

      @references[reference] ||= reference.delete_prefix('#/').split('/').reduce(@root) do |node, part|
        node.fetch(node.is_a?(Array) ? Integer(part) : part.gsub('~1', '/').gsub('~0', '~'))
      end
    end

    def accepts?(value)
      check(@root, value, { steps: 100_000 }, 0)
    rescue StandardError
      false
    end

    def check(node, value, budget, depth)
      budget[:steps] -= 1
      return false if depth > 64 || budget[:steps].negative?
      return node if [true, false].include?(node)
      return check(resolve(node['$ref']), value, budget, depth + 1) if node.key?('$ref')

      return false if node.key?('anyOf') && node['anyOf'].none? { |child| check(child, value, budget, depth + 1) }
      return false if node.key?('type') && Array(node['type']).none? { |type| matches_type?(value, type) }
      return false if node.key?('const') && value != node['const']
      return false if node.key?('enum') && !node['enum'].include?(value)

      case value
      when Hash then object?(node, value, budget, depth)
      when Array then array?(node, value, budget, depth)
      when String then string?(node, value)
      when Integer, Float then number?(node, value)
      else true
      end
    end

    def matches_type?(value, type)
      case type
      when 'null' then value.nil?
      when 'boolean' then [true, false].include?(value)
      when 'string' then value.is_a?(String)
      when 'object' then value.is_a?(Hash)
      when 'array' then value.is_a?(Array)
      when 'number' then (value.is_a?(Integer) || value.is_a?(Float)) && value.to_f.finite?
      when 'integer' then matches_type?(value, 'number') && value == value.floor
      else false
      end
    end

    def object?(node, value, budget, depth)
      return false unless node.fetch('required', []).all? { |key| value.key?(key) }

      properties = node.fetch('properties', {})
      value.all? do |key, child|
        if properties.key?(key)
          check(properties[key], child, budget, depth + 1)
        else
          check(node.fetch('additionalProperties', true), child, budget, depth + 1)
        end
      end
    end

    def array?(node, value, budget, depth)
      return false if node.key?('minItems') && value.length < node['minItems']
      return false if node.key?('maxItems') && value.length > node['maxItems']

      !node.key?('items') || value.all? { |child| check(node['items'], child, budget, depth + 1) }
    end

    def string?(node, value)
      return false if node.key?('minLength') && value.length < node['minLength']
      return false if node.key?('maxLength') && value.length > node['maxLength']
      return false if node.key?('pattern') && !@patterns.fetch(node['pattern']).match?(value)
      return EvidenceWire.uuid(value) if node['format'] == 'uuid'
      return EvidenceWire.timestamp(value) if node['format'] == 'date-time'

      true
    end

    def number?(node, value)
      (!node.key?('minimum') || value >= node['minimum']) &&
        (!node.key?('maximum') || value <= node['maximum']) &&
        (!node.key?('exclusiveMinimum') || value > node['exclusiveMinimum'])
    end
  end
end
