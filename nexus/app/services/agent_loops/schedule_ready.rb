module AgentLoops
  # Under the loop lock every queued countdown-zero node starts; the
  # admission plane stays the only capacity authority, and the tail is the
  # one quiescence site. Level-triggered, so any wake and the sweep floor are safe.
  class ScheduleReady
    # The two size walls, the composer's storage bound and the model's
    # window, arm the same repair. Only an exact count may fail a round; an
    # estimate still arms, since only the OpenAI family counts exactly.
    SIZE_REFUSALS = [
      InputComposition::CONTEXT_OVERFLOW, :estimated_input_exceeds_model_limit,
    ].freeze

    # THE APPROVAL STAGE is every TOOL row's and is crossed under every
    # mode, never skipped. The loop row's frozen `approval_mode` and
    # `approval_rules` and the row's own `authored_by` decide the verdict
    # through the one evaluator (Executors::Rules): a deny rule binds under
    # every mode for every origin; a `model` row is granted under `bypass`
    # (`origin: mode`), under `ask` by an allow rule (`origin: rule`) else
    # PARKS, under `rules` by an allow rule, parks on an ask rule, and is
    # otherwise DENIED as data — a typo never grants; an `author` or
    # `kernel` row is pre-approved by its origin unless a rule naming that
    # origin asks. A parked row rests at `needs_approval`, addressed to the
    # host's agent application with the decision's effect profile and the
    # park clock, listed on that inbox as kind `approval`, ended by the
    # member verbs (`Tasks::Approve.release`, the ONE grant site this stage
    # calls too) or the clock. Under `bypass` the crossing and the dispatch
    # land in one transaction, so only the event stream sees the stage. A
    # round has no stage: the admission plane admits it.

    class << self
      def call(agent_loop_id:)
        admitted = false
        AgentLoop.transaction do
          agent_loop = AgentLoop.lock.find_by(id: agent_loop_id)
          next if agent_loop.nil?

          if !agent_loop.terminal? && SourceWork.execution_stopped?(agent_loop)
            stop_forced(agent_loop)
          elsif !agent_loop.terminal? && !writable?(agent_loop)
            stop_without_authority(agent_loop)
          elsif agent_loop.running?
            admitted = schedule(agent_loop)
          end
          EvaluateQuiescence.call(agent_loop)
        end
        ModelInvocations::AdmitQueuedWorkJob.perform_later if admitted
        admitted
      end

      private

        # Pause and a repair hold suspend dispatch, not authority revocation.
        # Uncached so a cut after an earlier read is observed under this lock.
        def writable?(agent_loop)
          ApplicationRecord.uncached do
            agent_loop.workspace.data_writable_by?(agent_loop.creating_user)
          end
        end

        def stop_forced(agent_loop)
          if Stop.cancel_locked(agent_loop).accepted?
            ConvergeTerminalStepsJob.perform_later
            Spawn::RelayJob.perform_later
          end
        end

        def stop_without_authority(agent_loop)
          if agent_loop.pending? || agent_loop.canceling?
            # An unstarted loop cancels directly; an existing drain escalates
            # without restarting its canceling clock.
            stop_forced(agent_loop)
          else
            Stop.terminate(agent_loop, failure_reason: "authority_lost",
              step_reason: "workspace_access_revoked")
          end
        end

        def schedule(agent_loop)
          admitted = false
          TaskWaits.reconcile(agent_loop)
          admitted |= drain(agent_loop, ready_nodes(agent_loop))
          # The detached wake, here for latency only — the guarantee lives in
          # quiescence; whichever runs second finds the work delivered.
          admitted |= drain(agent_loop, deliver_detached(agent_loop))
          admitted
        end

        # Level-triggered like everything else here: the second pass
        # finds the work delivered and appends nothing.
        def deliver_detached(agent_loop)
          key = WakeContinuation.call(agent_loop: agent_loop)
          return [] if key.nil?

          agent_loop.agent_loop_nodes.where(node_key: key).to_a
        end

        def drain(agent_loop, worklist)
          admitted = false
          until worklist.empty?
            node = worklist.shift
            next unless node.reload.status == "queued"
            next unless node.remaining_dependencies.zero?

            admitted |= start_node(agent_loop, node, worklist)
          end
          admitted
        end

        def ready_nodes(agent_loop)
          agent_loop.agent_loop_nodes
            .where(status: "queued", remaining_dependencies: 0)
            .order(:created_at, :id).to_a
        end

        # The stage's verdict table, one function: `[:grant, origin]`,
        # `[:park]` or `[:deny, detail]`.
        def stage_verdict(agent_loop, node)
          verdict = Executors::Rules.verdict(agent_loop.approval_rules,
            tool_name: node.tool_name, tool_input: node.tool_input, origin: node.authored_by)
          return [:deny, verdict.reason || "denied by an approval rule"] if verdict.deny?
          # A non-model row is pre-approved by its origin unless a rule
          # that named its origin opted it back into asking.
          return (verdict.ask? ? [:park] : [:grant, node.authored_by]) unless node.authored_by == "model"

          case agent_loop.approval_mode
          when "bypass" then [:grant, "mode"]
          when "ask" then verdict.allow? ? [:grant, "rule"] : [:park]
          else
            if verdict.allow? then [:grant, "rule"]
            elsif verdict.ask? then [:park]
            else [:deny, "no approval rule allows #{node.tool_name}"]
            end
          end
        end

        # The park: ONE write puts the row at the stage addressed to the
        # host's agent application — the Human's member door alone on a
        # standalone loop without one — with the effect profile the
        # approver reads and the park clock; then the addressee is nudged
        # (`work_available`, kind `approval`). The decision's executor is
        # NOT stored: the release re-runs Address.
        def park(agent_loop, node, decision)
          address = Executors::Address.agent_address(agent_loop)
          Transition.node(node,
            status: "needs_approval", await_started_at: Time.current,
            addressed_executor_id: address&.id, addressed_role: ("agent_application" if address),
            effect_profile: decision.effect_profile)
          Executors::Nudge.work_available(node)
        end

        # The row says what it is (predicates, never a switch on the
        # class); a queued join surfacing here has an untrusted
        # countdown (an adjudication verb reset it), and the formula,
        # never the integer, decides.
        def start_node(agent_loop, node, worklist)
          return false if LifecycleHooks.before_start(agent_loop, node)

          return start_model_node(agent_loop, node, worklist) if node.round?
          return start_await_node(node) if node.await?
          return start_script_node(node) if node.script?
          return start_tool_node(agent_loop, node, worklist) if node.tool_call?
          if node.delegation?
            Transition.node(node, status: "running", started_at: Time.current)
            Spawn::RelayJob.perform_later
            return false
          end

          worklist.concat(Release.recompute(node))
          false
        end

        def start_script_node(node)
          now = Time.current
          Transition.node(node, status: "running", started_at: now, await_started_at: now)
          ScriptJob.perform_later(node.id, node.execution_generation)
          false
        end

        # The answer is written on the row; the inbox and the claim read it.
        # Tokened → `dispatched`, a holder outside the kernel has the proof;
        # tokenless → the ask, `awaiting_input`, nudging its addressee when it
        # has one (a Human loop's ask has none).
        def start_await_node(node)
          decision = Executors::Address.call(node)
          now = Time.current
          Transition.node(node,
            status: decision.status, started_at: now, await_started_at: now,
            addressed_executor_id: decision.executor&.id, addressed_role: decision.role)
          Executors::Nudge.work_available(node) if decision.executor
          TaskWaits.settle(node) if node.observing_task?
          false
        end

        # The kernel parks on the answer exactly as an await parks: a
        # kernel tool is `running` in one of our own jobs, an announced
        # one `dispatched` to the executor the row names. Nobody
        # announcing it is a failure the model reads (`tool_not_served`),
        # decided from `queued` — before the approval stage, which the
        # machine leaves only forward. Then the stage: the one type whose
        # effect reaches the person's machine has it, and says so on its
        # own machine — asked rather than assumed, so adding a type cannot
        # inherit permission silently.
        def start_tool_node(agent_loop, node, worklist)
          decision = Executors::Address.call(node)
          if decision.refused?
            FailNode.call(agent_loop: agent_loop, node: node, error_key: decision.error_key,
              error_detail: decision.detail, worklist: worklist)
            return false
          end

          verdict, word = node.class.approval_stage? ? stage_verdict(agent_loop, node) : [:grant, node.authored_by]
          if verdict == :park
            park(agent_loop, node, decision)
            return false
          end

          # The crossing is on the clock from the moment it enters the stage
          # (invariant 11); under a grant the release re-arms it as the run
          # clock, and a denial leaves it as the stamp of when it stood there.
          Transition.node(node, status: "needs_approval", await_started_at: Time.current) if
            node.class.approval_stage?
          if verdict == :deny
            FailNode.call(agent_loop: agent_loop, node: node, error_key: Tasks::Deny::ERROR_KEY,
              error_detail: word, worklist: worklist)
            return false
          end

          Tasks::Approve.release(agent_loop, node, decision: decision, origin: word)
          false
        end

        def start_model_node(agent_loop, node, worklist)
          selection, refusal = resolve_selection(agent_loop, node)
          if refusal && ModelFallback.call(agent_loop: agent_loop, node: node, reason: refusal)
            selection, refusal = resolve_selection(agent_loop, node)
          end
          if refusal
            fail_node(agent_loop, node, refusal.to_s, worklist)
            return false
          end

          if MailSeed.pending?(node)
            refusal = MailSeed.prepare(node: node, selection: selection)
            if refusal
              fail_node(agent_loop, node, refusal.to_s, worklist)
              return false
            end
            node.association(:input_body).reset
          end

          input = node_input(node)
          # A spliced round reads its sources; an unprepared mail seed
          # was assembled above. Every other plain round needs input.
          if input.blank? && node.input_from_node_keys.blank? && node.result_from_node_keys.blank?
            fail_node(agent_loop, node, "missing_input", worklist)
            return false
          end

          checkpoint = Steers::ConsumeAtCheckpoint.for(agent_loop: agent_loop, node: node)
          steers = checkpoint.peek
          composed = compose_input(node, input, selection, steers)
          if composed.refusal
            if planted_and_empty?(node, input, steers, composed.refusal)
              skip_planted_round(agent_loop, node, worklist)
              return false
            end
            # A round that will not fit is a round to make fit, once; the
            # typed refusal is otherwise a dead end nothing consumes.
            if SIZE_REFUSALS.include?(composed.refusal)
              trigger = Conversations::Compaction::Trigger.wall(node, overshoot: composed.overshoot)
              return false if repair(agent_loop, node, trigger, worklist)
            end

            fail_node(agent_loop, node, composed.refusal.to_s, worklist)
            return false
          end

          # A steer lands at the next unambiguous model boundary as its own
          # final user message; every refusal below leaves it pending for
          # the next. The pictures the composition read are placed per part
          # against THIS round's selection: native, or the index line in
          # place; the seal binds the placed rows.
          messages, placed = Conversations::ContextAssembly::AttachmentLine.place(
            composed.elements, composed.uploads,
            carries: Conversations::ContextAssembly::AttachmentLine.carries_for(selection)
          )

          normalized = ModelSelection::Workloads.accept_normalized_input(
            selection: selection, input: messages, uploads: placed
          )
          unless normalized.accepted?
            fail_node(agent_loop, node, normalized.refusal.to_s, worklist)
            return false
          end
          # THE PROVIDER'S OWN NUMBER FIRST: the last reported usage plus
          # what this round appends, on every lane — the counter below is
          # the second gate, for a round with no record behind it. Arms,
          # never fails: only an exact count may fail a round.
          over = over_usage(selection, node, composed)
          return false if over && repair(agent_loop, node,
            Conversations::Compaction::Trigger.usage(node, overshoot: over), worklist)

          # Over the window exactly or by a real tokenizer's estimate: only
          # an exact count may fail the round, but an estimate justifies a
          # repair, since compacting early costs a summary and never the round.
          over = over_window(selection, normalized)
          if over
            return false if repair(agent_loop, node,
              Conversations::Compaction::Trigger.wall(node, overshoot: over.overshoot), worklist)

            if over.exact
              fail_node(agent_loop, node, over.refusal.to_s, worklist)
              return false
            end
          end

          minted = mint_step(agent_loop, node, selection, normalized, worklist, source: composed.history_source)
          checkpoint.commit(steers, composed.steered, uploads: composed.uploads) if minted
          minted
        end

        # A kernel-planted follow-up round whose words were withdrawn has
        # nothing to ask: only the plant is a promptless spine round reading
        # its source alone — a wake round reads tips too.
        def planted_and_empty?(node, input, steers, refusal)
          refusal == InputComposition::MISSING_INPUT && steers.empty? &&
            input.blank? && node.continuation_source == Tasks::Compile::ROUND &&
            Array(node.input_from_node_keys).length <= 1 && node.result_from_node_keys.blank?
        end

        # The node's own input body, decoded by the row's one inverse.
        def node_input(node) = node.input_value

        # Settled skipped, no attempt charged; the answer that moved with
        # the plant moves back, and the quiescence pass looks again.
        def skip_planted_round(agent_loop, node, worklist)
          if agent_loop.deliverable_node_id == node.id
            source = agent_loop.agent_loop_nodes.find_by(node_key: node.input_from_node_keys.first)
            agent_loop.update!(deliverable_node_id: source&.id)
          end
          Transition.node(node, status: "skipped", completed_at: Time.current)
          worklist.concat(Release.settled(node))
        end

        # True when the round was handled here — repaired, or failed with
        # the raw rule's own key (under raw the kernel owns no history, so
        # its mode cannot repair and the round fails saying so).
        def repair(agent_loop, node, trigger, worklist)
          if Conversations::Compaction::Arm.policy_refusal(node) == Conversations::Compaction::Arm::RAW_REFUSAL
            fail_node(agent_loop, node, Conversations::Compaction::Arm::RAW_REFUSAL.to_s, worklist)
            return true
          end

          repaired = Conversations::Compaction::Arm.call(agent_loop: agent_loop, node: node, trigger: trigger)
          return false unless repaired

          # Born ready but not in this drain's worklist: the summarizer
          # after a summarize, the round itself after a prune (it composes
          # from rows now). The repair is only a repair if it starts in this pass.
          key = repaired.pruned? ? node.node_key : repaired.summary_task_key
          worklist.concat(agent_loop.agent_loop_nodes.where(node_key: key).to_a)
          true
        end

        # The composer owns the whole request, suffix zone included, so its
        # byte bound covers exactly what is sent; the steer ROWS go in, so
        # the composer renders each by its author.
        def compose_input(node, input, selection, steers)
          InputComposition.call(node: node, input: input, replay: replay_for(selection), steers: steers)
        end

        def replay_for(selection)
          capability = selection.capabilities.reasoning_replay
          return nil if capability.nil?

          Conversations::ContextAssembly::Replay.from_selection(selection)
        end

        def mint_step(agent_loop, node, selection, normalized, worklist, source:)
          invocation = ModelInvocation.create_for_selection(
            selection: selection,
            agent_loop: agent_loop,
            creating_user: agent_loop.creating_user,
            internal_creation_key:
              "agent_loop_step:#{node.id}:#{node.execution_generation}",
            request_options: step_request_options(selection, node, source: source)
          )
          request = ContentBodies::Replace.call(
            owner: invocation, role: "request",
            entries: Nexus::InputEntries.for(normalized.value.value),
            uploads: normalized.value.uploads,
            seal: true
          )
          unless request.accepted?
            invocation.terminalize(status: "failed", reason_key: "request_unstorable")
            fail_node(agent_loop, node, request.refusal.to_s, worklist)
            return false
          end

          Transition.node(node, status: "running", started_at: Time.current,
            selected_model_invocation_id: invocation.id)
          true
        end

        # `tools` is a request fact, never a generation control, so it is
        # merged after the selection's vocabulary rather than into it. The
        # ONE provider-bound site: an alias's resolution facts are stripped
        # here; the round keeps the whole entry. THE ONE PRESENCE RULE: the
        # `skill` entry is omitted while the loop's merged skill catalog is
        # empty — absent, not disabled; the stored set keeps it, and no
        # entry's bytes are ever shaped
        # (`AgentLoops::Skills::Catalog.declared`). `source` is the model
        # round whose sealed request this one replays as history.
        def step_request_options(selection, node, source:)
          options = selection.generation_config.to_h
          tools = AgentLoops::Skills::Catalog.declared(node.tool_definitions, node.agent_loop)
          options = options.merge("tools" => Nexus::ToolDeclarations.wire(tools)) if tools.present?
          options = options.merge(silenced_source_tools(selection, source)) if node.tool_definitions.blank?
          # The SYSTEM channel rides the wire's own field — segment one of
          # the cache contract, and the position a marker caches together
          # with the tool list on the Anthropic wire.
          options = options.merge("instructions" => node.system_instructions) if
            node.system_instructions.present?
          options.merge(Nexus::PromptCache::RequestKind::FACT => Nexus::PromptCache::RequestKind.stamp(cache_kind(node)))
        end

        # THE REQUEST'S CACHE KIND, stamped here at the one mint of a step:
        # the summarizer writes no marker; a branch — a composed member, a
        # detached step, a delegate — is read back within seconds; the spine
        # of a conversation's turn is paced by a person, a subagent's by its
        # parent; a standalone loop's rounds are seconds apart.
        def cache_kind(node)
          return "summary" if node.summary_task?
          return "branch" if node.continuation_source == Tasks::Compile::BRANCH

          conversation = node.agent_loop.conversation
          conversation ? Nexus::PromptCache::RequestKind.for_conversation(conversation) : "standalone"
        end

        # A TOOL-LESS CONTINUATION KEEPS ITS SOURCE'S TOOLS, TURNED OFF. The
        # step replays its source's request as history, and on the source's
        # lane the tool list heads the cached prefix and binds every
        # replayed thinking block: dropping it re-writes the whole request
        # and voids the source's thinking. So the step sends the tools the
        # source SENT, by value, under `tool_choice: none` — the provider's
        # own way to turn tool use off for one request. The declared set
        # stays empty, the delivery gate: a call is never admitted. Another
        # lane shares no prefix or signature with the source, and gets none.
        def silenced_source_tools(selection, source)
          sent = source&.selected_model_invocation
          same_lane = sent&.provider_id == selection.provider_id && sent.model_ref == selection.model_ref
          tools = same_lane ? sent.request_options["tools"] : nil
          tools.present? ? { "tools" => tools, "tool_choice" => "none" } : {}
        end

        def resolve_selection(agent_loop, node)
          resolved = ModelSelection.resolve(
            account: agent_loop.account,
            workload: "text_generation",
            submitted: Nexus::SubmittedModelSelection.new(
              model: "#{node.provider_id}/#{node.model_ref}",
              reasoning_effort: node.reasoning_effort
            ),
            configuration: OneShots::CoerceConfiguration.call(node.request_options),
            port: ModelSelection::Resolver.new
          )
          resolved.resolved? ? [resolved.selection, nil] : [nil, resolved.refusal]
        end

        # The pre-send window gate, the assembled-path symbol: only an EXACT
        # count may block (estimates advise, bytes enforce, the provider
        # stays authoritative). `overshoot` is by how much, for the prune arm.
        OverWindow = Data.define(:refusal, :exact, :overshoot)

        # A counter's estimate is evidence; a byte bound is not — bytes-as-
        # tokens over-states three or four times and would compact a quarter-full context.
        def over_window(selection, normalized)
          limit = selection.capabilities.limits.planning_input_bound
          return nil if limit.nil? || selection.execution_profile.token_counter.nil?

          counted = ModelRequests::TokenCount.count(
            profile: selection.execution_profile,
            segments: Nexus::ModelRequestInput.text_segments(normalized.value.value)
          )
          return nil unless counted.counted? && counted.tokens > limit

          OverWindow.new(refusal: :estimated_input_exceeds_model_limit, exact: counted.exact?,
            overshoot: Conversations::Compaction::Overshoot.tokens(counted.tokens - limit))
        end

        # The usage arm: the spine source's reported `input_tokens` and
        # `output_tokens` — what it said, reasoning included, is its output
        # as the provider counted it — plus the rest of the tail this round
        # appends, priced as assembly prices text. Answers the overshoot when
        # the bound is crossed, nil otherwise or when no record or no window
        # exists.
        def over_usage(selection, node, composed)
          limit = selection.capabilities.limits.planning_input_bound
          # A repaired round's prefix is not its source's request, so the
          # source's number says nothing about it.
          return nil if limit.nil? || node.repaired?

          record = Conversations::Compaction::LastUsage.for_round(node, source: composed.history_source)
          return nil if record&.input_tokens.nil?

          profile = selection.execution_profile
          tail = Nexus::ModelRequestInput.text_segments(composed.tail.drop(composed.said_count)).sum do |text|
            Conversations::ContextAssembly::FillCost.call(text, profile)
          end
          occupancy = record.input_tokens + record.output_tokens.to_i + tail
          Conversations::Compaction::Overshoot.tokens(occupancy - limit) if occupancy > limit
        end

        def fail_node(agent_loop, node, error_key, worklist)
          FailNode.call(agent_loop: agent_loop, node: node, error_key: error_key,
            error_detail: refused_before(agent_loop, node, error_key), worklist: worklist)
        end

        # A step the answerer's fallback took over after a refusal or an
        # overload, failing at its start there — a smaller window, fewer
        # modalities, a credential gone: the gate's key stays the error, and
        # the detail says the cause it follows, the one thing the reader
        # could not otherwise learn (the row fact renders in no envelope).
        def refused_before(agent_loop, node, error_key)
          return unless ModelFallback::SWITCH_REASONS.include?(node.output_summary.dig("model_change", "reason"))

          refused = ModelFallback.switch_causes_of(node).last
          return if refused.nil?

          verdict = ModelFallback::Verdict.new(stand: :fallback_unavailable,
            fallback: "#{node.provider_id}/#{node.model_ref}", word: error_key)
          RefusalSentence.for(invocation: refused, verdict: verdict, declaring_profile: agent_loop.declaring_profile)
        end
    end
  end
end
