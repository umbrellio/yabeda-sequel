# frozen_string_literal: true

module Yabeda
  module Sequel
    # Metric declarations.
    #
    # Only ever calls Yabeda.configure, which queues a configurator. Calling
    # Yabeda.configure! is the host application's job and raises if done twice.
    #
    # Exported names are built as [group, name, unit].compact.join("_"), and
    # prometheus-client does not add `_total` to counters — hence the explicit
    # suffix on connection_pool_timeouts_total.
    module Metrics
      POOL_TAGS = %i[db server].freeze
      DB_TAGS = %i[db].freeze

      class << self
        def install!
          Yabeda.configure do
            group :sequel do
              gauge :connection_pool_processes,
                    tags: DB_TAGS, aggregation: :sum,
                    comment: "Processes reporting pool metrics for this database"

              gauge :connection_pool_connections,
                    tags: POOL_TAGS, aggregation: :sum,
                    comment: "Connections currently open in the pool"

              gauge :connection_pool_size,
                    tags: POOL_TAGS, aggregation: :sum,
                    comment: "Maximum connections the pool may open"

              gauge :connection_pool_waiting,
                    tags: POOL_TAGS, aggregation: :sum,
                    comment: "Threads waiting to check out a connection"

              histogram :connection_pool_wait,
                        tags: POOL_TAGS, unit: :seconds, aggregation: :sum,
                        buckets: Yabeda::Sequel.config.wait_buckets,
                        comment: "Time spent waiting to check out a connection"

              counter :connection_pool_busy_seconds_total,
                      tags: POOL_TAGS, aggregation: :sum,
                      comment: "Seconds connections spent checked out of the pool"

              counter :connection_pool_timeouts_total,
                      tags: POOL_TAGS, aggregation: :sum,
                      comment: "Checkouts that failed with Sequel::PoolTimeout"

              gauge :async_pool_threads,
                    tags: DB_TAGS, aggregation: :sum,
                    comment: "Live threads in the async query thread pool"

              gauge :async_pool_queue,
                    tags: DB_TAGS, aggregation: :sum,
                    comment: "Tasks queued in the async query thread pool"

              gauge :async_pool_max_threads,
                    tags: DB_TAGS, aggregation: :sum,
                    comment: "Maximum threads the async query thread pool may run"
            end
          end
        end
      end
    end
  end
end
