# frozen_string_literal: true

require 'socket'

module DebugBundle
  module Runtime
    def self.payload
      {
        'version' => RUBY_VERSION,
        'platform' => RUBY_PLATFORM,
        'pid' => Process.pid,
        'cwd' => Dir.pwd,
        'hostname' => Socket.gethostname,
        'thread_id' => Thread.current.object_id,
        'engine' => defined?(RUBY_ENGINE) ? RUBY_ENGINE : 'ruby',
        'engine_version' => defined?(RUBY_ENGINE_VERSION) ? RUBY_ENGINE_VERSION : RUBY_VERSION
      }
    rescue StandardError
      { 'version' => RUBY_VERSION }
    end
  end
end
