require_relative "../until"
require_relative "../host_policy"

module Rho
  module Until
    # Reads durable policy and the original execution directly. Follower state
    # is neither an input nor a prerequisite for advancing an accepted goal.
    class Recovery
      def initialize(owner_public_id:, timeout_seconds:, log: nil, sleeper: ->(seconds) { sleep(seconds) })
        @owner_public_id, @timeout_seconds, @log, @sleeper = owner_public_id, timeout_seconds, log, sleeper
      end

      def call(workspace:, run_public_id:, conversation_public_id:, turn_public_id: nil, advance: true)
        hosted = workspace.conversation(conversation_public_id)
        document = HostPolicy.new(store: -> { hosted.store_entries }, owner_public_id: @owner_public_id,
          host_public_id: conversation_public_id)
        snapshot = document.read
        return unless snapshot && snapshot.owner_public_id == @owner_public_id && snapshot.host_public_id == conversation_public_id

        note = snapshot.notes["rho.until"]
        return unless note
        bound = note.fetch("run_public_id")
        return if bound && bound != run_public_id

        context = workspace.run(run_public_id)
        policy = Policy.from_h(note)
        unless bound
          run = context.fetch
          unless run.public_id == run_public_id && original?(hosted, context, run, policy, turn_public_id: turn_public_id)
            @log&.warn("until.not_restored", run: run_public_id, reason: "pending_run_unproven")
            return
          end

          begin
            snapshot = document.change(notes: snapshot.notes.merge("rho.until" => note.merge("run_public_id" => run_public_id)))
            return unless snapshot.notes.fetch("rho.until").fetch("run_public_id") == run_public_id
          rescue CybrosAgent::Api::Conflict => error
            # Archived stores are read-only. The immutable original materialization
            # and accepted check remain the proof; every recovery rechecks them.
            raise unless error.code == "conversation_archived"
          end
        end
        gate = Gate.new(policy: policy, run_public_id: run_public_id, timeout_seconds: @timeout_seconds,
          log: @log, sleeper: @sleeper)
        gate.reconsider(context) if advance
        gate
      end

      private

        def original?(hosted, context, run, policy, turn_public_id:)
          turn_id = turn_public_id || run.turn&.public_id
          return false unless run.turn&.conversation_public_id == hosted.public_id && turn_id == run.turn.public_id

          turn = hosted.turns.fetch(turn_id, include_hidden: true)
          return false unless turn.input_public_id && turn.position == 0

          original = hosted.inputs.materialization(turn.input_public_id, include_hidden: true)
          return false unless original.run_public_id == run.public_id && original.turn_public_id == turn_id
          return false unless run.tasks.any? { |task| task.key == Until.hold_key(1) && task.await? }
          return false unless run.tasks.any? { |task| task.key == Until.check_key(1) && task.tool_call? }

          check = context.task(Until.check_key(1))
          check.task.tool_name == "bash" && check.tool_input&.fetch("command", nil) == policy.command &&
            check.tool_input&.fetch("workdir", nil) == policy.directory &&
            check.task.target&.executor_public_id == policy.runner &&
            check.executor_context == policy.seed.fetch("executor_contexts", {})[policy.runner]
        end
    end
  end
end
