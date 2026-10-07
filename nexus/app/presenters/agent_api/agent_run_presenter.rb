module AgentAPI
  # The task-grained public projection: keys, kinds, public statuses, what a
  # task was authored after and still waits for, policies and correlations. Join
  # mechanics draw on the graph route; mainline mark, counters, ids never render.
  module AgentRunPresenter
    class << self
      def public_status(...) = AgentRuns::TaskProjection.public_status(...)

      def full(agent_run)
        nodes = agent_run.agent_run_tasks.includes(:sources, :addressed_executor, :target_executor, :approved_by_user)
          .order(:created_at, :id).to_a
        # The live server set, loaded ONCE for the page and threaded to every
        # row's addressee: never a query per task.
        build(agent_run, nodes: nodes, live_server_ids: NexusServer.live_ids)
      end

      # The loop document, pure over the loop row (or a double shaped like
      # it) and its loaded nodes, so the contract pack renders the same
      # projection the route serves — the phases presenter's `build`.
      def build(agent_run, nodes:, live_server_ids:)
        {
          public_id: agent_run.public_id,
          status: agent_run.status,
          approval_mode: agent_run.approval_mode,
          details_pruned_at: agent_run.details_pruned_at,
          failure_reason: agent_run.failure_reason,
          turn: turn(agent_run, nodes: nodes),
          deliverable_task_key: deliverable_key(agent_run, nodes),
          tasks: nodes.map { |node| task(node, live_server_ids: live_server_ids) },
          task_progress: progress(nodes),
          started_at: agent_run.started_at,
          paused_at: agent_run.paused_at,
          completed_at: agent_run.completed_at,
          attention: AgentRuns::Transition.attention_projection(agent_run, nodes: nodes),
          input_queue: input_queue(agent_run),
          # THE BINDING IS READABLE: a loop-backed loop shows its
          # conversation's; nil when unbound or reaped. Not on `basic`.
          runner_effects: AgentRuns::RunnerEffects.from_tasks(nodes, run_public_id: agent_run.public_id, details_pruned_at: agent_run.details_pruned_at),
          created_at: agent_run.created_at,
          updated_at: agent_run.updated_at,
        }.compact.merge(
          # THE EFFECTIVE MECHANISM WORD: `default` or `raw` on a
          # loop-backed turn; null on a standalone loop and the kernel's
          # summary loop. Kept null, never dropped — a reader asks for it.
          prompt_mechanism: agent_run.prompt_mechanism,
          default_runner: ExecutorPresenter.binding(agent_run.default_runner, live_server_ids: live_server_ids)
        )
      end

      # The index shape carries no tasks, so the attention rollup rides here:
      # "which of my loops needs me" has nothing else to read.
      def basic_many(agent_runs)
        backed = agent_runs.reject(&:standalone?)
        ActiveRecord::Associations::Preloader.new(records: backed,
          associations: [:conversation_turn_variant, { conversation_turn: [:conversation, :answering_user] }]).call
        models = AgentRuns::CurrentModel.for_loops(backed)
        agent_runs.map do |agent_run|
          basic(agent_run, model: models[agent_run.id] || agent_run.conversation_turn_variant)
        end
      end

      def basic(agent_run, model: nil)
        {
          public_id: agent_run.public_id,
          status: agent_run.status,
          details_pruned_at: agent_run.details_pruned_at,
          failure_reason: agent_run.failure_reason,
          turn: turn(agent_run, model: model),
          attention: attention_projection(agent_run),
          created_at: agent_run.created_at,
        }.compact
      end

      # The one-row settlement renders take the defaulted set — one query for
      # one row; the trace above loads it once for all.
      def task(node, live_server_ids: NexusServer.live_ids)
        {
          key: node.node_key,
          kind: node.task_kind,
          lifetime: node.lifetime,
          wake: node.wake,
          status: public_status(node.status),
          after: after(node),
          waiting_on: waiting_on(node),
          on_failure: node.on_failure,
          failure_resolution: node.failure_resolution,
          retry: node.retry_budget.positive? ? { budget: node.retry_budget } : nil,
          model: model_projection(node),
          tool_name: node.tool_name,
          # The spelling the model called a kernel tool under, beside the
          # kernel's wire name; absent unless the call was aliased.
          tool_alias: node.tool_alias,
          target: target(node),
          # Who a started call is for and who holds it: the role and the
          # address — the role alone for a pool row — and the claimant's
          # public-id snapshot; never the effect profile.
          addressed_to: addressed_to(node, live_server_ids),
          claimed_by: claimed_by(node),
          # The approval fact: who or what let the call past the stage, and
          # when; absent until a decision.
          approval: approval_projection(node),
          # The resolution token is a BEARER capability and travels only
          # in the creator's append receipt — the trace is readable by
          # browse-only principals and never carries it.
          result: node.output_summary.presence,
          error: error_projection(node),
          visibility: node.transcript_visibility,
          created_at: node.created_at,
          started_at: node.started_at,
          completed_at: node.completed_at,
          # A background answer that outlived its turn, and when the kernel
          # mailed it — absent on everything else.
          result_delivered_at: node.result_delivered_at,
        }.compact
      end

      def target(...) = AgentRuns::TaskProjection.target(...)

      def approval_projection(...) = AgentRuns::TaskProjection.approval_projection(...)

      # The one projection in this plane that loads a body: `output` is the
      # text, `content`/`structured_content` what the grammar stored. The entries
      # are read once and passed down — a memo on this module is process-wide.
      def task_detail(node, live_server_ids: NexusServer.live_ids)
        bodies = node.content_bodies.where(role: %w[output input]).index_by(&:role)
        body = bodies["output"]
        detail(node, output: body&.effective_text, payloads: AgentRuns::TaskResultProjection.entry_payloads(body),
          prompt: bodies["input"]&.effective_text, live_server_ids: live_server_ids,
          declaring_task_key: (AgentRuns::KernelTool.round_of(node)&.node_key if node.tool_call?))
      end

      # The single-task read, pure over the node (or a double) and its two
      # bodies' facts — the output text, the output's stored entry payloads,
      # the authored prompt — so the contract pack renders it over fixtures.
      def detail(node, output:, payloads:, prompt:, live_server_ids:, declaring_task_key: nil)
        result = task(node, live_server_ids: live_server_ids).merge({
          declaring_task_key: declaring_task_key,
          output: output,
          # The bounded preview the settled-call frame carries, so a reader
          # that attached after the call settled renders what a live
          # follower rendered.
          output_preview: node.output_preview,
          content: AgentRuns::TaskResultProjection.content_blocks(payloads),
          # The UI's two fields: the one-line header and the
          # model-invisible carrier the executor sent at commit, served on
          # this read alone and only when present — `metadata.checkpoint`
          # is reserved. Never rendered to a model.
          title: node.result_title,
          metadata: node.result_metadata,
          # The authored side of any task that has one — an ask's question, a
          # client-appended round's prompt; a spliced continuation has none.
          prompt: prompt,
          # An ask's choices as data: present only when the asker gave
          # them; the inbox row serves the same two.
          options: node.ask_options,
          multi: node.ask_multi,
          # The system field a `raw` round was authored with: what the SDK
          # wrote, read back on this read alone; absent on a round
          # authored without one and on every other kind.
          instructions: node.system_instructions.presence,
          # The round's frozen declarations retain alias resolution facts.
          # Provider requests may omit a skill or carry silenced historical
          # tools, so their wire list cannot establish what a round may call.
          # An empty set is explicit; other task kinds carry no declaration.
          tool_definitions: (node.tool_definitions || [] if node.model_task?),
          # The arguments ride on the single-task read, which already serves the
          # tool's output; the trace omits them. Not `.presence` — an
          # argument-less call reads `{}`, as the runner's inbox row serves it.
          tool_input: (node.tool_input if node.tool_call?),
          wait: (node.observing_task? ? {
            run_public_id: node.awaited_run_public_id,
            task: node.awaited_task_key, timeout_ms: node.await_timeout_ms,
          } : nil),
          # The bytes a round's request was sealed with: the body's
          # stored size, a column read; absent on every other kind and on
          # a round never scheduled.
          request_bytes: node.sealed_request_bytes,
        }.compact)
        if AgentRuns::TaskResultProjection.structured_content_present?(payloads)
          result[:structured_content] = AgentRuns::TaskResultProjection.structured_content(payloads)
        end
        result
      end

      private

        # The addressee's presence and contact sample ride beside its id
        # from the row the trace preloads — display for the person watching
        # a call wait; the pool row names a role alone, and the claimant
        # below stays a public-id snapshot.
        def addressed_to(node, live_server_ids)
          return if node.addressed_role.nil?

          executor = node.addressed_executor
          {
            role: node.addressed_role,
            executor_public_id: executor&.public_id,
            presence: (Nexus::Presence.of(executor, live_server_ids: live_server_ids) if executor),
            last_seen_at: executor&.last_seen_at,
          }.compact
        end

        def claimed_by(node)
          public_id = node.claimed_by_executor_public_id
          { executor_public_id: public_id } if public_id
        end

        # The turn shape, beside the loop's own row: a loop-backed loop
        # renders its TURN row through the seam — the reason only while the
        # seam's variant is still the active one, else a person overrode it —
        # and a standalone loop renders the function over its own rows.
        # `model` is the current main-line selection, including a local
        # retry's model change, so a follower of the loop (rho's `say`
        # on a conversation it only attached) reads the model in use here and
        # a missing one is never a transmission failure. The loop's own model
        # shape, `{model, reasoning_effort, reasoning_enabled}`.
        def turn(agent_run, nodes: nil, model: nil)
          shape = agent_run.turn_shape
          if agent_run.standalone?
            { status: shape.status, failure_reason_key: shape.failure_reason_key }.compact
          else
            turn = agent_run.conversation_turn
            seam_active = turn.active_variant_id == agent_run.conversation_turn_variant_id
            {
              status: turn.status,
              failure_reason_key: (shape.failure_reason_key if seam_active),
              public_id: turn.public_id,
              conversation_public_id: turn.conversation.public_id,
              answering_user_public_id: turn.answering_user.public_id,
              model: model_projection(model || AgentRuns::CurrentModel.for(agent_run, nodes: nodes)),
            }.compact
          end
        end

        # A standalone loop hosts its own waiting room; a loop-backed loop's
        # is its conversation's, read there.
        def input_queue(agent_run)
          return nil unless agent_run.standalone?

          {
            limit: agent_run.input_queue_limit,
            held: agent_run.conversation_inputs.caller_authored.count,
          }
        end

        # No expires_at — an ask has no clock. Rendered whenever a reason stands, not
        # only when the status holds: the announce split stamps one on a running loop
        # too. Which task needs the person is the task's own status.
        def attention_projection(agent_run)
          return nil if agent_run.attention_reason.blank?

          { reason: agent_run.attention_reason }
        end

        def error_projection(node)
          return nil if node.error_key.blank?

          { key: node.error_key, detail: node.error_detail }.compact
        end

        def deliverable_key(agent_run, nodes)
          return nil if agent_run.deliverable_node_id.nil?

          nodes.find { |node| node.id == agent_run.deliverable_node_id }&.node_key
        end

        # Authored, at every status; a root reads none.
        def after(node) = node.sources.map(&:node_key).presence

        # Live, and answered only while the task has spent nothing: once
        # started its status says what it waits on, and once settled a racing
        # join's still-running sources would contradict the status.
        def waiting_on(node)
          return nil unless AgentRunTask::PRE_DISPATCH_STATUSES.include?(node.status)

          node.sources.reject(&:terminal?).map(&:node_key).presence
        end

        # One shape for a task's current selection and a turn's.
        def model_projection(selection)
          return nil if selection.provider_id.blank?

          {
            model: "#{selection.provider_id}/#{selection.model_ref}",
            reasoning_effort: selection.reasoning_effort, reasoning_enabled: selection.reasoning_enabled,
          }.compact
        end

        # One bucket per status, derived from the vocabulary so the next park
        # word arrives with its count already.
        def progress(nodes)
          counts = nodes.group_by(&:status).transform_values(&:length)
          AgentRunTask::STATUSES
            .to_h { |status| [public_status(status).to_sym, counts.fetch(status, 0)] }
            .merge(total: nodes.length)
        end
    end
  end
end
