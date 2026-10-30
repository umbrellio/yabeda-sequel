# frozen_string_literal: true

require "concurrent"

module Yabeda
  module Sequel
    # Refreshes pool gauges from a background thread, once per process.
    #
    # Sampling rather than a Yabeda `collect` block is deliberate. Under a forking
    # server only the process that happens to serve /metrics runs a collect block,
    # so every other worker's gauges would sit stale — the bug yabeda-activerecord
    # tracks as issue #7. Here each process samples its own pools into its own
    # metric store file, and the exporter sums across those files at scrape time.
    class Sampler
      EXECUTOR_METHODS = %i[length queue_length max_length].freeze

      MUTEX = Mutex.new
      JOIN_TIMEOUT = 5

      class << self
        def start!
          MUTEX.synchronize do
            return false if running_unsynchronized?

            @pid = Process.pid
            @running = true
            @thread = spawn_thread
            true
          end
        end

        def stop!
          MUTEX.synchronize do
            @running = false
            thread = @thread
            @thread = nil
            @pid = nil
            shutdown(thread) if thread
          end
          nil
        end

        def running?
          MUTEX.synchronize { running_unsynchronized? }
        end

        def sample!
          ::Sequel::DATABASES.each { |db| sample_database(db) }
          nil
        end

        private

        # Fork safety comes from the pid check: an inherited @pid never matches
        # the child's, so a forked worker always spawns its own thread instead of
        # trusting one that did not survive the fork.
        def running_unsynchronized?
          @running == true && @pid == Process.pid && @thread&.alive? == true
        end

        # The loop must never take MUTEX — stop! holds it while joining.
        def spawn_thread
          Thread.new do
            Thread.current.name = "yabeda-sequel-sampler"

            while @running
              sleep(Yabeda::Sequel.config.sample_interval.to_f)
              break unless @running

              begin
                sample!
              rescue StandardError => error
                handle_error(error)
              end
            end
          end
        end

        # Cooperative: wake the thread so it observes @running == false and
        # finishes its current iteration, rather than killing it mid-sample and
        # risking a half-released lock at fork time.
        def shutdown(thread)
          thread.wakeup if thread.alive?
          thread.join(JOIN_TIMEOUT) || thread.kill
        rescue ThreadError
          nil
        end

        def handle_error(error)
          Yabeda::Sequel.config.error_handler.call(error)
        rescue StandardError
          nil
        end

        def sample_database(db)
          pool = db.pool
          return unless PoolReader.supported?(pool)

          pool.yabeda_sequel_flush_busy_time if pool.respond_to?(:yabeda_sequel_flush_busy_time)
          reader = PoolReader.new(pool)
          db_tag = Naming.call(db)

          Yabeda.sequel.connection_pool_processes.set({ db: db_tag }, 1)
          reader.servers.each { |server| sample_server(reader, db_tag, server) }
          sample_async_pool(db, db_tag)
        end

        def sample_server(reader, db_tag, server)
          tags = { db: db_tag, server: server.to_s }

          Yabeda.sequel.connection_pool_connections.set(tags, reader.connections(server))
          Yabeda.sequel.connection_pool_size.set(tags, reader.max_size)

          waiting = reader.waiting(server)
          Yabeda.sequel.connection_pool_waiting.set(tags, waiting) unless waiting.nil?
        end

        def sample_async_pool(db, db_tag)
          return unless db.respond_to?(:async_thread_executor)

          executor = db.async_thread_executor
          return unless EXECUTOR_METHODS.all? { |method| executor.respond_to?(method) }

          tags = { db: db_tag }
          Yabeda.sequel.async_pool_threads.set(tags, executor.length)
          Yabeda.sequel.async_pool_queue.set(tags, executor.queue_length)
          Yabeda.sequel.async_pool_max_threads.set(tags, executor.max_length)
        end
      end
    end
  end
end
