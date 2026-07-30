# frozen_string_literal: true

require "sequel"
require "yabeda"

require_relative "sequel/version"
require_relative "sequel/config"
require_relative "sequel/naming"

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
