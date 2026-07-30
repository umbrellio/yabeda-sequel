# frozen_string_literal: true

RSpec.describe Yabeda::Sequel do
  describe ".start!" do
    before { Sequel::DATABASES.clear }

    after { Sequel::DATABASES.clear }

    it "starts the sampler" do
      described_class.start!
      expect(Yabeda::Sequel::Sampler).to be_running
    end

    it "installs checkout instrumentation on connected databases" do
      db = Sequel.mock(database: "shop")

      described_class.start!

      expect(Yabeda::Sequel::PoolInstrumentation).to be_installed(db)
    end

    it "skips instrumentation when the kill switch is off" do
      db = Sequel.mock(database: "shop")
      described_class.config.instrument_checkouts = false

      described_class.start!

      expect(Yabeda::Sequel::PoolInstrumentation).not_to be_installed(db)
    ensure
      described_class.config.instrument_checkouts = true
    end
  end

  describe ".safely" do
    it "returns the block's value" do
      expect(described_class.safely { 42 }).to eq(42)
    end

    it "routes an error to the handler instead of raising" do
      errors = []
      described_class.config.error_handler = -> (error) { errors << error }

      expect { described_class.safely { raise "nope" } }.not_to raise_error
      expect(errors.map(&:message)).to eq(["nope"])
    end

    it "returns nil when the block failed" do
      described_class.config.error_handler = -> (_error) {}
      expect(described_class.safely { raise "nope" }).to be_nil
    end
  end

  describe ".config" do
    it "returns the same instance on repeat calls" do
      memoized = described_class.config
      expect(described_class.config).to be(memoized)
    end
  end
end
