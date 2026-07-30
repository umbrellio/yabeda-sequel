# frozen_string_literal: true

RSpec.describe Yabeda::Sequel::Sampler do
  before { Yabeda::Sequel.config.sample_interval = 0.01 }

  after { Yabeda::Sequel.config.sample_interval = 5 }

  describe ".start!" do
    it "starts and reports itself running" do
      expect(described_class.start!).to be(true)
      expect(described_class).to be_running
    end

    it "is idempotent within a process" do
      described_class.start!
      expect(described_class.start!).to be(false)
    end

    it "samples repeatedly on its own" do
      Sequel::DATABASES.clear
      Sequel.mock(database: "shop")
      described_class.start!

      Timeout.timeout(5) do
        sleep(0.01) until Yabeda.sequel.connection_pool_processes.get(db: "shop")
      end

      expect(Yabeda.sequel.connection_pool_processes.get(db: "shop")).to eq(1)
    ensure
      Sequel::DATABASES.clear
    end

    it "keeps looping after an error and reports it" do
      errors = Queue.new
      Yabeda::Sequel.config.error_handler = ->(error) { errors << error }
      allow(described_class).to receive(:sample!).and_raise(RuntimeError, "boom")

      described_class.start!
      error = Timeout.timeout(5) { errors.pop }

      expect(error.message).to eq("boom")
      expect(described_class).to be_running
    end
  end

  describe ".stop!" do
    it "stops a running sampler" do
      described_class.start!
      described_class.stop!
      expect(described_class).not_to be_running
    end

    it "tolerates being called without a start" do
      expect { described_class.stop! }.not_to raise_error
    end

    it "is safe to call twice" do
      described_class.start!
      described_class.stop!
      expect { described_class.stop! }.not_to raise_error
    end

    it "leaves the mutex unlocked so a fork cannot inherit a held lock" do
      described_class.start!
      described_class.stop!
      expect(Yabeda::Sequel::Sampler::MUTEX).not_to be_locked
    end
  end

  describe "fork safety" do
    it "does not consider an inherited thread to be running" do
      described_class.start!
      reader, writer = IO.pipe

      pid = fork do
        reader.close
        writer.write(described_class.running? ? "running" : "stopped")
        writer.close
        exit!(0)
      end

      writer.close
      Process.wait(pid)
      expect(reader.read).to eq("stopped")
    ensure
      reader&.close
    end

    it "lets a forked child start its own sampler" do
      described_class.start!
      reader, writer = IO.pipe

      pid = fork do
        reader.close
        writer.write(described_class.start! ? "started" : "refused")
        writer.close
        exit!(0)
      end

      writer.close
      Process.wait(pid)
      expect(reader.read).to eq("started")
    ensure
      reader&.close
    end
  end
end
