# frozen_string_literal: true

module Yabeda
  module Sequel
    # Hold scopes survive temporary releases but isolate nested checkouts.
    # This mutex never takes a Sequel pool lock.
    class CheckoutTimers
      State = Struct.new(:holds, :checkouts)
      Hold = Struct.new(:owner, :checkouts)
      Checkout = Struct.new(:server, :started_at, :hold)

      def initialize
        @mutex = Mutex.new
        @pid = Process.pid
        @states = {}.compare_by_identity
      end

      def enter(owner)
        synchronize do
          hold = Hold.new(owner, {})
          state(owner).holds.push(hold)
          hold
        end
      end

      def leave(hold)
        synchronize do
          current = @states[hold.owner]
          next [] unless current && current.holds.last.equal?(hold)

          current.holds.pop
          checkouts = hold.checkouts.keys.map { |server| remove(current, server) }
          cleanup(hold.owner, current)
          checkouts
        end
      end

      def start(owner, server, started_at)
        synchronize do
          @states.delete_if { |thread, _| !thread.alive? }
          current = state(owner)
          remove(current, server)
          checkout = Checkout.new(server, started_at, current.holds.last)
          current.checkouts[server] = checkout
          checkout.hold.checkouts[server] = checkout if checkout.hold
        end
      end

      def finish(owner, server)
        synchronize do
          current = @states[owner]
          next unless current

          checkout = remove(current, server)
          cleanup(owner, current)
          checkout
        end
      end

      private

      def state(owner)
        @states[owner] ||= State.new([], {})
      end

      def remove(current, server)
        checkout = current.checkouts.delete(server)
        return unless checkout

        checkout.hold&.checkouts&.delete(server)
        checkout
      end

      def cleanup(owner, current)
        @states.delete(owner) if current.holds.empty? && current.checkouts.empty?
      end

      def synchronize
        @mutex.synchronize do
          # Forked children must never finish a parent's checkout.
          if @pid != Process.pid
            @states.clear
            @pid = Process.pid
          end
          yield
        end
      end
    end
  end
end
