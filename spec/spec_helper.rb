# frozen_string_literal: true

require "timeout"
require "tmpdir"
require "fileutils"

require "yabeda-sequel"
require "yabeda/rspec"

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
