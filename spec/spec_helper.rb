# frozen_string_literal: true

require "timeout"
require "tmpdir"
require "fileutils"

require "yabeda-sequel"
require "yabeda/rspec"

# Sequel's timed_queue pools need Ruby 3.2+, and its default pool class differs
# either side of that line — so specs that care request a pool class explicitly.
TIMED_QUEUE_SUPPORTED = RUBY_VERSION >= "3.2"

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
