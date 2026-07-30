# frozen_string_literal: true

module Yabeda
  module Sequel
    # Times connection checkouts.
    #
    # Wait time is inherently per-checkout and cannot be sampled, so this is the
    # one place the gem touches Sequel internals: `acquire` is private API. It has
    # the same shape on every pool implementation — `acquire(thread)` when
    # unsharded, `acquire(thread, server)` when sharded — so splatted args plus a
    # bare `super` covers all of them. The specs pin this behaviour so that a
    # Sequel release changing `acquire` fails CI rather than silently flatlining
    # the metric.
    #
    # Nested checkouts are not double counted: `hold` returns early via
    # `owned_connection` when the calling thread already holds a connection, so
    # `acquire` is only reached for genuine acquisitions.
    module PoolInstrumentation
      class << self
        def installed?(db)
          pool = db.pool
          pool.respond_to?(:singleton_class) && pool.singleton_class.ancestors.include?(self)
        end

        def install!(db)
          pool = db.pool
          return unless PoolReader.supported?(pool)
          return if pool.frozen?
          return if installed?(db)

          pool.instance_variable_set(:@yabeda_sequel_db, Naming.call(db))
          pool.singleton_class.prepend(self)
          nil
        end
      end

      def acquire(*args)
        return super unless Yabeda.configured?

        # Sharded pools pass the server second; unsharded ones take no server.
        tags = yabeda_sequel_tags(args[1])
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        begin
          super
        rescue ::Sequel::PoolTimeout
          Yabeda::Sequel.safely do
            Yabeda.sequel.connection_pool_timeouts_total.increment(tags)
          end
          raise
        ensure
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
          Yabeda::Sequel.safely { Yabeda.sequel.connection_pool_wait.measure(tags, elapsed) }
        end
      end

      private

      def yabeda_sequel_tags(server)
        { db: @yabeda_sequel_db, server: (server || :default).to_s }
      end
    end
  end
end
