# frozen_string_literal: true

RSpec.describe Yabeda::Sequel::PoolInstrumentation do
  describe ".install!" do
    it "installs onto a pool" do
      expect(described_class.install!(Sequel.mock)).to be(true)
    end

    it "does not install twice onto the same pool" do
      db = Sequel.mock
      described_class.install!(db)
      expect(described_class.install!(db)).to be(false)
    end

    it "refuses a frozen pool rather than raising" do
      db = Sequel.mock
      db.pool.freeze
      expect(described_class.install!(db)).to be(false)
    end

    it "refuses an unsupported pool object" do
      db = Sequel.mock
      allow(db).to receive(:pool).and_return(Object.new)
      expect(described_class.install!(db)).to be(false)
    end
  end

  describe "measuring checkouts" do
    it "measures a checkout" do
      db = Sequel.mock(database: "shop")
      described_class.install!(db)

      expect { db.synchronize { nil } }
        .to measure_yabeda_histogram(Yabeda.sequel.connection_pool_wait)
        .with_tags(db: "shop", server: "default")
    end

    # `hold` returns early via `owned_connection` when the thread already holds a
    # connection, so a nested checkout must not produce a second measurement.
    it "does not measure nested checkouts twice" do
      db = Sequel.mock(database: "shop")
      described_class.install!(db)
      allow(Yabeda.sequel.connection_pool_wait).to receive(:measure).and_call_original

      db.synchronize { db.synchronize { nil } }

      expect(Yabeda.sequel.connection_pool_wait).to have_received(:measure).once
    end

    it "labels the server on a sharded pool" do
      db = Sequel.mock(database: "shop", servers: { slave: {} })
      described_class.install!(db)

      expect { db[:items].server(:slave).all }
        .to measure_yabeda_histogram(Yabeda.sequel.connection_pool_wait)
        .with_tags(db: "shop", server: "slave")
    end

    it "does not measure anything before Yabeda is configured" do
      db = Sequel.mock(database: "shop")
      described_class.install!(db)
      allow(Yabeda).to receive(:configured?).and_return(false)

      expect { db.synchronize { nil } }
        .not_to measure_yabeda_histogram(Yabeda.sequel.connection_pool_wait)
    end
  end

  describe "pool timeouts" do
    it "counts a timeout and lets it propagate untouched" do
      db = Sequel.mock(database: "shop", max_connections: 1, pool_timeout: 0)
      described_class.install!(db)

      # The only connection is held here, so the second thread cannot acquire one.
      error = db.synchronize do
        thread = Thread.new do
          db.synchronize { nil }
        rescue ::Sequel::PoolTimeout => e
          e
        end
        thread.report_on_exception = false
        thread.value
      end

      expect(error).to be_a(Sequel::PoolTimeout)
      expect(Yabeda.sequel.connection_pool_timeouts_total.get(db: "shop", server: "default"))
        .to eq(1)
    end
  end

  describe "isolation from application failures" do
    it "never lets a failed measurement break a query" do
      db = Sequel.mock(database: "shop")
      described_class.install!(db)
      errors = []
      Yabeda::Sequel.config.error_handler = ->(error) { errors << error }
      allow(Yabeda.sequel.connection_pool_wait).to receive(:measure).and_raise("metrics down")

      expect { db.synchronize { nil } }.not_to raise_error
      expect(errors.map(&:message)).to eq(["metrics down"])
    end

    it "still returns the block's value" do
      db = Sequel.mock(database: "shop")
      described_class.install!(db)

      expect(db.synchronize { :result }).to eq(:result)
    end
  end
end
