module Nexus
  module Contract
    class << self
      private

        # The picture of a run, rendered by the route's own presenter over
        # doubles shaped like the rows: a round, the tool it called, the
        # continuation the kernel minted, a hidden join, and a script that
        # selects earlier results independently of its structural placement.
        def agent_loops
          node_type = Data.define(:id, :node_key, :task_kind, :status, :transcript_visibility,
            :error_key, :join_mode, :quorum_k, :loser_policy, :continuation_source, :sources, :detached,
            :failure_resolution, :mailed_at, :lifetime, :wake, :incoming_edges,
            :input_from_node_keys, :result_from_node_keys, :expansion_parent_id)
          edge_type = Data.define(:from_node_id, :structural)
          plain = { error_key: nil, join_mode: nil, quorum_k: nil, loser_policy: nil,
                    continuation_source: nil, detached: false, failure_resolution: nil, mailed_at: nil, lifetime: "conversation", wake: "auto",
                    incoming_edges: [], input_from_node_keys: nil, result_from_node_keys: nil, expansion_parent_id: nil }
          # An authored round's mark is NULL, and NULL is the spine.
          round = node_type.new(id: 1, node_key: "r1", task_kind: "model_task", status: "completed",
            transcript_visibility: "visible", sources: [], **plain)
          # The call rests at the stage: the resting word a picture must draw and a reader must
          # carry. THE KERNEL'S SPELLING: a round's calls carry its CONTINUATION's number — `r1`
          # makes `r2t0`, and `r2` reads it (ExpandRound mints both from one number; the thread
          # folds the call under `r2`).
          call = node_type.new(id: 2, node_key: "r2t0", task_kind: "tool_task", status: "needs_approval",
            transcript_visibility: "collapsed", sources: [round], **plain.merge(expansion_parent_id: round.id))
          continuation = node_type.new(id: 3, node_key: "r2", task_kind: "model_task",
            status: "queued", transcript_visibility: "visible", sources: [call],
            **plain.merge(continuation_source: AgentLoops::Tasks::Compile::ROUND,
              input_from_node_keys: %w[r1 r2t0], expansion_parent_id: round.id))
          gate = node_type.new(id: 4, node_key: "gate", task_kind: "join_task", status: "queued",
            transcript_visibility: "hidden", sources: [round, continuation],
            **plain.merge(join_mode: "any", loser_policy: "cancel_losers"))
          selected = node_type.new(id: 5, node_key: "select", task_kind: "script_task", status: "queued",
            transcript_visibility: "hidden", sources: [round, continuation, gate],
            **plain.merge(result_from_node_keys: %w[r2 r1]))
          graph_nodes = [round, call, continuation, gate, selected].map do |node|
            node.with(incoming_edges: node.sources.map do |source|
              edge_type.new(from_node_id: source.id, structural: node != selected || source == gate)
            end)
          end
          graph = stringify_keys(
            AgentAPI::AgentLoopGraphPresenter.build(nodes: graph_nodes,
              deliverable_node_id: 3).to_h
          )
          # THE BACKGROUND: two detached tips nothing waits on, keyed as the
          # task tool mints a child's root, one still running and one
          # settled and mailed after the reply went final — the one row that
          # carries `mailed_at`. They hang off no row, so the phases stay
          # the plan's and the background list is all they add.
          detached = plain.merge(detached: true)
          running_tip = node_type.new(id: 6, node_key: "r2t1-model-1", task_kind: "model_task",
            status: "running", transcript_visibility: "visible", sources: [], **detached)
          mailed_tip = node_type.new(id: 7, node_key: "r2t2-model-1", task_kind: "model_task",
            status: "completed", transcript_visibility: "visible", sources: [],
            **detached.merge(mailed_at: Time.utc(2026, 9, 12, 0, 0, 9)))
          # The phases projection over the same rows: `r1` is the authored
          # phase, its fan and continuation count inside it, and the gate
          # is the second phase.
          # THE SPEND, the route's seven members (audit wire-20): the two
          # token sums, the cache read beside the input count with its rate
          # (`UsageRecord.cache_hit_rate`), the money when every priced
          # receipt agrees on a unit — null here, an unpriced lane — and the
          # same receipts split by the model each names (`by_model`), here a
          # step re-run on a second model.
          phases = stringify_keys(
            AgentAPI::AgentLoopPhasesPresenter.build(
              nodes: [round, call, continuation, gate, running_tip, mailed_tip],
              plans: [["r1"], [{ "parallel" => ["r1", "r2"], "key" => "gate" }]],
              spend: { input_tokens: 41_230, output_tokens: 6_120, cache_read_tokens: 30_100,
                       cache_hit_rate: UsageRecord.cache_hit_rate(41_230, 30_100),
                       cost_amount: nil, cost_unit: nil,
                       by_model: {
                         "dev/mock-text" => { input_tokens: 40_000, output_tokens: 6_000, cache_read_tokens: 30_100,
                                              cost_amount: nil, cost_unit: nil },
                         "dev/mock-unmetered" => { input_tokens: 1_230, output_tokens: 120, cache_read_tokens: 0,
                                                   cost_amount: nil, cost_unit: nil },
                       } }
            ).to_h
          )

          thread = thread_page_fixture
          runner = contract_runner
          details = task_detail_fixtures(runner)
          request_loop = request_loop_fixture(runner)

          {
            # THE THREAD: the transcript route's page — spine rounds in reading order, each with the
            # calls it READ and the branches under them; `?prefix=<call>` answers the branch under
            # that call in the same envelope. Hand-typed to the kernel's spelling (`r1` makes
            # `r2t0`, `r2` reads it) and pinned key-for-key against a real page in
            # AgentLoops::TranscriptTest.
            "transcript_envelope" => thread.keys,
            # The row's keys in the builder's order; the optional ones by
            # presence (`error` on a failed round, the two compaction marks
            # on the round after a cut, `usage` once an attempt settled).
            "thread_row_projection" => %w[
              task_key spine status visibility text_preview text_bytes usage error compacted_before
              pruned_before started_at completed_at calls branches
            ],
            "thread_row_projection_required" => %w[task_key spine status visibility calls branches],
            "thread_calls_projection" => %w[count items],
            "thread_call_projection" => %w[
              task_key tool_call_id name tool status is_error title metadata output_preview output_bytes
              started_at completed_at
            ],
            "thread_call_projection_required" => %w[task_key name status],
            "valid_thread_page_fixture" => thread,
            "graph_envelope" => graph.keys,
            "node_projection" => graph.fetch("nodes").flat_map(&:keys).uniq,
            "node_projection_required" => %w[key kind status visibility deliverable lifetime wake input_from result_from],
            "edge_projection" => graph.fetch("edges").first.keys,
            "join_projection" => %w[until losers],
            # The STI roster, the authorable verbs first: `join_task` is
            # a READ kind (the barrier the kernel places) and leaves no write door.
            "node_kinds" => [AgentLoopNodes::AwaitTask, AgentLoopNodes::ModelTask, AgentLoopNodes::ToolTask,
                             AgentLoopNodes::ScriptTask, AgentLoopNodes::JoinTask, AgentLoopNodes::DelegationTask].map(&:task_kind),
            "phases_envelope" => phases.keys,
            "phase_projection" => phases.fetch("phases").first.keys,
            # A background row's keys by presence: `mailed_at` only once the tip was mailed.
            "background_projection" => phases.fetch("background").flat_map(&:keys).uniq,
            "background_projection_required" => %w[key status],
            "phase_spend_projection" => phases.fetch("spend").keys,
            "phase_spend_model_projection" => phases.dig("spend", "by_model").values.flat_map(&:keys).uniq,
            "phase_statuses" => %w[waiting running awaiting_human needs_approval completed failed],
            # The loop's attention reasons, the approval fact's vocabulary and its projection, and
            # the task verbs.
            "attention_reasons" => %w[halt_failure deliverable_unresolved awaiting_human approval_required],
            "approval_origins" => AgentLoopNode::APPROVAL_ORIGINS,
            "approval_projection" => %w[origin decided_by decided_at],
            "task_verbs" => %w[resolution retry abandon cancel compact approve deny],
            # THE LISTING'S GRAMMAR: a comma-separated status set, the
            # attention rollup (`any`), the keyset direction and window.
            "list_filters" => %w[status attention order after limit],
            "list_directions" => AgentAPI::KeysetPagination::DIRECTIONS.keys,
            "loop_statuses" => AgentLoop::STATUSES,
            "error_codes" => AGENT_LOOP_ERROR_STATUSES.keys,
            "error_statuses" => AGENT_LOOP_ERROR_STATUSES,
            "absence_refusals" => WORKSPACE_BASE::ABSENCE_REFUSALS.map(&:to_s),
            # The create door's open refusals are 422 (the base's `else`);
            # the lifecycle and adjudication verbs' are CONFLICTS — the
            # loop exists and its state is not the one the verb needs.
            "refusal_default_status" => 422,
            "lifecycle_refusal_status" => 409,
            "adjudication_refusal_status" => 409,
            "expired_detail_error_fixture" => api_error_fixture("execution_details_pruned", 410),
            "retained_loop_detail_fields" => %w[details_pruned_at],
            "valid_error_fixture" =>
              api_error_fixture("agent_loop_not_appendable", AGENT_LOOP_ERROR_STATUSES.fetch("agent_loop_not_appendable")),
            "unknown_error_fixture" => unknown_api_error_fixture,
            "valid_phases_fixture" => phases,
            # THE DEBUG DOOR on a task: the round's sealed request with its tools; a round never
            # scheduled is `request_not_sealed`.
            "valid_task_request_fixture" => sealed_request_fixture(
              entries: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "read it" }] }],
              request_options: {
                "temperature" => 0.2,
                "tools" => [{ "type" => "function", "function" => { "name" => "read_file",
                                                                    "parameters" => { "type" => "object" } } }],
              }
            ),
            # THE SINGLE-TASK READS, each rendered by the route's own
            # presenter over a node double (audit wire-21) — the shapes
            # below are `task_detail_fixtures`' rows: a settled round, a
            # settled tool call, the two `skill` loads, the relay's request
            # half, the restore and the store's records.
            **details,
            # The same loop, whole, after its one step completed: the seed is
            # the deliverable, the trace is that one task, no round ever ran
            # — rendered by `AgentLoopPresenter.build` over the loop double,
            # so `task_progress` is the presenter's bucket per status.
            "valid_request_loop_fixture" => { "agent_loop" => request_loop },
            "valid_loop_backed_fixture" => { "agent_loop" => loop_backed_fixture },
            "task_progress_projection" => request_loop.fetch("task_progress").keys,
            # The effective mechanism word on the loop's full projection: `default` or `raw` on a
            # loop-backed turn, null on a standalone loop and the kernel's summary loop.
            "prompt_mechanisms" => %w[default raw],
            "node_statuses" => AgentLoopNode::STATUSES.map { |status|
              AgentAPI::AgentLoopPresenter.public_status(status)
            }.sort,
            "mermaid_header" => "flowchart TD",
            "valid_graph_fixture" => graph,
            "unknown_node_status_fixture" =>
              graph.fetch("nodes").first.merge("status" => "future_status"),
          }
        end

        # THE NODE DOUBLE the single-task read renders over: every column
        # the presenter reads, defaulted the way an unset column reads.
        CONTRACT_NODE_TYPE = Data.define(
          :id, :node_key, :task_kind, :status, :sources, :on_failure, :failure_resolution, :retry_budget,
          :provider_id, :model_ref, :reasoning_effort, :tool_name, :tool_alias, :addressed_role,
          :addressed_executor, :claimed_by_executor_public_id, :approval_origin, :approved_by_user,
          :approval_decided_at, :output_summary, :error_key, :error_detail, :transcript_visibility,
          :created_at, :started_at, :completed_at, :mailed_at, :result_title, :result_metadata,
          :system_instructions, :tool_input, :sealed_request_bytes, :ask_options, :ask_multi, :lifetime, :wake,
          :output_preview, :tool_definitions
        ) do
          def initialize(sources: [], failure_resolution: nil, retry_budget: 0, provider_id: nil, model_ref: nil,
                         reasoning_effort: nil, tool_name: nil, tool_alias: nil, addressed_role: nil,
                         addressed_executor: nil, claimed_by_executor_public_id: nil, approval_origin: nil,
                         approved_by_user: nil, approval_decided_at: nil, output_summary: {}, error_key: nil,
                         error_detail: nil, started_at: nil, completed_at: nil, mailed_at: nil, result_title: nil,
                         result_metadata: nil, system_instructions: nil, tool_input: nil, sealed_request_bytes: nil,
                         ask_options: nil, ask_multi: nil, lifetime: "conversation", wake: "auto", output_preview: nil,
                         tool_definitions: nil, **) = super
          def terminal? = AgentLoopNode::TERMINAL_STATUSES.include?(status)
          def round? = task_kind == "model_task"
          def tool_call? = task_kind == "tool_task"
          def observing_task? = false
        end

        # An executor as the addressee and binding reads see it: a contact
        # sample and no live socket, so presence reads `offline`.
        CONTRACT_EXECUTOR_TYPE = Data.define(
          :public_id, :display_name, :presence_connection_id, :presence_server_id, :last_seen_at
        )

        def contract_runner
          CONTRACT_EXECUTOR_TYPE.new(
            public_id: "019f0000-0000-7000-8000-000000000301", display_name: "Fixture runner",
            presence_connection_id: nil, presence_server_id: nil, last_seen_at: Time.utc(2026, 9, 12, 0, 0, 2)
          )
        end

        def detail_of(node, output: nil, payloads: [], prompt: nil)
          { "task" => stringify_keys(AgentAPI::AgentLoopPresenter.detail(
            node, output: output, payloads: payloads, prompt: prompt, live_server_ids: []
          )) }
        end

        # The result grammar's stored entries (Parks::ResultContent): a text
        # block, a `resource_link` block, the one structured value.
        def text_payload(text) = { AgentLoops::Parks::ResultContent::TEXT => text }

        def link_payload(link) = { AgentLoops::Parks::ResultContent::RESOURCE_LINK => link }

        def structured_payload(value) = { AgentLoops::Parks::ResultContent::STRUCTURED => value }

        def task_detail_fixtures(runner)
          settled = { created_at: Time.utc(2026, 9, 12), started_at: Time.utc(2026, 9, 12, 0, 0, 1),
                      completed_at: Time.utc(2026, 9, 12, 0, 0, 2) }
          settled_later = { created_at: Time.utc(2026, 9, 15), started_at: Time.utc(2026, 9, 15, 0, 0, 1),
                            completed_at: Time.utc(2026, 9, 15, 0, 0, 2) }
          claimed = { claimed_by_executor_public_id: runner.public_id }
          granted = { approval_origin: "author", approval_decided_at: Time.utc(2026, 9, 15, 0, 0, 1) }
          resolved = { output_summary: { "resolved" => true } }
          deploy_text = "# Deploying\n\nRun `bin/deploy` from a clean main.\n\n" \
                        "Files for this skill are under /work/app/.agents/skills/deploy-notes; " \
                        "relative paths in the instructions are relative to it."
          commit_text = "# Commits\n\nOne change per commit; the subject names the change.\n"
          restore_text = "Restored 2 files to 4b825dc642cb6eb9a060e54bf8d69288fbee4904; " \
                         "undo with 9c1f2e3d4b5a69788796a5b4c3d2e1f0a9b8c7d6"
          records_text = "1 checkpoint for 01900000-0000-7000-8000-0000000000b1"
          {
            # THE SINGLE-TASK READ on a round: the trace row plus its `output` text and
            # `request_bytes`, the size its request was sealed with — the body's stored fact; absent
            # on every other kind and on a round never scheduled. A SETTLED round authored under
            # `raw`: the `instructions` the SDK wrote read back on this read alone, beside the
            # output and the `prompt` it was authored with.
            "valid_task_detail_fixture" => detail_of(CONTRACT_NODE_TYPE.new(
              id: 11, node_key: "r1", task_kind: "model_task", status: "completed", on_failure: "halt",
              provider_id: "dev", model_ref: "mock-text", reasoning_effort: "medium",
              transcript_visibility: "visible", system_instructions: "Be brief.", sealed_request_bytes: 41_230,
              tool_definitions: Nexus::ToolDeclarations.render([
                { "name" => "Clarify", "canonical" => "nexus.human.ask",
                  "params" => { "question" => { "maps_to" => "prompt" } }, "omit" => ["multi"] },
              ]),
              **settled
            ), output: "read it", prompt: "Read the file and say what it is."),
            "valid_toolless_task_detail_fixture" => detail_of(CONTRACT_NODE_TYPE.new(
              id: 12, node_key: "r2", task_kind: "model_task", status: "queued", on_failure: "halt",
              provider_id: "dev", model_ref: "mock-text", transcript_visibility: "visible",
              created_at: settled.fetch(:created_at)
            )),
            "valid_delegation_task_detail_fixture" => detail_of(CONTRACT_NODE_TYPE.new(
              id: 19, node_key: "r2t0-delegation", task_kind: "delegation_task", status: "completed",
              lifetime: "turn", on_failure: "absorb", transcript_visibility: "collapsed",
              **resolved, **settled
            ), output: "The child completed its report."),
            # THE SINGLE-TASK READ on a model's parked ASK (audit
            # refs-parity-6): the question under `prompt`, its choices as
            # data — `options`, one string each, `multi` when several may be
            # taken — the two the inbox's ask row serves as well; absent on
            # an ask that gave none.
            "valid_ask_task_detail_fixture" => detail_of(CONTRACT_NODE_TYPE.new(
              id: 16, node_key: "r1t0-ask-1", task_kind: "await_task", status: "awaiting_input", on_failure: "halt",
              transcript_visibility: "visible", ask_options: %w[Postgres MySQL], ask_multi: false,
              created_at: Time.utc(2026, 9, 15), started_at: Time.utc(2026, 9, 15, 0, 0, 1)
            ), prompt: "Which database should I use?"),
            # THE SINGLE-TASK READ on a SETTLED TOOL CALL (the three channels): `output` the text
            # the model read, `content` the blocks, `structured_content` the UI's whole value, and
            # the two UI fields the executor committed — `title` and `metadata`
            # (`metadata.checkpoint` reserved) — present only when sent. The `resource_link` block
            # names a CAPTURE, fetched through `uploads.json`'s bytes read; `output` is the text
            # alone, `output_preview` the bounded preview the settled call's feed item carries.
            "valid_tool_task_detail_fixture" => detail_of(CONTRACT_NODE_TYPE.new(
              id: 12, node_key: "r1t0", task_kind: "tool_task", status: "completed", on_failure: "absorb",
              tool_name: "read_file", tool_input: { "path" => "x.rb" }, transcript_visibility: "visible", output_preview: "class Foo",
              result_title: "read x.rb", result_metadata: { "checkpoint" => "c1" }, **claimed, **resolved, **settled
            ), output: "class Foo", payloads: [
              text_payload("class Foo"),
              link_payload({ "uri" => "nexus://uploads/#{UPLOAD_PUBLIC_ID}", "name" => "x.rb",
                             "mimeType" => "text/plain", "size" => 9 }),
              structured_payload({ "lines" => 1 }),
            ]),
            # THE TWO SETTLED `skill` LOADS — one per source, the same result grammar. A KERNEL-ROW
            # load ran in-process: nobody claimed it, `output` is the row's body as `memory_read`
            # would answer it, the title names the rung it was read from. An ANNOUNCED load reached
            # its announcer: claimed by that runner, the body it committed plus rho-runner's one
            # base-directory line. A name neither holds is an ordinary error result whose text is
            # the one word `skill_unknown: <name>`.
            "valid_skill_task_detail_fixture" => detail_of(CONTRACT_NODE_TYPE.new(
              id: 13, node_key: "r2t0", task_kind: "tool_task", status: "completed", on_failure: "absorb",
              tool_name: "skill", tool_input: { "name" => "commit-style" }, transcript_visibility: "collapsed",
              result_title: "read workspace/skills/commit-style", **resolved, **settled_later
            ), output: commit_text, payloads: [text_payload(commit_text)]),
            "valid_announced_skill_task_detail_fixture" => detail_of(CONTRACT_NODE_TYPE.new(
              id: 14, node_key: "r2t1", task_kind: "tool_task", status: "completed", on_failure: "absorb",
              tool_name: "skill", tool_alias: "Skill", tool_input: { "name" => "deploy-notes" },
              transcript_visibility: "collapsed", **claimed, **resolved,
              **settled_later.merge(completed_at: Time.utc(2026, 9, 15, 0, 0, 3))
            ), output: deploy_text, payloads: [text_payload(deploy_text)]),
            # THE REQUEST HALF OF THE RELAY: a ONE-TASK standalone loop's terminal task, never
            # claimed — an offline runner's request swept `timed_out` at its own deadline
            # (`tool_timeout`); the addressee stands, no claimant, no result. The SDK's composition
            # answers this task and stops the loop behind it.
            "valid_timed_out_task_detail_fixture" => detail_of(CONTRACT_NODE_TYPE.new(
              id: 15, node_key: "relay", task_kind: "tool_task", status: "timed_out", on_failure: "propagate",
              tool_name: "files_bytes", tool_input: { "path" => "note.txt" }, addressed_role: "runner",
              addressed_executor: runner, error_key: "tool_timeout", transcript_visibility: "visible",
              **settled.merge(completed_at: Time.utc(2026, 9, 12, 0, 0, 6))
            )),
            # THE RESTORE: a completed `world_restore {checkpoint}` request task on a runner that
            # keeps a shadow store — the tool's own sentence, its `structured_content` (the tree
            # restored, the UNDO it captured first, the counts, the nested checkouts it left alone)
            # and `metadata.checkpoint` naming that undo as a checkpoint on the reserved key, so a
            # reader finds it where it finds every checkpoint. Hidden by name: described to no
            # model.
            "valid_world_restore_task_detail_fixture" => detail_of(CONTRACT_NODE_TYPE.new(
              id: 16, node_key: "relay", task_kind: "tool_task", status: "completed", on_failure: "propagate",
              tool_name: "world_restore", tool_input: { "checkpoint" => "4b825dc642cb6eb9a060e54bf8d69288fbee4904" },
              transcript_visibility: "visible", result_title: "world restored",
              result_metadata: { "checkpoint" => { "hash" => "9c1f2e3d4b5a69788796a5b4c3d2e1f0a9b8c7d6",
                                                   "store" => "3f0c9d2a7b1e5c68" } },
              **claimed, **granted, **resolved, **settled_later.merge(completed_at: Time.utc(2026, 9, 15, 0, 0, 3))
            ), output: restore_text, payloads: [
              text_payload(restore_text),
              structured_payload({ "restored" => "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
                                   "undo" => "9c1f2e3d4b5a69788796a5b4c3d2e1f0a9b8c7d6",
                                   "files" => 2, "removed" => 1, "nested" => [] }),
            ]),
            # THE STORE'S OWN RECORDS: a completed `checkpoints {loop}` request task — the runner's
            # truth the kernel's `world` is a cache of: one record per loop that wrote on this root,
            # `present` saying whether the tree is still held.
            "valid_checkpoints_task_detail_fixture" => detail_of(CONTRACT_NODE_TYPE.new(
              id: 17, node_key: "relay", task_kind: "tool_task", status: "completed", on_failure: "propagate",
              tool_name: "checkpoints", tool_input: { "loop" => "01900000-0000-7000-8000-0000000000b1" },
              transcript_visibility: "visible", **claimed, **granted, **resolved, **settled_later
            ), output: records_text, payloads: [
              text_payload(records_text),
              structured_payload({ "records" => [{
                "loop" => "01900000-0000-7000-8000-0000000000b1",
                "hash" => "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
                "captured_at" => "2026-09-15T00:00:00Z", "files" => 2,
                "skipped" => [], "nested" => [], "outside" => [], "present" => true,
              }] }),
            ]),
          }
        end

        # THE LOOP DOUBLE `AgentLoopPresenter.build` renders over: a
        # standalone one-task loop, completed and bound to the runner that
        # claimed its relay; its waiting room holds nothing.
        def request_loop_fixture(runner)
          relay = CONTRACT_NODE_TYPE.new(
            id: 18, node_key: "relay", task_kind: "tool_task", status: "completed", on_failure: "propagate",
            tool_name: "files_bytes", claimed_by_executor_public_id: runner.public_id,
            approval_origin: "author", approval_decided_at: Time.utc(2026, 9, 12, 0, 0, 1),
            output_summary: { "resolved" => true }, transcript_visibility: "visible",
            created_at: Time.utc(2026, 9, 12), started_at: Time.utc(2026, 9, 12, 0, 0, 1),
            completed_at: Time.utc(2026, 9, 12, 0, 0, 2)
          )
          held = Data.define(:caller_authored).new(caller_authored: Data.define(:count).new(count: 0))
          loop_type = Data.define(
            :public_id, :status, :failure_reason, :turn_shape, :deliverable_node_id, :started_at, :paused_at,
            :completed_at, :details_pruned_at, :attention_reason, :input_queue_limit, :conversation_inputs, :bound_runner,
            :created_at, :updated_at, :prompt_mechanism, :approval_mode
          ) do
            def standalone? = true
          end
          agent_loop = loop_type.new(
            public_id: "019f0000-0000-7000-8000-000000000602", status: "completed", failure_reason: nil,
            turn_shape: AgentLoop::TurnShape.new(status: "completed", failure_reason_key: nil),
            deliverable_node_id: relay.id, started_at: Time.utc(2026, 9, 12, 0, 0, 1), paused_at: nil,
            completed_at: Time.utc(2026, 9, 12, 0, 0, 2), details_pruned_at: nil, attention_reason: nil,
            input_queue_limit: AgentLoop::INPUT_QUEUE_LIMIT, conversation_inputs: held, bound_runner: runner,
            created_at: Time.utc(2026, 9, 12), updated_at: Time.utc(2026, 9, 12, 0, 0, 2), prompt_mechanism: nil,
            approval_mode: "bypass"
          )
          stringify_keys(AgentAPI::AgentLoopPresenter.build(agent_loop, nodes: [relay], live_server_ids: []))
        end

        # A turn's answerer is frozen independently of the conversation's
        # current default, and rides the existing loop turn projection.
        def loop_backed_fixture
          answerer = Data.define(:public_id).new(public_id: "019f0000-0000-7000-8000-0000000000a2")
          conversation = Data.define(:public_id).new(public_id: "019f0000-0000-7000-8000-0000000000c1")
          turn = Data.define(:public_id, :conversation, :answering_user, :active_variant_id, :status).new(
            public_id: "019f0000-0000-7000-8000-0000000000d1", conversation: conversation,
            answering_user: answerer, active_variant_id: 1, status: "running"
          )
          loop_type = Data.define(:public_id, :status, :details_pruned_at, :failure_reason, :attention_reason,
            :created_at, :conversation_turn, :conversation_turn_variant_id, :turn_shape) do
            def standalone? = false
          end
          agent_loop = loop_type.new(
            public_id: "019f0000-0000-7000-8000-000000000603", status: "running", details_pruned_at: nil,
            failure_reason: nil, attention_reason: nil, created_at: Time.utc(2026, 9, 12),
            conversation_turn: turn, conversation_turn_variant_id: 1,
            turn_shape: AgentLoop::TurnShape.new(status: "running", failure_reason_key: nil)
          )
          model = Data.define(:provider_id, :model_ref, :reasoning_effort).new(
            provider_id: "dev", model_ref: "mock-text", reasoning_effort: nil
          )
          stringify_keys(AgentAPI::AgentLoopPresenter.basic(agent_loop, model: model))
        end

        # A page of the thread as the route serves it: three spine rounds
        # in reading order — the opener with nothing read, a round that
        # read a `read_file` call and an aliased `task` call whose branch
        # hangs under it (`branches` names the call; `?prefix=r2t1` expands
        # it), and the waiting tail showing the call it waits on — behind a
        # cursor with an older page. `spine` is the kernel's mark; a
        # branch's expansion answers the same rows with `spine: false`.
        def thread_page_fixture
          {
            "rounds" => [
              {
                "task_key" => "r1", "spine" => true, "status" => "completed", "visibility" => "visible",
                "text_preview" => "I will read the file, then hand the review to a subagent.", "text_bytes" => 57,
                "usage" => { "input_tokens" => 812, "output_tokens" => 40, "total_tokens" => 852 },
                "started_at" => "2026-09-14T00:00:01Z", "completed_at" => "2026-09-14T00:00:03Z",
                "calls" => { "count" => 0, "items" => [] }, "branches" => [],
              },
              {
                "task_key" => "r2", "spine" => true, "status" => "completed", "visibility" => "visible",
                "text_preview" => "The review found one unused method.", "text_bytes" => 35,
                "usage" => { "input_tokens" => 1_204, "output_tokens" => 18, "total_tokens" => 1_222,
                             "cache_read_tokens" => 800 },
                "started_at" => "2026-09-14T00:00:09Z", "completed_at" => "2026-09-14T00:00:11Z",
                "calls" => {
                  "count" => 2,
                  "items" => [
                    { "task_key" => "r2t0", "tool_call_id" => "call_1", "name" => "read_file", "status" => "completed",
                      "is_error" => false, "title" => "read x.rb", "metadata" => { "checkpoint" => "c1" },
                      "output_preview" => "class Foo", "output_bytes" => 9,
                      "started_at" => "2026-09-14T00:00:03Z", "completed_at" => "2026-09-14T00:00:04Z" },
                    { "task_key" => "r2t1", "tool_call_id" => "call_2", "name" => "Agent", "tool" => "task",
                      "status" => "completed", "is_error" => false,
                      "output_preview" => "lib/x.rb — orphan", "output_bytes" => 18,
                      "started_at" => "2026-09-14T00:00:03Z", "completed_at" => "2026-09-14T00:00:08Z" },
                  ],
                },
                "branches" => ["r2t1"],
              },
              {
                "task_key" => "r3", "spine" => true, "status" => "waiting", "visibility" => "visible",
                "calls" => {
                  "count" => 1,
                  "items" => [
                    { "task_key" => "r3t0", "tool_call_id" => "call_3", "name" => "bash", "status" => "dispatched",
                      "started_at" => "2026-09-14T00:00:11Z" },
                  ],
                },
                "branches" => [],
              },
            ],
            "pagination" => { "next_before" => "MQ", "has_older" => true },
          }
        end
    end
  end
end
