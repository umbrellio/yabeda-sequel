# frozen_string_literal: true

module Yabeda
  module Sequel
    # Never takes a Sequel pool lock while holding the bookkeeping mutex.
    class CheckoutTimers
      def initialize
        @mutex = Mutex.new
        @pid = Process.pid
        @checkouts = {}.compare_by_identity
        @next_prune_at = 0
      end

      def start(owner, server, started_at)
        synchronize do
          if started_at >= @next_prune_at
            @checkouts.delete_if { |thread, _| !thread.alive? }
            @next_prune_at = started_at + Yabeda::Sequel.config.sample_interval.to_f
          end
          (@checkouts[owner] ||= {})[server] = started_at
        end
      end

      def finish(owner, server)
        synchronize do
          timers = @checkouts[owner]
          next unless timers

          started_at = timers.delete(server)
          @checkouts.delete(owner) if timers.empty?
          started_at
        end
      end

      private

      def synchronize
        @mutex.synchronize do
          # Forked children must never finish a parent's checkout.
          if @pid != Process.pid
            @checkouts.clear
            @next_prune_at = 0
            @pid = Process.pid
          end
          yield
        end
      end
    end
  end
end
