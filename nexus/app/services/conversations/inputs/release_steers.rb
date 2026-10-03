module Conversations
  module Inputs
    # Owed at every terminal of what a steer was bound to — a reply's invocation, or
    # a loop's own status: the binding ends with its target, and the words fall back
    # to the queue unless the caller pinned one execution. A pinned correction
    # is canceled when its execution ends without consuming it.
    # One body for both hosts; it releases the rows it is handed and narrates on the
    # host it is handed.
    class ReleaseSteers
      class << self
        def call(host:, inputs:)
          # Guarded cancellation shares the target loop lock with this cleanup.
          # A terminal transition may already hold task/body locks below inputs.
          released = inputs.steering.reorder(:queue_position, :id).to_a
          return 0 if released.empty?

          # A guarded correction belongs only to its original execution. Reuse
          # steer cancellation when that execution ends before consuming it.
          guarded, queued = released.partition(&:expected_steering_loop_public_id)
          guarded.each { |input| Destroy.remove(input) }
          return released.length if queued.empty?

          # One set write over exactly the rows loaded (`update_all` skips
          # `updated_at` and the optimistic `lock_version` a save would bump,
          # so both are spelled — the row changed, and the edit door's
          # `expected_lock_version` CAS must see that); the narration reads
          # only the loaded rows' `public_id` and `queue_position`, untouched.
          inputs.where(id: queued.map(&:id)).update_all(
            state: "pending", steering_target_turn_id: nil,
            updated_at: Time.current, lock_version: Arel.sql("lock_version + 1")
          )
          narrate(host, queued)
          released.length
        end

        private

          def narrate(host, released)
            ConversationEvent::Append.call(
              host: host,
              items: released.map do |input|
                {
                  type: "input_edited",
                  payload: {
                    "input_public_id" => input.public_id,
                    "queue_position" => input.queue_position,
                    "state" => "pending",
                    "reason" => "steer_target_settled",
                  },
                }
              end
            )
          end
      end
    end
  end
end
