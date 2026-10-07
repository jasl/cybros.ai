module Conversations
  module Inputs
    # Destroying a steering row is the steer-cancel verb; destroying a
    # blocked head is the give-up path. Either way the queue moves. A
    # kernel-origin row cannot be given up here: the one way to "delete"
    # a result is to cancel its task before it lands. A peer's `send` is
    # a principal's word and can be.
    class Destroy
      Command = Data.define(:host, :input_public_id, :acting_user)

      class << self
        def call(command)
          new(command).call
        end

        # Kernel cleanup uses the same deletion and narration after its source
        # execution has already been canceled. Caller holds the input or its
        # guarded target loop, which also serializes the public delete door.
        def remove(input)
          public_id, queue_position, was_steering = input.public_id, input.queue_position, input.steering?
          input.destroy!
          ConversationEvent::Append.call(
            host: input.host,
            items: [{ type: "input_deleted", payload: {
              "input_public_id" => public_id, "queue_position" => queue_position,
              "steer_canceled" => was_steering,
            } }]
          )
          Outcome.accepted(input)
        end
      end

      def initialize(command)
        @command = command
        @host = command.host
      end

      def call
        unless @host.writable_by?(@command.acting_user)
          return Outcome.refused(:not_authorized)
        end

        result = @host.with_lock { locked_destroy }
        @host.wake_drain if result.accepted?
        result
      end

      private

        def locked_destroy
          refusal = @host.input_refusal
          return Outcome.refused(refusal) if refusal

          input = @host.conversation_inputs.find_by(public_id: @command.input_public_id)
          return Outcome.refused(:not_found) if input.nil?
          return Outcome.refused(:kernel_input_immutable) if input.kernel_origin?

          # Terminal cleanup already owns this immutable target, potentially
          # below task/body locks. Share its loop lock before the input lock so
          # either deletion wins without asking cleanup to climb the ladder.
          if input.expected_steering_run_public_id
            AgentRun.lock.find_by!(public_id: input.expected_steering_run_public_id)
          end

          # A delegated input must leave a result before its only queue row
          # disappears. The source loop precedes the input on the lock ladder.
          AgentRuns::Delegations.with_owner(input) do |delegation|
            # A steering consumer owns its loop, not this host, and may have
            # consumed the row since discovery. A missing locked row is the
            # ordinary delete race, with the same not-found answer as above.
            input = @host.conversation_inputs.lock.find_by(id: input.id)
            next Outcome.refused(:not_found) unless input

            if delegation
              AgentRuns::Delegations::Settlement.call(node: delegation, call: @host.spawn_node,
                text: "The delegated input was removed before execution.", status: "failed",
                error_key: "delegation_abandoned", child: @host)
            end
            self.class.remove(input)
          end
        end
    end
  end
end
