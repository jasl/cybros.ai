module Nexus
  module Contract
    class << self
      private

        def task_executors
          valid = {
            "executor" => {
              "public_id" => "01900000-0000-7000-8000-000000000030",
              "kind" => "agent_application",
              "status" => "active",
              "display_name" => "Fixture executor",
              "credential_epoch" => 1,
              # Presence beside the contact sample (r-modes M4): an HTTP
              # self-read has just stamped contact and holds no socket.
              "presence" => "offline",
              "last_seen_at" => "2026-07-30T00:00:00Z",
              "connected_at" => nil,
            },
            "measured_at" => "2026-07-30T00:00:00Z",
          }

          # THE ANNOUNCEMENT'S ONE WRITE SHAPE: the three lists the verb replaces whole — the tools,
          # the environment document, the DOCUMENTS this executor can load for a model as `{name,
          # description}` under the skill grammar — and DISCOVERY rendered by the real presenter
          # over that announcement: `served_documents` beside `served_tools` and `environment`.
          announcement = {
            "tools" => [
              { "name" => "read", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
                "description" => "Read a file under the root.",
                "input_schema" => { "type" => "object", "properties" => { "path" => { "type" => "string" } },
                                    "required" => ["path"] } },
              { "name" => "skill", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED },
            ],
            "environment" => { "root" => "/srv/lab", "platform" => "darwin",
                               "fragments" => [{ "extension" => "rho.coding", "text" => "Relative paths resolve against /srv/lab." }] },
            "documents" => [
              { "name" => "deploy-notes", "description" => "How this project is deployed. Use before any deploy or release step." },
            ],
          }
          discovered = Data.define(
            :public_id, :executor_kind, :display_name, :status, :assignment_scope, :served_tools, :environment,
            :served_documents, :presence_connection_id, :presence_server_id, :last_seen_at, :connected_at
          ).new(
            public_id: "01900000-0000-7000-8000-000000000032", executor_kind: "runner", display_name: "lab-mac",
            status: "active", assignment_scope: "user_private",
            served_tools: Nexus::ToolAnnouncements.canonical(announcement.fetch("tools")),
            environment: announcement.fetch("environment"),
            served_documents: Nexus::ToolAnnouncements.canonical_documents(announcement.fetch("documents")),
            presence_connection_id: nil, presence_server_id: nil,
            last_seen_at: Time.utc(2026, 7, 30, 0, 0, 0), connected_at: nil
          )

          {
            "executor_kinds" => TaskExecutor.executor_kinds.keys.sort,
            "statuses" => TaskExecutor.statuses.keys.sort,
            "valid_fixture" => valid,
            "announcement_request_fixture" => announcement,
            "served_document_keys" => Nexus::ToolAnnouncements::DOCUMENT_KEYS,
            # DISCOVERY'S ENVELOPES: the listing and the singular read, the one filter and its
            # closed words — the machine kinds alone; absent lists both.
            "discovery_envelope" => %w[executors],
            "discovery_singular_envelope" => %w[executor],
            "discovery_filters" => %w[kind],
            "discovery_kinds" => TaskExecutor::MACHINE_KINDS,
            "discovery_fixture" => stringify_keys(AgentAPI::ExecutorPresenter.discovery(discovered, live_server_ids: [])),
            "valid_discovery_kind_filter_request" => { "kind" => TaskExecutor::MACHINE_KINDS.first },
            "unknown_discovery_kind_filter_request" => { "kind" => UNKNOWN_VALUE_FIXTURE },
            "unknown_kind_fixture" => valid.merge(
              "executor" => valid.fetch("executor").merge("kind" => UNKNOWN_VALUE_FIXTURE)
            ),
            "unknown_status_fixture" => valid.merge(
              "executor" => valid.fetch("executor").merge("status" => UNKNOWN_VALUE_FIXTURE)
            ),
            "terminal_status_fixture" => valid.merge(
              "executor" => valid.fetch("executor").merge("status" => "revoked")
            ),
            "unknown_value_fixture" => UNKNOWN_VALUE_FIXTURE,
            "unknown_value_behavior" => "carry_unknown",
            "unknown_field_behavior" => "ignore",
          }
        end

        # The executor plane's inbox, rendered by the real presenter over fixture-built parked rows
        # with an addressee: the list envelope, the claim answer, an ask row (the question, no tool
        # fields, never claimed), and a kind this version does not know — the SDK carries it.
        def executor_inbox
          executor_public_id = "01900000-0000-7000-8000-000000000030"
          executor = Data.define(:public_id, :display_name).new(public_id: executor_public_id, display_name: "Fixture runner")
          # Every row names its workspace, including a standalone loop with no conversation.
          workspace = Data.define(:public_id).new(public_id: "01900000-0000-7000-8000-000000000001")
          agent_run = Data.define(:public_id, :workspace, :conversation)
            .new(public_id: "01900000-0000-7000-8000-000000000031", workspace: workspace, conversation: nil)
          # A kernel-named row's loop: the stamp reads the loop's workspace, conversation (nil:
          # standalone) and its MEMORY PRINCIPAL's controlling Human — only a kernel name
          # needs this additional scope stamp.
          anchored_loop = Data.define(:public_id, :workspace, :conversation, :creating_user, :memory_context) do
            def memory_principal = creating_user
          end.new(
            public_id: agent_run.public_id,
            workspace: workspace,
            conversation: nil,
            memory_context: nil,
            creating_user: Data.define(:controlling_human).new(
              controlling_human: Data.define(:public_id).new(public_id: "01900000-0000-7000-8000-000000000003")
            )
          )
          node_type = Data.define(
            :inbox_kind, :agent_run, :node_key, :prompt, :ask_options, :ask_multi, :tool_name, :tool_alias,
            :tool_input, :tool_call_id, :started_at, :deadline_at, :effective_timeout_ms, :claimed_at,
            :addressed_role, :addressed_executor, :effect_profile, :target_executor_public_id, :target_executor
          ) do
            def initialize(prompt: nil, ask_options: nil, ask_multi: nil, effect_profile: nil, tool_alias: nil, target_executor_public_id: nil, target_executor: nil,
                           **members) = super
            def wall_deadline_at = deadline_at
            def await? = inbox_kind == "ask"
            # An approval row IS a tool call resting at the stage.
            def tool_call? = inbox_kind != "ask"
          end
          started_at = Time.utc(2026, 7, 30, 0, 0, 0)
          # Every unclaimed row below states the budget its deadline was cut from: its `deadline_at`
          # is the fixture's start plus its `timeout_ms`.
          fields = {
            inbox_kind: "tool_call", agent_run: agent_run, node_key: "r1t0", tool_name: "read_file",
            tool_input: { "path" => "README.md" }, tool_call_id: "call_1",
            started_at: started_at, deadline_at: started_at + 10.minutes,
            effective_timeout_ms: 10.minutes.in_milliseconds, claimed_at: nil,
            addressed_role: "runner", addressed_executor: executor,
            target_executor_public_id: executor.public_id, target_executor: executor,
          }
          row = stringify_keys(Executors::Inbox.row(node_type.new(**fields)))
          claimed = stringify_keys(Executors::Inbox.row(node_type.new(**fields, claimed_at: started_at + 1.second)))
          # THE CLAIMANT'S EXTENSION (node review 2026-09-08, change 8): the
          # same row, its one clock moved — the new budget FROM NOW, bounded
          # by the tool's announced park or the kernel's hour — under the
          # claim's own envelope, the token unrotated. The row's `timeout_ms`
          # stays the park's: the deadline moved, the budget did not.
          extend_request = { "claim_token" => "01900000-0000-7000-8000-000000000032", "timeout_ms" => 900_000 }
          extended = stringify_keys(Executors::Inbox.row(node_type.new(
            **fields, claimed_at: started_at + 1.second,
            deadline_at: started_at + 1.second + (extend_request.fetch("timeout_ms") / 1000)
          )))
          ask = stringify_keys(Executors::Inbox.row(node_type.new(
            inbox_kind: "ask", agent_run: agent_run, node_key: "r1t0-ask-1", prompt: "which database?",
            ask_options: %w[Postgres MySQL], ask_multi: false,
            tool_name: nil, tool_input: nil, tool_call_id: nil,
            started_at: started_at, deadline_at: started_at + AgentRunTasks::AwaitTask::MAX_HOLD,
            effective_timeout_ms: AgentRunTasks::AwaitTask::MAX_HOLD_MS, claimed_at: nil,
            addressed_role: "agent_application", addressed_executor: executor
          )))
          overridden = stringify_keys(Executors::Inbox.row(node_type.new(
            inbox_kind: "tool_call", agent_run: anchored_loop, node_key: "r3t0", tool_name: "memory_read",
            tool_input: { "path" => "workspace/notes.md" }, tool_call_id: "call_3",
            started_at: started_at, deadline_at: started_at + 30.seconds, effective_timeout_ms: 30_000, claimed_at: nil,
            addressed_role: "tool_provider", addressed_executor: executor
          )))
          # THE SOURCE-ROUTED ROW: a model's `skill {name}` for a name this runner announced under
          # `documents` — the SAME `skill` row, addressed to the announcer, listed with the kernel's
          # `tool_name`, the model's `tool_alias` (Claude Code's `Skill` here), `tool_input`
          # untouched and the scope stamp every kernel-named row carries.
          skill = stringify_keys(Executors::Inbox.row(node_type.new(
            inbox_kind: "tool_call", agent_run: anchored_loop, node_key: "r4t0", tool_name: "skill",
            tool_alias: "Skill", tool_input: { "name" => "deploy-notes" }, tool_call_id: "call_4",
            started_at: started_at, deadline_at: started_at + 30.seconds, effective_timeout_ms: 30_000, claimed_at: nil,
            addressed_role: "runner", addressed_executor: executor
          )))
          # The approval row: a tool call resting for its approver — nothing started, the hold's 24
          # h clock, the frozen effect profile the approver reads, never claimed.
          approval = stringify_keys(Executors::Inbox.row(node_type.new(
            inbox_kind: "approval", agent_run: agent_run, node_key: "r2t0", tool_name: "bash",
            tool_input: { "command" => "rm -rf build" }, tool_call_id: "call_2",
            effect_profile: { "kind" => "write", "destructive" => true, "effect_scope" => "open",
                              "idempotency" => "none", "reconciliation" => "none", "timeout_ms" => 600_000 },
            started_at: nil, deadline_at: started_at + AgentRunTasks::AwaitTask::MAX_HOLD,
            effective_timeout_ms: AgentRunTasks::AwaitTask::MAX_HOLD_MS, claimed_at: nil,
            addressed_role: "agent_application", addressed_executor: executor
          )))
          list = { "tasks" => [row], "pagination" => { "next_after" => AgentRunTask::InboxCursor.encode(2) } }
          progress = progress_fixtures(executor_public_id: executor_public_id, run_public_id: agent_run.public_id)
          # A commit naming a CAPTURE: the text block the model reads, the `resource_link` block a
          # client fetches through the bytes read, the UI's `title` and the carrier `metadata`.
          commit_link = {
            "claim_token" => "01900000-0000-7000-8000-000000000032",
            "content" => [
              { "type" => "text", "text" => "Saved a screenshot of /sign_in to /tmp/shot.png" },
              { "type" => "resource_link", "uri" => "nexus://uploads/#{UPLOAD_PUBLIC_ID}",
                "name" => "shot.png", "mimeType" => "image/png", "size" => 184_211,
                "title" => "screenshot of /sign_in" },
            ],
            "title" => "screenshot",
            "metadata" => { "checkpoint" => "c1" },
          }
          unknown_kind = commit_link.merge("content" => [
            commit_link.fetch("content").fetch(0),
            commit_link.fetch("content").fetch(1).merge("type" => UNKNOWN_VALUE_FIXTURE),
          ])

          {
            "kinds" => %w[tool_call ask approval],
            "content_kinds" => AgentRuns::Parks::ResultContent::KINDS,
            "resource_link_uri_prefix" => AgentRuns::Parks::ResultContent::URI_PREFIX,
            "resource_link_fields" => %w[uri name mimeType size title description],
            "resource_link_required" => %w[uri name],
            "addressed_roles" => AgentRunTask::ADDRESSED_ROLES,
            "list_envelope" => list.keys,
            "pagination" => list.fetch("pagination").keys,
            "row_projection" => (row.keys | ask.keys | overridden.keys | skill.keys | approval.keys),
            "scope_projection" => %w[workspace_public_id conversation_public_id user_public_id],
            "memory_scope_projection" => %w[bindings],
            "claim_envelope" => %w[task claim],
            "claim_projection" => %w[claim_token deadline_at],
            "extend_envelope" => extend_request.keys,
            "extend_bound_ms" => Executors::Extend::MAX_EXTENSION_MS,
            "commit_envelope" => %w[claim_token content structured_content result_type outcome is_error title metadata],
            "outcomes" => AgentRuns::Parks::Settle::OUTCOMES,
            "list_filters" => %w[after limit],
            "limits" => { "default" => Executors::Inbox::DEFAULT_LIMIT, "max" => Executors::Inbox::MAX_LIMIT },
            "error_statuses" => EXECUTOR_INBOX_ERROR_STATUSES,
            "valid_fixture" => list,
            "claim_fixture" => {
              "task" => claimed,
              "claim" => { "claim_token" => "01900000-0000-7000-8000-000000000032",
                           "deadline_at" => claimed.fetch("deadline_at") },
            },
            "extend_request_fixture" => extend_request,
            "extend_fixture" => {
              "task" => extended,
              "claim" => { "claim_token" => extend_request.fetch("claim_token"),
                           "deadline_at" => extended.fetch("deadline_at") },
            },
            "ask_fixture" => ask,
            "approval_fixture" => approval,
            "overridden_fixture" => overridden,
            "skill_fixture" => skill,
            "commit_link_fixture" => commit_link,
            "unknown_content_kind_fixture" => unknown_kind,
            "unknown_kind_fixture" => row.merge("kind" => UNKNOWN_VALUE_FIXTURE),
            "unknown_value_fixture" => UNKNOWN_VALUE_FIXTURE,
            "unknown_value_behavior" => "carry_unknown",
            "unknown_field_behavior" => "ignore",
          }.merge(progress)
        end

        # THE PROGRESS DOOR: what an executor POSTS — the raw `{frame}` of each key kind — and what
        # goes out on the host's `progress` feed for it, rendered by the door's own shape functions,
        # so the SDK's `ProgressFrame` is settled against the kernel's bytes. `at` is milliseconds,
        # a String the encoder leaves alone: the per-key bound is observable on the wire only there.
        def progress_fixtures(executor_public_id:, run_public_id:)
          conversation_public_id = "01900000-0000-7000-8000-000000000033"
          at = "2026-09-13T10:00:00.250Z"
          task_request = {
            "frame" => {
              "run_public_id" => run_public_id, "task_key" => "r1t0",
              "claim_token" => "01900000-0000-7000-8000-000000000032",
              "text_tail" => "compiling 41/120\n", "structured" => { "done" => 41, "total" => 120 },
            },
          }
          process_request = {
            "frame" => {
              "conversation_public_id" => conversation_public_id, "process_id" => "p3",
              "source" => { "run_public_id" => run_public_id, "task_key" => "r1t0",
                "claim_token" => "01900000-0000-7000-8000-000000000032" },
              "lines" => ["Listening on http://127.0.0.1:4000"], "exit" => nil,
            },
          }
          task_frame = Executors::Progress.executor_progress(
            run_public_id: run_public_id, task_key: "r1t0", tool_name: "bash",
            executor_public_id: executor_public_id, at: at,
            payload: task_request.dig("frame").slice("text_tail", "structured")
          )
          process_frame = Executors::Progress.process_output(
            host_type: "conversation", host_public_id: conversation_public_id, process_id: "p3",
            executor_public_id: executor_public_id, at: at, payload: process_request.dig("frame").slice("lines", "exit")
          )
          {
            "progress" => {
              "key_kinds" => %w[task process],
              # No `frame_types` here: the feed's vocabulary — the door's two words and the kernel's
              # three — is listed ONCE, as `conversations.json#/progress_frame_types`.
              "min_interval_ms" => Executors::Progress::MIN_INTERVAL_MS,
              "request_envelope" => %w[frame],
              "task_key" => %w[run_public_id task_key claim_token],
              "process_key" => %w[conversation_public_id run_public_id process_id source],
              "process_source" => %w[run_public_id task_key claim_token],
              "stamps" => %w[type executor_public_id at tool_name],
              "task_payload" => Executors::Progress::TASK_PAYLOAD.keys,
              "process_payload" => Executors::Progress::PROCESS_PAYLOAD.keys,
              "feed_envelope" => %w[frame],
              "accepted_status" => 202,
            },
            "progress_task_frame_request_fixture" => task_request,
            "progress_process_frame_request_fixture" => process_request,
            "valid_progress_frame_fixture" => { "frame" => task_frame },
            "valid_process_output_frame_fixture" => { "frame" => process_frame },
            "unknown_progress_frame_type_fixture" => { "frame" => task_frame.merge("type" => UNKNOWN_VALUE_FIXTURE) },
            # A frame keyed by neither a task nor a process: `invalid_frame`.
            "unknown_progress_key_kind_fixture" => {
              "frame" => { "run_public_id" => run_public_id, UNKNOWN_VALUE_FIXTURE => "x" },
            },
          }
        end
    end
  end
end
