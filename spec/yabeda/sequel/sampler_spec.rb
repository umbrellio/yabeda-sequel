# frozen_string_literal: true

RSpec.describe Yabeda::Sequel::Sampler do
  before { Sequel::DATABASES.clear }

  after { Sequel::DATABASES.clear }

  describe ".sample!" do
    it "reports connections per server" do
      db = Sequel.mock(database: "shop", servers: { slave: {} })
      db.synchronize { nil }

      expect { described_class.sample! }
        .to update_yabeda_gauge(Yabeda.sequel.connection_pool_connections)
        .with_tags(db: "shop", server: "default").with(1)
    end

    it "reports the ceiling for every server" do
      Sequel.mock(database: "shop", servers: { slave: {} })

      expect { described_class.sample! }
        .to update_yabeda_gauge(Yabeda.sequel.connection_pool_size)
        .with({ db: "shop", server: "default" } => 4, { db: "shop", server: "slave" } => 4)
    end

    it "reports exactly one process per database" do
      Sequel.mock(database: "shop")

      expect { described_class.sample! }
        .to update_yabeda_gauge(Yabeda.sequel.connection_pool_processes)
        .with_tags(db: "shop").with(1)
    end

    it "reports a waiter count on timed_queue pools" do
      skip("timed_queue requires Ruby 3.2+") unless TIMED_QUEUE_SUPPORTED
      Sequel.mock(database: "shop", pool_class: :timed_queue)

      expect { described_class.sample! }
        .to update_yabeda_gauge(Yabeda.sequel.connection_pool_waiting)
        .with_tags(db: "shop", server: "default").with(0)
    end

    it "omits the waiter count on legacy pools that cannot report it" do
      Sequel.mock(database: "shop", pool_class: :threaded)

      expect { described_class.sample! }
        .not_to update_yabeda_gauge(Yabeda.sequel.connection_pool_waiting)
    end

    it "covers every connected database" do
      Sequel.mock(database: "shop")
      Sequel.mock(database: "warehouse")

      expect { described_class.sample! }
        .to update_yabeda_gauge(Yabeda.sequel.connection_pool_processes)
        .with({ db: "shop" } => 1, { db: "warehouse" } => 1)
    end

    it "still reports a single_threaded database rather than skipping it" do
      Sequel.mock(database: "shop", single_threaded: true)

      expect { described_class.sample! }
        .to update_yabeda_gauge(Yabeda.sequel.connection_pool_size)
        .with_tags(db: "shop", server: "default").with(1)
    end

    it "skips async gauges when the database has no async executor" do
      Sequel.mock(database: "shop")

      expect { described_class.sample! }
        .not_to update_yabeda_gauge(Yabeda.sequel.async_pool_threads)
    end

    it "reports async pool stats when an executor is present" do
      db = Sequel.mock(database: "shop")
      executor = Concurrent::ThreadPoolExecutor.new(min_threads: 0, max_threads: 3, max_queue: 0)
      db.define_singleton_method(:async_thread_executor) { executor }

      expect { described_class.sample! }
        .to update_yabeda_gauge(Yabeda.sequel.async_pool_max_threads)
        .with_tags(db: "shop").with(3)
    ensure
      executor&.shutdown
    end

    # Sequel-using apps often swap in an ImmediateExecutor under test, and it
    # implements none of the introspection methods. Guarding on capability rather
    # than on environment keeps that harmless.
    it "ignores an executor that cannot introspect itself" do
      db = Sequel.mock(database: "shop")
      immediate = Concurrent::ImmediateExecutor.new
      db.define_singleton_method(:async_thread_executor) { immediate }

      expect { described_class.sample! }
        .not_to update_yabeda_gauge(Yabeda.sequel.async_pool_threads)
    end
  end
end
