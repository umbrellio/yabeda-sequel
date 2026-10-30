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
          pool.instance_variable_set(:@yabeda_sequel_defer_busy_metrics,
                                     %i[threaded sharded_threaded].include?(pool.pool_type))
          pool.singleton_class.prepend(self)
          nil
        end
      end

      # Legacy pools call release under their mutex; the sampler writes outside it.
      def yabeda_sequel_flush_busy_time
        return unless Yabeda.configured?

        @yabeda_sequel_timers.drain.each do |server, elapsed|
          yabeda_sequel_measure_busy(server, elapsed)
        end
        nil
      end

      private

      def acquire(*args)
        unless Yabeda.configured?
          @yabeda_sequel_timers.finish(args[0], args[1])
          return super
        end

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
        released_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        deferred_at = released_at if @yabeda_sequel_defer_busy_metrics && Yabeda.configured?
        started_at = @yabeda_sequel_timers.finish(args[0], args[2], finished_at: deferred_at)
        super
      ensure
        if started_at && !@yabeda_sequel_defer_busy_metrics
          yabeda_sequel_measure_busy(args[2], released_at - started_at)
        end
      end

      def yabeda_sequel_measure_busy(server, elapsed)
        return unless Yabeda.configured?

        Yabeda::Sequel.safely do
          Yabeda.sequel.connection_pool_busy_seconds_total.increment(
            yabeda_sequel_tags(server), by: elapsed
          )
        end
      end

      def yabeda_sequel_tags(server)
        { db: @yabeda_sequel_db, server: (server || :default).to_s }
      end
    end
  end
end
