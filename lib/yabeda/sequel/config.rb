# frozen_string_literal: true

require "anyway_config"

module Yabeda
  module Sequel
    # Settings, overridable via ENV (YABEDA_SEQUEL_*) or config/yabeda_sequel.yml.
    class Config < ::Anyway::Config
      config_name :yabeda_sequel
      env_prefix :YABEDA_SEQUEL

      attr_config(
        sample_interval: 5,
        instrument_checkouts: true,
        autostart: true,
        wait_buckets: [0.0005, 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
      )

      # A proc can't come from ENV or YAML, so this is a plain accessor rather
      # than part of attr_config.
      attr_writer :error_handler

      def error_handler
        @error_handler ||= ->(error) { warn("[yabeda-sequel] #{error.class}: #{error.message}") }
      end
    end
  end
end
