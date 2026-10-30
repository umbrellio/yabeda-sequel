# frozen_string_literal: true

require "timeout"
require "tmpdir"
require "fileutils"

require "yabeda-sequel"
require "yabeda/rspec"

# The timed_queue pools need both Ruby 3.2+ and a Sequel new enough to ship them,
# so this probes for the capability rather than guessing from either version.
# Specs that care about a specific pool always request it explicitly, since
# Sequel's default pool class differs across versions.
TIMED_QUEUE_SUPPORTED = begin
  Sequel.mock(pool_class: :timed_queue).pool.pool_type == :timed_queue
rescue StandardError, LoadError
  false
end

TEMPORARY_RELEASE_SUPPORTED = begin
  Sequel.extension(:temporarily_release_connection)
  true
rescue LoadError
  false
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }

  # Never leave a sampler thread running between examples.
  config.after do
    Yabeda::Sequel::Sampler.stop! if defined?(Yabeda::Sequel::Sampler)
    Yabeda::Sequel.config.error_handler = nil
  end
end
