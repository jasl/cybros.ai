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
          guarded, queued = released.partition do |input|
            input.expected_steering_run_public_id && (input.on_target_end != "queue" ||
              input.conversation_link&.closed? ||
              Runs::SourceWork.stopped?(input.cancellation_source_public_id, Run.find_by(public_id: input.sender_run_public_id)))
          end
          guarded.each { |input| Destroy.remove(input) }
          return released.length if queued.empty?

          # One set write over exactly the rows loaded (`update_all` skips
          # `updated_at` and the optimistic `lock_version` a save would bump,
          # so both are spelled — the row changed, and the edit door's
          # `expected_lock_version` CAS must see that); the narration reads
          # only the loaded rows' `public_id` and `queue_position`, untouched.
          explicit, ordinary = queued.partition(&:expected_steering_run_public_id)
          changes = { state: "pending", steering_target_turn_id: nil,
            updated_at: Time.current, lock_version: Arel.sql("lock_version + 1") }
          inputs.where(id: ordinary.map(&:id)).update_all(changes) if ordinary.any?
          if explicit.any?
            inputs.where(id: explicit.map(&:id)).update_all(changes.merge(
              delivery_mode: "queue", fallback_reason: "steer_target_settled"))
          end
          narrate(host, queued)
          released.length
        end

        private

          def narrate(host, released)
            Event::Append.call(
              host: host,
              items: released.map do |input|
                {
                  type: "input_edited",
                  payload: {
                    "input_public_id" => input.public_id,
                    "queue_position" => input.queue_position,
                    "state" => "pending",
                    "reason" => "steer_target_settled",
                    "delivery_mode" => input.expected_steering_run_public_id ? "queue" : input.delivery_mode,
                    "requested_delivery_mode" => input.requested_delivery_mode,
                    "expected_steering_run_public_id" => input.expected_steering_run_public_id,
                  },
                }
              end
            )
          end
      end
    end
  end
end
