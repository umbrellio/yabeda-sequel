# frozen_string_literal: true

RSpec.describe Yabeda::Sequel::PoolInstrumentation do
  %i[single sharded_single].each do |pool_class|
    it "leaves checkout metrics untouched on a #{pool_class} pool" do
      db = Sequel.mock(pool_class: pool_class, servers: { slave: {} })
      described_class.install!(db)

      expect { db.synchronize { nil } }
        .not_to increment_yabeda_counter(Yabeda.sequel.connection_pool_busy_seconds_total)
    end
  end

  %i[threaded timed_queue].each do |pool_class|
    next if pool_class == :timed_queue && !TIMED_QUEUE_SUPPORTED

    context "with a #{pool_class} pool" do
      describe ".install!" do
        it "installs onto a pool" do
          db = Sequel.mock(pool_class: pool_class)
          described_class.install!(db)
          expect(described_class).to be_installed(db)
        end

        it "does not prepend twice onto the same pool" do
          db = Sequel.mock(pool_class: pool_class)
          2.times { described_class.install!(db) }

          prepended = db.pool.singleton_class.ancestors.count { |mod| mod == described_class }
          expect(prepended).to eq(1)
        end

        it "refuses a frozen pool rather than raising" do
          db = Sequel.mock(pool_class: pool_class)
          db.pool.freeze

          expect { described_class.install!(db) }.not_to raise_error
          expect(described_class).not_to be_installed(db)
        end

        it "refuses an unsupported pool object" do
          db = Sequel.mock(pool_class: pool_class)
          allow(db).to receive(:pool).and_return(Object.new)

          expect { described_class.install!(db) }.not_to raise_error
          expect(described_class).not_to be_installed(db)
        end
      end

      describe "measuring checkouts" do
        it "measures a checkout" do
          db = Sequel.mock(pool_class: pool_class, database: "shop")
          described_class.install!(db)

          expect { db.synchronize { nil } }
            .to measure_yabeda_histogram(Yabeda.sequel.connection_pool_wait)
            .with_tags(db: "shop", server: "default")
        end

        # `hold` returns early via `owned_connection` when the thread already holds a
        # connection, so a nested checkout must not produce a second measurement.
        it "does not measure nested checkouts twice" do
          db = Sequel.mock(pool_class: pool_class, database: "shop")
          described_class.install!(db)
          allow(Yabeda.sequel.connection_pool_wait).to receive(:measure).and_call_original

          db.synchronize { db.synchronize { nil } }

          expect(Yabeda.sequel.connection_pool_wait).to have_received(:measure).once
        end

        it "labels the server on a sharded pool" do
          db = Sequel.mock(pool_class: :"sharded_#{pool_class}", database: "shop",
                           servers: { slave: {} })
          described_class.install!(db)

          expect { db[:items].server(:slave).all }
            .to measure_yabeda_histogram(Yabeda.sequel.connection_pool_wait)
            .with_tags(db: "shop", server: "slave")
        end

        it "does not measure anything before Yabeda is configured" do
          db = Sequel.mock(pool_class: pool_class, database: "shop")
          described_class.install!(db)
          allow(Yabeda).to receive(:configured?).and_return(false)

          expect { db.synchronize { nil } }
            .not_to measure_yabeda_histogram(Yabeda.sequel.connection_pool_wait)
        end
      end

      describe "pool timeouts" do
        it "counts a timeout and lets it propagate untouched" do
          db = Sequel.mock(pool_class: pool_class, database: "shop", max_connections: 1,
                           pool_timeout: 0)
          described_class.install!(db)

          # The only connection is held here, so the second thread cannot acquire one.
          error = db.synchronize do
            thread = Thread.new do
              db.synchronize { nil }
            rescue Sequel::PoolTimeout => error
              error
            end
            thread.report_on_exception = false
            thread.value
          end

          expect(error).to be_a(Sequel::PoolTimeout)
          timeouts = Yabeda::TestAdapter.instance.counters[Yabeda.sequel.connection_pool_timeouts_total]
          expect(timeouts[{ db: "shop", server: "default" }]).to eq(1)
        end
      end

      describe "isolation from application failures" do
        it "never lets a failed measurement break a query" do
          db = Sequel.mock(pool_class: pool_class, database: "shop")
          described_class.install!(db)
          errors = []
          Yabeda::Sequel.config.error_handler = -> (error) { errors << error }
          allow(Yabeda.sequel.connection_pool_wait).to receive(:measure).and_raise("metrics down")

          expect { db.synchronize { nil } }.not_to raise_error
          expect(errors.map(&:message)).to eq(["metrics down"])
        end

        it "still returns the block's value" do
          db = Sequel.mock(pool_class: pool_class, database: "shop")
          described_class.install!(db)

          expect(db.synchronize { :result }).to eq(:result)
        end
      end
    end
  end
