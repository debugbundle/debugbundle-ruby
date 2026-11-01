# frozen_string_literal: true

module DebugBundle
  module EvidenceGraph
    module_function

    def valid?(value)
      wire = EvidenceWire
      return false unless wire.closed(value, %w[version runtime root_id nodes truncated unavailable_reason])
      return false unless wire.integer(value['version'], 1, 1) && wire.integer(value['root_id'], 0, 7)
      return false unless %w[node browser python php jvm go ruby dotnet android swift react_native
                             unknown].include?(value['runtime'])
      return false unless [true, false].include?(value['truncated']) &&
                          [nil, 'unknown', 'unsupported', 'unsafe',
                           'budget_exceeded'].include?(value['unavailable_reason'])

      nodes = value['nodes']
      return false unless nodes.is_a?(Array) && nodes.length.between?(1, 8)

      adjacency = {}
      nodes.each do |node|
        return false unless valid_node?(node) && !adjacency.key?(node['id'])

        adjacency[node['id']] = node['relationships'].map { |edge| edge['target_id'] }
      end
      visited = {}
      visit(value['root_id'], adjacency, [], visited) && visited.length == nodes.length &&
        EvidenceJson.bytes(value) <= 32_768
    end

    def valid_node?(node)
      wire = EvidenceWire
      return false unless wire.closed(node, %w[id name message stack trace_origin parsing_status frames relationships])
      return false unless wire.integer(node['id'], 0,
                                       7) && wire.text(node['name'], 256) && wire.text(node['message'], 2048)
      return false unless node['stack'].nil? || wire.text(node['stack'], 16_384)
      return false unless %w[throw native_fatal capture runtime_reported unavailable
                             unknown].include?(node['trace_origin'])
      return false unless %w[parsed partial unparsed unavailable truncated].include?(node['parsing_status'])

      frames = node['frames']
      frames.is_a?(Array) && frames.length <= 32 && frames.all? { |frame| valid_frame?(frame) } &&
        valid_edges?(node['relationships'])
    end

    def valid_frame?(frame)
      wire = EvidenceWire
      wire.closed(frame, %w[function file line column classification]) &&
        (frame['function'].nil? || wire.text(frame['function'], 256)) &&
        (frame['file'].nil? || wire.text(frame['file'], 2048)) &&
        (frame['line'].nil? || wire.integer(frame['line'], 1)) &&
        (frame['column'].nil? || wire.integer(frame['column'], 0)) &&
        %w[application framework sdk unknown].include?(frame['classification'])
    end

    def valid_edges?(edges)
      return false unless edges.is_a?(Array) && edges.length <= 5 && edges.uniq.length == edges.length
      return false if edges.count { |edge| edge.is_a?(Hash) && %w[cause context].include?(edge['kind']) } > 1

      edges.all? do |edge|
        EvidenceWire.closed(edge, %w[kind target_id]) &&
          %w[cause context aggregate suppressed].include?(edge['kind']) && EvidenceWire.integer(edge['target_id'], 0, 7)
      end
    end

    def visit(id, adjacency, path, visited)
      return false if path.length > 4 || path.include?(id) || !adjacency.key?(id)

      visited[id] = true
      adjacency[id].all? { |target| visit(target, adjacency, path + [id], visited) }
    end
  end
end
