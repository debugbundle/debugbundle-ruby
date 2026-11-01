# frozen_string_literal: true

require 'json'
require 'uri'
require 'debugbundle/telemetry_privacy'
require 'debugbundle/evidence_value'

module DebugBundle
  # Consume the existing protected native snapshots, never an Exception or its
  # formatter. Even MRI's bound Exception#to_s converts a non-string message;
  # new inspection must not introduce another such application callback.
  module ExceptionEvidence
    module_function

    def native_type?(value, type)
      EvidenceValue.type?(value, type)
    end

    def owned_text(value, limit, scrub: true, state: nil)
      return nil unless Object.instance_method(:is_a?).bind_call(value, String)

      copy = String.new(value)
      state[:truncated] = true if state && (copy.bytesize > limit || !copy.valid_encoding?)
      copy = copy.byteslice(0, limit).force_encoding(Encoding::UTF_8).scrub
      # A split UTF-8 sequence can expand to a replacement character.
      copy = copy.byteslice(0, limit).force_encoding(Encoding::UTF_8).scrub('')
      copy = TelemetryPrivacy.protect(copy) if scrub
      state[:truncated] = true if state && copy.bytesize > limit
      copy.byteslice(0, limit).force_encoding(Encoding::UTF_8).scrub('')
    end

    def retained_snapshot(value, state)
      return nil unless native_type?(value, Hash)
      return nil if Hash.instance_method(:size).bind_call(value) > 32

      keys = Hash.instance_method(:keys).bind_call(value)
      return nil unless keys.all? { |key| native_type?(key, String) }

      result = {}
      { 'name' => 256, 'message' => 2048, 'stack' => 16_384 }.each do |key, limit|
        source = Hash.instance_method(:fetch).bind_call(value, key, nil)
        # Parse coordinates before a URL scrub can discard a fragment containing
        # the native line suffix. Only scrubbed fields/text enter the graph.
        result[key] = owned_text(source, limit, scrub: key != 'stack', state: state)
        return nil if result[key].nil?
      end
      result['name'] = 'Exception' if result['name'].empty?
      result['message'] = '[message unavailable]' if result['message'].empty?
      result
    end

    def from_retained(root:, causes:, fatal: false, budget_bytes: 32_768)
      maximum = [fatal ? 4096 : 32_768, budget_bytes].min
      return nil if maximum < 512

      state = { truncated: false }
      outer = retained_snapshot(root, state)
      return nil unless outer && native_type?(causes, Array)

      limit = fatal ? 2 : 5 # A linear cause path has at most four edges.
      count = Array.instance_method(:length).bind_call(causes)
      snapshots = [outer]
      [count, limit - 1].min.times do |index|
        cause = retained_snapshot(Array.instance_method(:[]).bind_call(causes, index), state)
        break unless cause

        snapshots << cause
      end
      graph = build_graph(snapshots, count > snapshots.length - 1 || state[:truncated])
      shrink_metadata(graph, maximum)
      return nil if JSON.generate(graph).bytesize > maximum

      append_traces(graph, snapshots, maximum, fatal ? 8 : 32)
      graph
    rescue StandardError
      nil
    end

    def build_graph(snapshots, truncated)
      nodes = snapshots.each_with_index.map do |snapshot, index|
        {
          'id' => index, 'name' => snapshot['name'], 'message' => snapshot['message'], 'stack' => nil,
          'trace_origin' => snapshot['stack'].empty? ? 'unavailable' : 'runtime_reported',
          'parsing_status' => snapshot['stack'].empty? ? 'unavailable' : 'unparsed', 'frames' => [],
          'relationships' => index + 1 < snapshots.length ? [{ 'kind' => 'cause', 'target_id' => index + 1 }] : []
        }
      end
      { 'version' => 1, 'runtime' => 'ruby', 'root_id' => 0, 'nodes' => nodes,
        'truncated' => truncated, 'unavailable_reason' => nil }
    end

    def shrink_metadata(graph, maximum)
      return if JSON.generate(graph).bytesize <= maximum - 32

      mark_budget(graph)
      graph['nodes'].each do |node|
        node['name'] = owned_text(node['name'], 64)
        node['message'] = owned_text(node['message'], 128)
      end
      while graph['nodes'].length > 1 && JSON.generate(graph).bytesize > maximum - 32
        graph['nodes'].pop
        graph['nodes'].last['relationships'] = []
      end
    end

    def append_traces(graph, snapshots, maximum, frame_limit)
      # Charge exact JSON fragments incrementally. Re-encoding the whole graph
      # for every rejected frame would amplify work on adversarial long stacks.
      used = JSON.generate(graph).bytesize + 32
      graph['nodes'].each_with_index do |node, index|
        stack = snapshots[index]['stack']
        stack.each_line do |line|
          frame = parse_frame(line)
          next unless frame

          cost = JSON.generate(frame).bytesize + (node['frames'].empty? ? 0 : 1)
          if node['frames'].length >= frame_limit || used + cost > maximum
            node['parsing_status'] = 'truncated'
            mark_budget(graph)
            break
          end
          node['frames'] << frame
          node['parsing_status'] = 'parsed'
          used += cost
        end
        next unless node['parsing_status'] == 'unparsed'

        retained = owned_text(stack, 16_384).gsub(%r{\bhttps?://[^\s<>"']+}i) { |url| frame_file(url) }
        cost = JSON.generate(retained).bytesize - 4 # Replaces JSON null.
        if used + cost <= maximum
          node['stack'] = retained
          used += cost
        else
          mark_budget(graph)
        end
      end
    end

    def parse_frame(line)
      match = /\A(.+):([1-9]\d*)(?::in [`']([^`'\r\n]*)[`'])?\z/.match(line.strip)
      return nil unless match

      { 'function' => match[3] && owned_text(match[3], 256), 'file' => frame_file(match[1]),
        'line' => match[2].to_i, 'column' => nil, 'classification' => 'unknown' }
    end

    def frame_file(value)
      result = owned_text(value, 2048)
      return result unless result.match?(%r{\Ahttps?://}i)

      uri = URI.parse(result)
      uri.password = nil
      uri.user = nil
      uri.query = nil
      uri.fragment = nil
      uri.to_s
    rescue URI::InvalidURIError
      '[withheld]'
    end

    def mark_budget(graph)
      graph['truncated'] = true
      graph['unavailable_reason'] = 'budget_exceeded'
    end
  end
end