end

RSpec.describe "Connection busy time" do
  pool_classes = %i[threaded sharded_threaded]
  pool_classes.push(:timed_queue, :sharded_timed_queue) if TIMED_QUEUE_SUPPORTED

  pool_classes.each do |pool_class|
    context "with a #{pool_class} pool" do
      let(:max_connections) { 2 }
      let(:sharded) { pool_class.to_s.start_with?("sharded_") }
      let(:db) do
        Sequel.mock(database: "shop", pool_class: pool_class, max_connections: max_connections,
                    servers: (sharded ? { slave: {} } : nil))
      end
      let(:metric) { Yabeda.sequel.connection_pool_busy_seconds_total }
      let(:tags) { { db: "shop", server: "default" } }
      let(:increments) { Yabeda::TestAdapter.instance.counters[metric] }
      let(:timers) { db.pool.instance_variable_get(:@yabeda_sequel_timers) }
      let(:entries) { timers.instance_variable_get(:@checkouts) }
      let(:clock) { [10.0] }
      let(:disconnect_total) { pool_class == :sharded_threaded ? 5 : 3 }

      def busy_seconds(tags)
        db.pool.yabeda_sequel_flush_busy_time
        increments[tags]
      end

      before do
        Yabeda::Sequel::PoolInstrumentation.install!(db)
        allow(Process).to receive(:clock_gettime).and_call_original
        allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { clock[0] }
      end

      it "counts held time with pool tags and excludes checkout wait" do
        allow(db.pool).to receive(:make_new).and_wrap_original do |original, *args|
          clock[0] += 3
          original.call(*args)
        end
        db.disconnect

        db.synchronize { clock[0] += 2.5 }

        expect(busy_seconds(tags)).to eq(2.5)
        waits = Yabeda::TestAdapter.instance.histograms[Yabeda.sequel.connection_pool_wait]
        expect(waits[tags]).to eq(3)
        expect(entries).to be_empty
      end

      it "counts the outer checkout once when holds are nested" do
        db.synchronize do
          clock[0] += 1
          db.synchronize { clock[0] += 2 }
          expect(busy_seconds(tags)).to eq(0)
          clock[0] += 1
        end

        expect(busy_seconds(tags)).to eq(4)
      end

      it "does not take the timer mutex for nested holds" do
        calls = []
        mutex = timers.instance_variable_get(:@mutex)
        allow(mutex).to receive(:synchronize).and_wrap_original do |original, &block|
          calls << true
          original.call(&block)
        end
        db.synchronize do
          before_nested = calls.size
          db.synchronize { nil }
          expect(calls.size).to eq(before_nested)
        end
      end

      it "counts concurrent owners independently" do
        ready = Queue.new
        finish = Queue.new
        threads = Array.new(2) do
          Thread.new do
            db.synchronize do
              ready.push(true)
              finish.pop
            end
          end
        end
        2.times { ready.pop }
        clock[0] += 3
        2.times { finish.push(true) }
        threads.each(&:value)

        expect(busy_seconds(tags)).to eq(6)
        expect(entries).to be_empty
      ensure
        threads&.each { |thread| thread.kill.join }
      end

      it "keeps Fiber owners on the same thread separate" do
        allow(Sequel).to receive(:current) { Fiber.current }
        fibers = Array.new(2) { Fiber.new { db.synchronize { Fiber.yield } } }
        fibers.each(&:resume)
        clock[0] += 3
        fibers.each(&:resume)

        expect(busy_seconds(tags)).to eq(6)
        expect(entries).to be_empty
      end

      it "cleans up after validator retries and validation errors" do
        db.extension(:connection_validator)
        db.pool.connection_validation_timeout = -1
        db.synchronize { clock[0] += 1 }
        allow(db).to receive(:valid_connection?) do
          clock[0] += 10
          false
        end
        db.synchronize { clock[0] += 2 }
        expect(busy_seconds(tags)).to eq(3)
        expect(entries).to be_empty

        allow(db).to receive(:valid_connection?).and_raise("validation failed")
        expect { db.synchronize { nil } }.to raise_error("validation failed")
        expect(entries).to be_empty
      end

      it "does not time connections discarded during expiration retries" do
        db.extension(:connection_expiration)
        db.pool.connection_expiration_timeout = 5
        db.disconnect
        first = db.synchronize do |connection|
          clock[0] += 1
          connection
        end
        clock[0] += 10
        second = db.synchronize do |connection|
          clock[0] += 2
          connection
        end

        expect(second).not_to equal(first)
        expect(busy_seconds(tags)).to eq(3)
        expect(entries).to be_empty
      end

      it "counts time even when the block raises a normal error" do
        expect do
          db.synchronize do
            clock[0] += 2
            raise "query failed"
          end
        end.to raise_error(RuntimeError, "query failed")

        expect(busy_seconds(tags)).to eq(2)
        expect(entries).to be_empty
      end

      it "never attributes disconnected checkout time to the next checkout" do
        expect do
          db.synchronize do
            clock[0] += 2
            raise Sequel::DatabaseDisconnectError
          end
        end.to raise_error(Sequel::DatabaseDisconnectError)

        clock[0] += 100
        db.synchronize { clock[0] += 3 }

        expect(busy_seconds(tags)).to eq(disconnect_total)
        expect(entries).to be_empty
      end

      it "discards stale time when the next acquisition is unconfigured" do
        expect do
          db.synchronize { raise Sequel::DatabaseDisconnectError }
        end.to raise_error(Sequel::DatabaseDisconnectError)
        clock[0] += 100
        allow(Yabeda).to receive(:configured?).and_return(false)
        db.synchronize do
          clock[0] += 2
          allow(Yabeda).to receive(:configured?).and_return(true)
        end

        expect(busy_seconds(tags)).to eq(0)
        expect(entries).to be_empty
      end

      it "does not let a counter write break a query or retain its timer" do
        errors = []
        Yabeda::Sequel.config.error_handler = -> (error) { errors << error }
        allow(metric).to receive(:increment).and_raise("counter down")

        expect(db.synchronize do
          clock[0] += 1
          :result
        end).to eq(:result)
        db.pool.yabeda_sequel_flush_busy_time
        expect(errors.map(&:message)).to eq(["counter down"])
        expect(entries).to be_empty
      end

      it "ignores a checkout that began before Yabeda was configured" do
        allow(Yabeda).to receive(:configured?).and_return(false)
        db.synchronize do
          clock[0] += 2
          allow(Yabeda).to receive(:configured?).and_return(true)
        end

        expect(busy_seconds(tags)).to eq(0)
        expect(entries).to be_empty
      end

      it "clears a timer even if Yabeda is unconfigured at release" do
        db.synchronize do
          clock[0] += 2
          allow(Yabeda).to receive(:configured?).and_return(false)
        end
        expect(entries).to be_empty
        allow(Yabeda).to receive(:configured?).and_return(true)
        db.synchronize { clock[0] += 1 }

        expect(busy_seconds(tags)).to eq(1)
      end

      it "does not report a parent's checkout in a forked child" do
        IO.pipe do |reader, writer|
          db.synchronize do |connection|
            pid = fork do
              reader.close
              clock[0] += 1000
              args = sharded ? [Sequel.current, connection, :default] : [Sequel.current]
              db.pool.send(:release, *args)
              writer.write("#{busy_seconds(tags)},")
              db.synchronize { clock[0] += 3 }
              writer.write(busy_seconds(tags).to_s)
              writer.close
              exit!(0)
            end
            writer.close
            Process.wait(pid)
            expect(reader.read.split(",").map(&:to_f)).to eq([0, 3])
            clock[0] += 2
          end
        end

        expect(busy_seconds(tags)).to eq(2)
      end

      context "with one connection" do
        let(:max_connections) { 1 }

        it "drops abandoned timers when Sequel reclaims a dead owner" do
          abandoned = Thread.new do
            args = sharded ? [Sequel.current, :default] : [Sequel.current]
            db.pool.send(:acquire, *args)
          end
          abandoned.value
          clock[0] += 100
          db.synchronize do
            db.synchronize { nil }
            clock[0] += 1
          end
          db.synchronize { clock[0] += 1 }

          expect(entries).to be_empty
          expect(busy_seconds(tags)).to eq(2)
        end

        it "prunes dead owners no more than once per sample interval" do
          abandoned = Thread.new do
            args = sharded ? [Sequel.current, :default] : [Sequel.current]
            db.pool.send(:acquire, *args)
          end
          abandoned.value
          3.times { db.synchronize { nil } }
          expect(entries.keys).to include(abandoned)
          clock[0] += Yabeda::Sequel.config.sample_interval
          db.synchronize { nil }

          expect(entries).to be_empty
          expect(busy_seconds(tags)).to eq(0)
        end

        it "counts temporary releases as separate intervals" do
          skip "Temporary releases are unavailable" unless TEMPORARY_RELEASE_SUPPORTED

          db.extension(:temporarily_release_connection)
          db.synchronize do |connection|
            clock[0] += 2
            db.temporarily_release_connection(connection) { clock[0] += 100 }
            db.synchronize { clock[0] += 1 }
            clock[0] += 2
          end

          expect(busy_seconds(tags)).to eq(5)
          expect(entries).to be_empty
        end

        it "keeps timing after a temporary release inside a nested hold" do
          skip "Temporary releases are unavailable" unless TEMPORARY_RELEASE_SUPPORTED

          db.extension(:temporarily_release_connection)
          db.synchronize do |connection|
            clock[0] += 1
            db.synchronize do
              clock[0] += 1
              db.temporarily_release_connection(connection) { clock[0] += 100 }
              clock[0] += 2
            end
            clock[0] += 3
          end

          expect(busy_seconds(tags)).to eq(7)
        end

        it "never carries disconnected time across a temporary reacquisition" do
          skip "Temporary releases are unavailable" unless TEMPORARY_RELEASE_SUPPORTED

          db.extension(:temporarily_release_connection)
          expect do
            db.synchronize do |connection|
              clock[0] += 2
              db.temporarily_release_connection(connection) { clock[0] += 100 }
              clock[0] += 3
              raise Sequel::DatabaseDisconnectError
            end
          end.to raise_error(Sequel::DatabaseDisconnectError)

          clock[0] += 100
          db.synchronize { clock[0] += 3 }

          expect(busy_seconds(tags)).to eq(pool_class == :sharded_threaded ? 8 : 5)
          expect(entries).to be_empty
        end
      end

      if pool_class.to_s.start_with?("sharded_")
        it "keeps overlapping checkouts on different shards separate" do
          db.synchronize do
            clock[0] += 1
            db.synchronize(:slave) { clock[0] += 2 }
            clock[0] += 1
          end

          expect(busy_seconds(tags)).to eq(4)
          expect(busy_seconds(db: "shop", server: "slave")).to eq(2)
        end
      end
    end
  end
end
