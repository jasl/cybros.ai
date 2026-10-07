module Conversations
  module Sides
    # A side dies whole: its reply in flight stopped by the kernel's own
    # act, the row tombstoned, and the physical reap tried at once — a
    # side has no children, so leaves-first holds by construction. A
    # settlement fence (an attempt still pending after the cancel) leaves
    # the tombstone standing for the sweep, whose candidates carry a
    # tombstoned side at any age. Callers hold the verb's lock: the side's
    # own for DELETE, the parent's for the cascade; the side's row lock is
    # taken under it (parent → side, the fork's own order).
    class Discard
      def self.call(side) = new(side).call

      def initialize(side)
        @side = side
      end

      def call
        stopped = @side.with_lock do
          next false if @side.tombstoned?

          cancel = Turns::Cancel.stop_now(@side)
          @side.touch(:tombstoned_at)
          Reap.reap_now(@side.id)
          cancel.accepted?
        end
        Turns::ConvergeJob.perform_later if stopped
        stopped
      end
    end
  end
end
