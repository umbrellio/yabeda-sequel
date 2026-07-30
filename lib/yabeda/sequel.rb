# frozen_string_literal: true

require "sequel"
require "yabeda"

require_relative "sequel/version"
require_relative "sequel/config"
require_relative "sequel/naming"
require_relative "sequel/pool_reader"
require_relative "sequel/metrics"
require_relative "sequel/pool_instrumentation"
require_relative "sequel/sampler"

module Yabeda
  # Connection pool and async thread pool metrics for Sequel.
  #
  # NOTE: inside this namespace a bare `Sequel` resolves to `Yabeda::Sequel`.
  # Always write `::Sequel` when the real Sequel is meant.
  module Sequel
    class << self
      def config
        @config ||= Config.new
      end

      # Call once per process, after fork. Idempotent.
      def start!
        install_instrumentation! if config.instrument_checkouts
        Sampler.start!
      end

      # Call before forking, so no sampler thread is mid-sample at fork time.
      def stop!
        Sampler.stop!
      end

      def install_instrumentation!
        ::Sequel::DATABASES.each { |db| PoolInstrumentation.install!(db) }
      end

      # Metric writes must never surface as application failures.
      def safely
        yield
      rescue StandardError => error
        config.error_handler.call(error)
        nil
      end
    end
  end
end

# Queue the metric declarations at require time. They are registered when the
# host application calls Yabeda.configure!.
Yabeda::Sequel::Metrics.install!

require_relative "sequel/railtie" if defined?(Rails::Railtie)
