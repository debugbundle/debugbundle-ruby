# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DebugBundle do
  before do
    described_class.client = DebugBundle::Client.new
  end

  it 'exposes the universal singleton interface' do
    client = described_class.init(project_token: 'dbundle_proj_test', service: 'checkout-api')

    expect(client).to be_a(DebugBundle::Client)
    expect(described_class).to respond_to(:init)
    expect(described_class).to respond_to(:capture_exception)
    expect(described_class).to respond_to(:capture_error)
    expect(described_class).to respond_to(:capture_log)
    expect(described_class).to respond_to(:capture_request)
    expect(described_class).to respond_to(:capture_message)
    expect(described_class).to respond_to(:set_context)
    expect(described_class).to respond_to(:probe)
    expect(described_class).to respond_to(:flush)
    expect(described_class).to respond_to(:status)
    expect(described_class).to respond_to(:last_event_at)
  end

  it 'arms exception capture when initialized' do
    client = instance_double(DebugBundle::Client)
    allow(DebugBundle::Client).to receive(:new).and_return(client)
    allow(client).to receive(:capture_exceptions).and_return(true)

    expect(client).to receive(:capture_exceptions)
    expect(described_class.init(project_token: 'dbundle_proj_test')).to be(client)
  end

  it 'reports a degraded status without a configured project token' do
    described_class.client = DebugBundle::Client.new

    expect(described_class.status).to eq(:degraded)
  end

  it 'records the last event timestamp on flush' do
    transport = Class.new do
      def call(_request)
        DebugBundle::Transport::Result.new(status_code: 202)
      end
    end.new

    described_class.client = DebugBundle::Client.new(project_token: 'dbundle_proj_test', transport: transport)
    described_class.capture_log('worker started', level: :warning)

    expect { described_class.flush }.to change(described_class, :last_event_at).from(nil)
  end
end
