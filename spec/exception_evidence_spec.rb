# frozen_string_literal: true

require 'spec_helper'
require 'debugbundle/exception_evidence'

RSpec.describe DebugBundle::ExceptionEvidence do
  let(:root) { { 'name' => 'RuntimeError', 'message' => 'outer', 'stack' => "/app/jobs.rb:40:in 'calculate'" } }
  let(:cause) { { 'name' => 'ArgumentError', 'message' => 'inner', 'stack' => "/app/db.rb:7:in `lookup'" } }

  it 'turns retained native cause snapshots into bounded linked nodes without mutating the old fields' do
    graph = described_class.from_retained(root: root, causes: [cause])
    expect(graph['nodes'].map { |node| node['name'] }).to eq(%w[RuntimeError ArgumentError])
    expect(graph['nodes'][0]['relationships']).to eq([{ 'kind' => 'cause', 'target_id' => 1 }])
    expect(graph['nodes'][0]['frames'][0]).to eq('function' => 'calculate', 'file' => '/app/jobs.rb',
                                                 'line' => 40, 'column' => nil, 'classification' => 'unknown')
    expect(graph['nodes'][1]['frames'][0]['function']).to eq('lookup')
    expect(root['stack']).to eq("/app/jobs.rb:40:in 'calculate'")
  end

  it 'never formats an application object or invokes native-error accessors itself' do
    calls = []
    foreign = Object.new
    foreign.define_singleton_method(:to_s) do
      calls << :format
      'foreign'
    end
    foreign.define_singleton_method(:to_str) do
      calls << :convert
      'foreign'
    end
    expect(described_class.from_retained(root: foreign, causes: [])).to be_nil
    expect(described_class.from_retained(root: root.merge('message' => foreign), causes: [])).to be_nil
    expect(calls).to eq([])
  end

  it 'does not dispatch equality through a foreign class while checking retained snapshots' do
    calls = []
    type = Class.new
    type.define_singleton_method(:equal?) do |_other|
      calls << :class_equality
      false
    end
    expect(described_class.from_retained(root: type.new, causes: [])).to be_nil
    expect(calls).to eq([])
  end

  it 'honestly distinguishes absent and unparsed retained traces and sanitises URL locations' do
    absent = described_class.from_retained(root: root.merge('stack' => ''), causes: [])
    expect(absent['nodes'][0]).to include('trace_origin' => 'unavailable', 'parsing_status' => 'unavailable',
                                          'frames' => [])
    unknown = described_class.from_retained(root: root.merge('stack' => 'retained unfamiliar trace'), causes: [])
    expect(unknown['nodes'][0]).to include('parsing_status' => 'unparsed', 'stack' => 'retained unfamiliar trace')
    url = root.merge('stack' => "https://user:password@cdn.example/app.rb?token=secret#part:3:in 'run'")
    graph = described_class.from_retained(root: url, causes: [])
    expect(graph['nodes'][0]['frames'][0]['file']).to eq('https://cdn.example/app.rb')
  end

  it 'enforces cause depth, per-node frames and the smaller crash total under escaped Unicode' do
    large = root.merge('message' => "\u0001" * 2048, 'stack' => Array.new(40) do |i|
      "/app/#{'é' * 500}#{i}.rb:1:in 'run'"
    end.join("\n"))
    normal = described_class.from_retained(root: large, causes: Array.new(8) { cause })
    expect(normal['nodes'].length).to be <= 5
    expect(normal['nodes'].all? { |node| node['frames'].length <= 32 }).to be(true)
    expect(normal['truncated']).to be(true)
    expect(JSON.generate(normal).bytesize).to be <= 32 * 1024
    fatal = described_class.from_retained(root: large, causes: [cause, cause], fatal: true, budget_bytes: 3500)
    expect(fatal['nodes'].length).to be <= 2
    expect(fatal['nodes'].all? { |node| node['frames'].length <= 8 }).to be(true)
    expect(JSON.generate(fatal).bytesize).to be <= 3500
    expect(described_class.from_retained(root: root, causes: [], budget_bytes: 100)).to be_nil
  end
end
