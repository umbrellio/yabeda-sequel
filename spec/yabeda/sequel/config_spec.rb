# frozen_string_literal: true

RSpec.describe Yabeda::Sequel::Config do
  it "defaults the sample interval" do
    expect(described_class.new.sample_interval).to eq(5)
  end

  it "instruments checkouts by default" do
    expect(described_class.new.instrument_checkouts).to be(true)
  end

  it "autostarts by default" do
    expect(described_class.new.autostart).to be(true)
  end

  it "provides wait buckets topping out at Sequel's default pool timeout" do
    expect(described_class.new.wait_buckets.last).to eq(5)
  end

  it "reads overrides from the environment" do
    ENV["YABEDA_SEQUEL_SAMPLE_INTERVAL"] = "0.5"
    expect(described_class.new.sample_interval.to_f).to eq(0.5)
  ensure
    ENV.delete("YABEDA_SEQUEL_SAMPLE_INTERVAL")
  end

  it "can be told not to autostart from the environment" do
    ENV["YABEDA_SEQUEL_AUTOSTART"] = "false"
    expect(described_class.new.autostart).to be(false)
  ensure
    ENV.delete("YABEDA_SEQUEL_AUTOSTART")
  end

  it "provides a callable default error handler" do
    expect(described_class.new.error_handler).to respond_to(:call)
  end

  it "accepts a custom error handler" do
    config = described_class.new
    config.error_handler = ->(error) { error }
    expect(config.error_handler.call(:boom)).to eq(:boom)
  end
end
