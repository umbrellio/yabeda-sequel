# frozen_string_literal: true

module Yabeda
  module Sequel
    # Sequel's private acquire/release signatures are pinned by the specs.
    # Nested holds bypass them, so only genuine checkouts start timers.
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
          pool.instance_variable_set(:@yabeda_sequel_timers, CheckoutTimers.new)
          pool.singleton_class.prepend(self)
          nil
        end
      end

      def hold(*)
        return super unless Yabeda.configured?

        hold = @yabeda_sequel_timers.enter(::Sequel.current)
        super
      ensure
        # Disconnect paths can delete allocations without calling release.
        if hold
          @yabeda_sequel_timers.leave(hold).each { |timer| yabeda_sequel_measure_busy(timer) }
        end
      end

      private

      def acquire(*args)
        return super unless Yabeda.configured?

        # Sharded pools pass the server second; unsharded ones take no server.
        tags = yabeda_sequel_tags(args[1])
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        begin
          connection = super
          acquired_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @yabeda_sequel_timers.start(args[0], args[1], acquired_at)
          connection
        rescue ::Sequel::PoolTimeout
          Yabeda::Sequel.safely do
            Yabeda.sequel.connection_pool_timeouts_total.increment(tags)
          end
          raise
        ensure
          elapsed = (acquired_at || Process.clock_gettime(Process::CLOCK_MONOTONIC)) - started_at
          Yabeda::Sequel.safely { Yabeda.sequel.connection_pool_wait.measure(tags, elapsed) }
        end
      end

      def release(*args)
        checkout = @yabeda_sequel_timers.finish(args[0], args[2])
        released_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) if checkout
        super
      ensure
        yabeda_sequel_measure_busy(checkout, released_at)
      end

      def yabeda_sequel_measure_busy(checkout, finished_at = nil)
        return unless checkout && Yabeda.configured?

        finished_at ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
        elapsed = finished_at - checkout.started_at
        Yabeda::Sequel.safely do
          Yabeda.sequel.connection_pool_busy_seconds_total.increment(
            yabeda_sequel_tags(checkout.server), by: elapsed
          )
        end
      end

      def yabeda_sequel_tags(server)
        { db: @yabeda_sequel_db, server: (server || :default).to_s }
      end
    end
  end
end
