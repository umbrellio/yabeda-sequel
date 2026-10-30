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
        @completed = {}
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

      def finish(owner, server, finished_at: nil)
        synchronize do
          timers = @checkouts[owner]
          next unless timers

          started_at = timers.delete(server)
          if started_at && finished_at
            @completed[server] = @completed.fetch(server, 0) + (finished_at - started_at)
          end
          @checkouts.delete(owner) if timers.empty?
          started_at
        end
      end

      def drain
        synchronize do
          completed = @completed
          @completed = {}
          completed
        end
      end

      private

      def synchronize
        @mutex.synchronize do
          # Forked children must never finish a parent's checkout.
          if @pid != Process.pid
            @checkouts.clear
            @completed.clear
            @next_prune_at = 0
            @pid = Process.pid
          end
          yield
        end
      end
    end
  end
end
