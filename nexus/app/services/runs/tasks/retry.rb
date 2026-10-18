module Runs
  module Tasks
    # The verb the halt policy exists for: an unresolved failed task
    # re-queues under a fresh generation, so a late stale result applies to
    # nothing, and the loop returns to running. An `uncertain` call re-runs
    # under a new generation only because a PERSON decided its effect did
    # not happen — the kernel never decides that.
    class Retry
      ADJUDICABLE_LOOP_STATUSES = Run::ADJUDICABLE_STATUSES

      Command = Data.define(:run, :task_key, :acting_user, :model) do
        def initialize(model: nil, **) = super
      end

      Result = Data.define(:outcome, :node) do
        class << self
          def accepted(node) = new(outcome: :accepted, node: node)
          def refused(code) = new(outcome: code, node: nil)
        end

        def accepted? = outcome == :accepted
      end

      class << self
        def call(command)
          new(command).call
        end
      end

      def initialize(command)
        @command = command
      end

      def call
        unless @command.run.writable_by?(@command.acting_user)
          return Result.refused(:not_authorized)
        end

        run = @command.run
        # The seam's veto, lock-free first: a loop behind a person's edit
        # takes no lock for a verb it will refuse.
        return Result.refused(:not_adjudicable) if run.overridden?

        result, resumed = run.with_lock { adjudicate(run) }
        ScheduleJob.perform_later(@command.run.id) if resumed
        result
      end

      private

        def adjudicate(run)
          if run.tombstoned?
            return [Result.refused(:not_found), false]
          end
          unless ADJUDICABLE_LOOP_STATUSES.include?(run.status) && !run.overridden?
            return [Result.refused(:not_adjudicable), false]
          end

          node = run.tasks.find_by(node_key: @command.task_key)
          return [Result.refused(:task_not_found), false] if node.nil?
          # A join has no execution to re-run: its failure is structural and
          # only abandon or an appended repair answers it.
          if node.join_mode.present? || node.task_kind == "delegation_task"
            return [Result.refused(:not_retryable), false]
          end
          if run.delivered? && node.lifetime == "turn"
            return [Result.refused(:turn_already_delivered), false]
          end
          # Unresolved by a person AND by its effective policy. An ordinary
          # absorb failure settles when written, so nothing re-runs it.
          return [Result.refused(:not_retryable), false] unless node.unresolved_failure?

          selection, refusal = replacement_selection(run, node)
          return [Result.refused(refusal), false] if refusal
          model_attributes = selection ? {
            provider_id: selection.provider_id, model_ref: selection.model_ref,
            reasoning_effort: selection.reasoning.effort,
            reasoning_enabled: selection.reasoning.enabled,
          } : {}

          # Its sources were satisfied once and a grown graph never changes,
          # so the countdown restarts at 0. The previous run's answer goes
          # with its error. A model route's consumed allowance stays in its invocation history.
          node.content_bodies.where(role: "output").destroy_all
          Transition.node(
            node,
            status: "queued",
            execution_generation: node.execution_generation + 1,
            committed_result_digest: nil,
            remaining_dependencies: 0,
            error_key: nil, error_detail: nil,
            started_at: nil, completed_at: nil,
            # The transcript reads these columns, not the body, so they go
            # with the answer or a re-run renders the previous result — the
            # summary included, or a queued re-run reads the last run's
            # `refused`.
            output_preview: nil, output_size_bytes: nil, output_summary: {},
            result_title: nil, result_metadata: nil,
            # And the claim: a dead attempt's token would make the re-armed
            # park un-takeable by anyone else. The address goes with it —
            # the next start re-addresses the new generation to the immutable
            # target. The first Runner write survives with its checkpoint.
            claim_token: nil, claimed_at: nil, external_started_at: nil,
            claimed_by_executor_id: nil, claimed_by_executor_public_id: nil,
            addressed_executor_id: nil, addressed_role: nil, effect_profile: nil,
            # And the approval fact: a grant was this generation's; the next
            # crosses the stage again and is decided anew.
            approval_origin: nil, approved_by_user_id: nil, approval_decided_at: nil,
            **model_attributes
          )
          [Result.accepted(node), release_hold(run)]
        end

        # An explicit model change retries this task alone. Its existing
        # tools/options/approval remain authoritative, and a person's retry
        # renews no automatic switch: not the mail loop's allowance, and not
        # a declined step's once-only re-run, which its own history bounds.
        def replacement_selection(run, node)
          return [nil, nil] if @command.model.nil?
          return [nil, :model_not_applicable] unless node.model_task?

          fields = @command.model.to_h.stringify_keys
          current_model = "#{node.provider_id}/#{node.model_ref}"
          model = fields.fetch("model", current_model).to_s
          refusal = ModelSelection::Recovery.constraint_refusal(run.account, node.model_selection, model)
          return [nil, refusal] if refusal
          return [nil, :model_route_spent] if ModelFallback.spent_route?(node, model)

          inherited = model == current_model
          effort = fields["reasoning_effort"].presence || (node.reasoning_effort if inherited)
          enabled = ActiveModel::Type::Boolean.new.cast(fields["reasoning_enabled"])
          enabled = node.reasoning_enabled if enabled.nil? && inherited
          result = ModelSelection.resolve(
            account: run.account, workload: node.workload,
            submitted: Nexus::SubmittedModelSelection.new(
              model: model,
              reasoning_effort: effort&.to_s, reasoning_enabled: enabled
            ),
            configuration: InferenceRequests::CoerceConfiguration.call(node.request_options),
            port: ModelSelection::Resolver.new
          )
          result.resolved? ? [result.selection, nil] : [nil, result.refusal]
        end

        def release_hold(run)
          if run.needs_attention?
            Transition.run(
              run,
              status: "running",
              attention_reason: nil
            )
          end
          run.running?
        end
    end
  end
end
