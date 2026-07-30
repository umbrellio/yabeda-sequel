# frozen_string_literal: true

module Yabeda
  module Sequel
    # Sequel ships six connection pool implementations that expose different
    # subsets of the same information. This normalizes them so the sampler doesn't
    # care which one it was handed.
    #
    # Ruby 3.2+ defaults to the timed_queue pair; the threaded pair is legacy, and
    # its `allocated` / `available_connections` readers are marked for removal in
    # Sequel 6 — which is why this gem exposes no busy/idle counts at all.
    class PoolReader
      class << self
        # A capability check rather than a type allowlist, so an unfamiliar pool
        # class degrades to being skipped instead of raising.
        def supported?(pool)
          %i[max_size size servers pool_type].all? { |method| pool.respond_to?(method) }
        end
      end

      attr_reader :pool

      def initialize(pool)
        @pool = pool
        # Only some pools track size per server. Arity is the honest test: the
        # sharded_single pool lists several servers but keeps one pool-wide size,
        # so trusting `pool.servers` alone would report its total once per server.
        @per_server = pool.method(:size).arity != 0
      end

      def servers
        per_server? ? pool.servers : [:default]
      end

      def max_size
        pool.max_size
      end

      def connections(server)
        per_server? ? pool.size(server) : pool.size
      end

      # Only the timed_queue pools expose a waiter count.
      def waiting(server)
        return nil unless pool.respond_to?(:num_waiting)

        pool.num_waiting(server)
      end

      private

      def per_server?
        @per_server
      end
    end
  end
end
