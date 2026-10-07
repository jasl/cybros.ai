require_relative "../test_helper"
require_relative "../support/ops_harness"

# Answers, approvals, task repair and pending input queue controls.
class OpsControlsTest < Minitest::Test
  include RhoTest::OpsHarness

  # A lineage holding BOTH planes: the member bearer for the person's
  # door, the transport credential for the agent application's own inbox.
  def both_planes_ready(daemon, api)
    about = Object.new
    about.define_singleton_method(:member_credential) { NexusDoubles::MEMBER_TOKEN }
    about.define_singleton_method(:executor_credential) { NexusDoubles::TRANSPORT_TOKEN }
    daemon.lineage.stop_maintenance
    daemon.lineage.adopt(identity: IDENTITY, credentials: about)
    daemon.lineage.commit_workspace(about, adopted_workspace)
    daemon.wire.api_transport = api
    daemon
  end

  EFFECT_PROFILE = { "kind" => "write", "destructive" => true, "effect_scope" => "open", "idempotency" => "none",
                     "reconciliation" => "none", "timeout_ms" => 600_000 }.freeze

  # The contract's `approval_fixture` shape (`executor_inbox.json`): a
  # held call addressed to the agent application, never claimed.
  def approval_row(key, command: "git push --force origin main")
    { "kind" => "approval", "run_public_id" => "al-9", "conversation_public_id" => nil,
      "parent_public_id" => nil, "task_key" => key, "tool_name" => "bash",
      "tool_input" => { "command" => command }, "effect_profile" => EFFECT_PROFILE, "tool_call_id" => "call-#{key}",
      "deadline_at" => "2026-09-08T00:00:00Z", "claimed" => false,
      "addressed_to" => { "role" => "agent_application", "executor_public_id" => "0199-executor" } }
  end

  def ask_row(key, prompt: "which database?")
    { "kind" => "ask", "run_public_id" => "al-9", "conversation_public_id" => nil,
      "parent_public_id" => nil, "task_key" => key, "prompt" => prompt,
      "started_at" => "2026-09-07T00:00:00Z", "deadline_at" => "2026-09-08T00:00:00Z", "claimed" => false,
      "addressed_to" => { "role" => "agent_application", "executor_public_id" => "0199-executor" } }
  end

  # ANSWERING IS AN OPS VERB WITH TWO DOORS OVER ONE
  # SETTLE: with no token the row is this agent's own inbox
  # `ask` and the commit goes on the EXECUTOR plane — no claim token, the
  # address is the door; the member resolution door is not touched.
  def test_an_ask_in_my_inbox_is_answered_on_the_executor_plane
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE)
    daemon = both_planes_ready(boot, api)
    api.stock_inbox(ask_row("ask-1"))

    response = request(daemon, :post, "/answer",
      token: bearer(daemon), body: { public_id: "al-9", task_key: "ask-1", content: "yes" })

    assert_equal "200", response.code, response.body
    assert_equal({ "public_id" => "al-9", "task_key" => "ask-1", "door" => "executor" },
      JSON.parse(response.body).fetch("answered"))
    assert_equal [["ask-1", { "content" => "yes" }]], api.commits, "no claim_token: the address is the door"
    assert_empty api.resolutions, "the member door was never asked"
    assert_equal "400",
      request(daemon, :post, "/answer", token: bearer(daemon), body: { public_id: "al-9" }).code
  end

  # A `--token` names a client-authored await, which is never an inbox
  # row: the person's door, exactly as before.
  def test_a_token_goes_to_the_member_door
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE)
    daemon = both_planes_ready(boot, api)

    response = request(daemon, :post, "/answer",
      token: bearer(daemon), body: { public_id: "al-9", task_key: "ask-1", content: "yes", resolution_token: "rt-1" })

    assert_equal "200", response.code, response.body
    assert_equal "member", JSON.parse(response.body).dig("answered", "door")
    assert_equal [{ "content" => "yes", "resolution_token" => "rt-1" }], api.resolutions
    assert(api.requests.any? { |path, _| path.end_with?("/tasks/ask-1/resolution") })
    assert_empty api.commits
  end

  # A row nobody addressed to this executor — a Human-created run's ask
  # (E7) — is `not_addressed_here` on the executor door, and the verb falls
  # ONCE to the member door, where rho's bearer has write standing.
  def test_a_row_not_addressed_here_falls_to_the_member_door_once
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE, commit: :not_addressed_here)
    daemon = both_planes_ready(boot, api)

    response = request(daemon, :post, "/answer",
      token: bearer(daemon), body: { public_id: "al-9", task_key: "ask-1", content: "yes" })

    assert_equal "200", response.code, response.body
    assert_equal "member", JSON.parse(response.body).dig("answered", "door")
    assert_equal [{ "content" => "yes" }], api.resolutions
    assert_equal 1, api.requests.count { |path, _| path.end_with?("/inbox/al-9/ask-1/commit") },
      "the executor door was tried exactly once"
  end

  # With no executor plane the verb has no inbox to commit on, and says so
  # rather than guessing a door.
  def test_answer_without_an_executor_plane_is_refused_by_name
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE)
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/answer",
      token: bearer(daemon), body: { public_id: "al-9", task_key: "ask-1", content: "yes" })

    assert_equal "503", response.code, response.body
    assert_equal "executor_plane_unavailable", JSON.parse(response.body).dig("error", "code")
    assert_empty api.resolutions
  end

  # THE LEVEL-TRIGGERED READ: the daemon's pending
  # rows are the `ask` and `approval` rows of its own inbox — a question a
  # person answers, a call a person decides, each with its clock — never
  # the tool rows beside them. One read lists both kinds, each named.
  def test_asks_lists_the_inboxs_ask_rows_with_their_questions
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE, inbox_tasks: [
      ask_row("ask-1"),
      { "kind" => "tool_call", "run_public_id" => "al-9", "conversation_public_id" => nil,
        "parent_public_id" => nil, "task_key" => "t1", "tool_name" => "ls",
        "tool_input" => {}, "tool_call_id" => "call-t1", "started_at" => nil, "deadline_at" => nil,
        "claimed" => false, "addressed_to" => { "role" => "runner", "executor_public_id" => "0199-executor" } },
    ])
    daemon = both_planes_ready(boot, api)

    response = request(daemon, :get, "/asks", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    assert_equal [{ "kind" => "ask", "run_public_id" => "al-9", "workspace_public_id" => "ws-1", "task_key" => "ask-1",
                    "prompt" => "which database?", "deadline_at" => "2026-09-08T00:00:00Z" }],
      JSON.parse(response.body).fetch("asks")
  end

  # An approval row lists with its tool, arguments, profile and clock (the
  # contract's `approval_fixture` shape); a tool_call row still does not.
  def test_asks_lists_an_approval_row_with_its_call_and_profile_and_a_tool_call_row_still_not
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE, inbox_tasks: [
      approval_row("r1t0"),
      { "kind" => "tool_call", "run_public_id" => "al-9", "conversation_public_id" => nil,
        "parent_public_id" => nil, "task_key" => "t1", "tool_name" => "ls",
        "tool_input" => {}, "tool_call_id" => "call-t1", "started_at" => nil, "deadline_at" => nil,
        "claimed" => false, "addressed_to" => { "role" => "runner", "executor_public_id" => "0199-executor" } },
      ask_row("ask-1"),
    ])
    daemon = both_planes_ready(boot, api)

    response = request(daemon, :get, "/asks", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    rows = JSON.parse(response.body).fetch("asks")
    assert_equal %w[approval ask], rows.map { |row| row.fetch("kind") }, "the inbox's order; the tool row is nobody's"
    assert_equal({ "kind" => "approval", "run_public_id" => "al-9", "workspace_public_id" => "ws-1", "task_key" => "r1t0",
                   "tool_name" => "bash", "tool_input" => { "command" => "git push --force origin main" },
                   "effect_profile" => EFFECT_PROFILE, "deadline_at" => "2026-09-08T00:00:00Z" }, rows.first)
  end

  # THE TWO VERBS (the adjudicate shape): `approve` releases the
  # held call and answers the task with the stage's fact; `deny` fails it
  # `approval_denied` with the reason as the detail the model reads, the
  # reason riding the posted body and NO reason posting none. The key is
  # ALWAYS named: an approval is a decision about one call whose arguments
  # the person has read, and deciding blind is what the stage exists to
  # prevent — no request reaches the kernel without it.
  def test_approve_and_deny_forward_to_the_kernel_and_answer_the_task_with_its_fact
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE)
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/runs/approve",
      token: bearer(daemon), body: { public_id: "al-9", task_key: "r1t0" })
    assert_equal "200", response.code, "body: #{response.body}"
    assert_equal({ "key" => "r1t0", "status" => "dispatched",
                   "approval" => { "origin" => "agent", "decided_by" => "0199-user",
                                   "decided_at" => "2026-09-08T12:00:00Z" } },
      JSON.parse(response.body).fetch("task"))
    assert_equal [["approve", "r1t0", nil]], api.adjudications, "the verb reached the kernel's own door, no body"

    response = request(daemon, :post, "/runs/deny",
      token: bearer(daemon), body: { public_id: "al-9", task_key: "r1t0", reason: "use ls" })
    assert_equal "200", response.code, "body: #{response.body}"
    assert_equal({ "key" => "r1t0", "status" => "failed",
                   "error" => { "key" => "approval_denied", "detail" => "use ls" },
                   "approval" => { "origin" => "agent", "decided_by" => "0199-user",
                                   "decided_at" => "2026-09-08T12:00:00Z" } },
      JSON.parse(response.body).fetch("task"))
    assert_equal ["deny", "r1t0", { "reason" => "use ls" }], api.adjudications.last, "the reason rides the body"

    response = request(daemon, :post, "/runs/deny", token: bearer(daemon), body: { public_id: "al-9", task_key: "r1t0" })
    assert_equal "200", response.code, response.body
    assert_equal ["deny", "r1t0", {}], api.adjudications.last, "no reason is an EMPTY body, never `reason: nil`"

    response = request(daemon, :post, "/runs/approve", token: bearer(daemon), body: { public_id: "al-9" })
    assert_equal "400", response.code, response.body
    assert_equal "malformed_body", JSON.parse(response.body).dig("error", "code")
    assert_match(/task_key is required/, JSON.parse(response.body).dig("error", "message"))
    assert_equal 3, api.adjudications.length, "a keyless decision never reaches the kernel"
  end

  def test_unfollowed_child_controls_keep_the_inbox_workspace_after_the_default_changes
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE,
      workspaces: [{ public_id: "ws-1", name: "Original" }, { public_id: "ws-2", name: "New default" }])
    daemon = both_planes_ready(boot, api)
    core = Rho::Core.new(home: daemon.home)
    daemon.home.write_setting("workspace", "ws-2")
    assert_nil daemon.host_followers.host_workspace("al-9"), "a waited child's run is not a followed host"

    core.approve("al-9", "r1t0", workspace_public_id: "ws-1")
    core.deny("al-9", "r1t0", workspace_public_id: "ws-1")
    api.stock_inbox(ask_row("ask-1"))
    daemon.home.write_setting("workspace", "missing")
    assert_equal "executor", core.answer("al-9", "ask-1", "yes", workspace_public_id: "ws-1").fetch("door")
    assert_equal "member", core.answer("al-9", "ask-1", "yes", token: "rt-1", workspace_public_id: "ws-1").fetch("door")

    paths = api.requests.map(&:first).grep(%r{/tasks/(?:r1t0|ask-1)/(?:approve|deny|resolution)\z})
    assert_equal 3, paths.length
    assert paths.all? { |path| path.start_with?("/agent_api/v1/workspaces/ws-1/") }, paths.inspect
    assert_equal "missing", daemon.home.settings_workspace
    assert_nil store.find("al-9"), "answering does not attach the child"
  end

  # The kernel's own refusals call_tool as themselves: a row not resting for an
  # approver is 409 `not_awaiting_approval`.
  def test_approve_relays_the_kernels_not_awaiting_approval
    refusal = CybrosAgent::Response.new(status: 409, headers: {},
      body: { "error" => { "code" => "not_awaiting_approval", "message" => "r1t0 is not awaiting approval" } })
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE, adjudication: refusal))

    response = request(daemon, :post, "/runs/approve",
      token: bearer(daemon), body: { public_id: "al-9", task_key: "r1t0" })

    assert_equal "409", response.code, response.body
    assert_equal "not_awaiting_approval", JSON.parse(response.body).dig("error", "code")
  end

  def test_retry_forwards_to_the_kernel_and_answers_the_task
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE)
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/runs/retry",
      token: bearer(daemon), body: { public_id: "al-9", task_key: "round1" })

    assert_equal "200", response.code, "body: #{response.body}"
    assert_equal({ "key" => "round1", "status" => "waiting" },
      JSON.parse(response.body).fetch("task"))
    assert(api.requests.any? { |path, _| path.end_with?("/tasks/round1/retry") },
      "the verb reached the kernel's own door: #{api.requests.map(&:first).inspect}")
  end

  # Model controls reach the SDK independently, including false. Abandon
  # re-runs nothing, so controls there are refused before the kernel read.
  def test_retry_passes_a_named_model_to_the_kernel_and_abandon_refuses_one
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE)
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/runs/retry", token: bearer(daemon),
      body: { public_id: "al-9", task_key: "round1", model: "dev/fallback", reasoning_effort: "high" })
    assert_equal "200", response.code, response.body
    assert_equal ["retry", "round1", { "model" => { "model" => "dev/fallback", "reasoning_effort" => "high" } }],
      api.adjudications.last

    request(daemon, :post, "/runs/retry", token: bearer(daemon), body: { public_id: "al-9", task_key: "round1" })
    assert_equal ["retry", "round1", nil], api.adjudications.last, "no model named, no body: the selection stands"

    effort = request(daemon, :post, "/runs/retry", token: bearer(daemon),
      body: { public_id: "al-9", task_key: "round1", reasoning_effort: "high" })
    assert_equal "200", effort.code, effort.body
    assert_equal ["retry", "round1", { "model" => { "reasoning_effort" => "high" } }], api.adjudications.last

    [false, true].each do |enabled|
      response = request(daemon, :post, "/runs/retry", token: bearer(daemon),
        body: { public_id: "al-9", task_key: "round1", reasoning_enabled: enabled })
      assert_equal "200", response.code, response.body
      assert_equal ["retry", "round1", { "model" => { "reasoning_enabled" => enabled } }], api.adjudications.last
    end

    abandoned = request(daemon, :post, "/runs/abandon", token: bearer(daemon),
      body: { public_id: "al-9", task_key: "round1", model: "dev/fallback" })
    assert_equal "400", abandoned.code
    assert_equal "abandon re-runs nothing, so it takes no model; retry names one",
      JSON.parse(abandoned.body).dig("error", "message")
    abandoned = request(daemon, :post, "/runs/abandon", token: bearer(daemon),
      body: { public_id: "al-9", task_key: "round1", reasoning_enabled: false })
    assert_equal "400", abandoned.code
    assert_equal 5, api.adjudications.length, "neither abandon refusal reached the kernel"
  end

  # A person typing the verb at a halted run means the thing that failed.
  # With one candidate the daemon reads the trace and picks it.
  def test_retry_with_no_key_picks_the_single_repairable_task
    trace = NexusDoubles::HALTED_TRACE.merge(
      "tasks" => NexusDoubles::HALTED_TRACE.fetch("tasks").reject { |task| %w[round2 round4].include?(task.fetch("key")) }
    )
    api = NexusDoubles::FakeAgentApi.new(trace: trace)
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/runs/retry",
      token: bearer(daemon), body: { public_id: "al-9" })

    assert_equal "200", response.code, "body: #{response.body}"
    assert_equal "round1", JSON.parse(response.body).dig("task", "key")
  end

  # Several candidates: guessing between them is worse than asking, so it
  # refuses and names every one — the two unresolved rounds AND the
  # uncertain call, which is adjudicable like a failure — and
  # calls no adjudication door.
  def test_retry_with_no_key_and_several_candidates_refuses_and_names_them
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE)
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/runs/retry",
      token: bearer(daemon), body: { public_id: "al-9" })

    assert_equal "409", response.code
    body = JSON.parse(response.body)
    assert_equal "ambiguous_repair", body.dig("error", "code")
    assert_equal "Name one of: round1, round2, round4", body.dig("error", "message")
    refute(api.requests.any? { |path, _| path.include?("/retry") },
      "nothing was adjudicated while the choice was ambiguous")
  end

  # AN UNCERTAIN CALL IS A PERSON'S TO RE-RUN, and the verb is the same
  # one: rho holds no rule of its own for the word — the SDK's `failed?`
  # is what `repairable_tasks` reads — so naming it posts the retry.
  def test_retry_names_an_uncertain_call_and_posts_the_verb
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE)
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/runs/retry",
      token: bearer(daemon), body: { public_id: "al-9", task_key: "round4" })

    assert_equal "200", response.code, "body: #{response.body}"
    assert(api.requests.any? { |path, _| path.end_with?("/tasks/round4/retry") },
      "the verb reached the kernel's own door: #{api.requests.map(&:first).inspect}")
  end

  def test_a_run_with_nothing_wrong_says_so_rather_than_guessing
    abandoned = NexusDoubles::HALTED_TRACE.fetch("tasks").find { |task| task["failure_resolution"] }
    healthy = NexusDoubles::HALTED_TRACE.merge("status" => "running", "attention" => nil,
      "tasks" => [abandoned])
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(trace: healthy))

    response = request(daemon, :post, "/runs/retry",
      token: bearer(daemon), body: { public_id: "al-9" })

    assert_equal "409", response.code
    assert_equal "nothing_to_repair", JSON.parse(response.body).dig("error", "code")
  end

  def test_abandon_answers_the_settlement
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE)
    daemon = member_ready(boot, api)

    abandoned = request(daemon, :post, "/runs/abandon",
      token: bearer(daemon), body: { public_id: "al-9", task_key: "round1" })
    assert_equal "abandoned", JSON.parse(abandoned.body).dig("task", "failure_resolution")
  end

  def test_delete_tombstones_the_record
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE)
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/runs/delete",
      token: bearer(daemon), body: { public_id: "al-9" })

    assert_equal "200", response.code
    assert_equal "al-9", JSON.parse(response.body).dig("deleted", "public_id")
  end

  # The kernel's refusal is the honest answer; the daemon carries its code
  # rather than inventing one.
  def test_a_kernel_refusal_is_carried_with_its_own_code
    refusal = CybrosAgent::Response.new(
      status: 409, headers: {},
      body: { "error" => { "code" => "not_retryable", "message" => "a join settles structurally" } }
    )
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE,
      adjudication: refusal))

    response = request(daemon, :post, "/runs/retry",
      token: bearer(daemon), body: { public_id: "al-9", task_key: "round1" })

    assert_equal "409", response.code
    assert_equal "not_retryable", JSON.parse(response.body).dig("error", "code")
  end

  def test_the_repair_routes_are_authenticated_and_need_a_public_id
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE))

    assert_equal "401", request(daemon, :post, "/runs/retry", body: { public_id: "al-9" }).code
    assert_equal "400",
      request(daemon, :post, "/runs/retry", token: bearer(daemon), body: {}).code
  end

  # ---- the queue verbs over the daemon ----

  # A followed host's queue, listed, dropped from and rewritten:
  # the three doors are the SDK's own `inputs.list/delete/update` on the
  # host the id names — a conversation's or its backing run's, through
  # the one resolution rule — and a kernel refusal relays as itself.
  def test_the_inputs_routes_list_drop_and_rewrite_a_followed_hosts_queue
    rows = [NexusDoubles.input_row("cin-1", "blocked", text: "push it", blocked_reason: "unknown_model"),
            NexusDoubles.input_row("cin-2", "pending", text: "and then", queue_position: 1)]
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, input_list: rows)
    daemon = member_ready(boot, api)
    store.remember(Rho::Host::Conversation.new(public_id: "c-1"), workspace: "ws-1", turn: "t-1", run_public_id: "al-1")

    listed = request(daemon, :get, "/inputs?public_id=al-1", token: bearer(daemon))
    assert_equal "200", listed.code, listed.body
    queue = JSON.parse(listed.body)
    assert_equal [%w[cin-1 blocked unknown_model], ["cin-2", "pending", nil]],
      queue.fetch("inputs").map { |row| [row["public_id"], row["state"], row["blocked_reason"]] }
    assert_equal "c-1", queue.fetch("host_public_id"), "a run id resolved to the conversation it backs"
    assert(api.requests.any? { |path, _| path.end_with?("/conversations/c-1/inputs") })
    assert_equal "400", request(daemon, :get, "/inputs", token: bearer(daemon)).code

    dropped = request(daemon, :post, "/inputs/delete", token: bearer(daemon),
      body: { public_id: "c-1", input_public_id: "cin-1" })
    assert_equal "200", dropped.code, dropped.body
    assert_equal({ "public_id" => "cin-1", "host_public_id" => "c-1" }, JSON.parse(dropped.body).fetch("deleted"))
    assert_equal %w[cin-1], api.input_deletes
    assert_equal "400", request(daemon, :post, "/inputs/delete", token: bearer(daemon), body: { public_id: "c-1" }).code

    edited = request(daemon, :post, "/inputs/update", token: bearer(daemon),
      body: { public_id: "c-1", input_public_id: "cin-1", text: "push it again" })
    assert_equal "200", edited.code, edited.body
    assert_equal %w[cin-1 pending], JSON.parse(edited.body).fetch("input").values_at("public_id", "state")
    assert_equal [["cin-1", { "input" => { "text" => "push it again" } }]], api.input_updates,
      "the text alone rides the PATCH: no fence, the person is the row's one writer"
    assert_equal "400", request(daemon, :post, "/inputs/update", token: bearer(daemon),
      body: { public_id: "c-1", input_public_id: "cin-1", text: " " }).code
  end

  def test_the_input_queue_preserves_explicit_tool_subsets_and_unknown_scope
    rows = [
      NexusDoubles.input_row("cin-read", "pending").merge("tool_names" => ["read"]),
      NexusDoubles.input_row("cin-none", "pending").merge("tool_names" => []),
      NexusDoubles.input_row("cin-default", "pending"),
    ]
    api = NexusDoubles::FakeAgentApi.new(input_list: rows)
    daemon = member_ready(boot, api)

    response = request(daemon, :get, "/inputs?public_id=c-1&host_type=conversation", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    read, none, default = JSON.parse(response.body).fetch("inputs")
    assert_equal ["read"], read.fetch("tool_names")
    assert_equal [], none.fetch("tool_names")
    refute default.key?("tool_names"), "an omitted subset cannot prove a read-only admission"
  end

  # A kernel-origin row is nobody's to change: the
  # kernel's 409 relays with its code and its sentence, never re-worded.
  def test_the_inputs_routes_relay_the_kernels_refusal_on_a_kernel_origin_row
    refusal = CybrosAgent::Response.new(status: 409, headers: {},
      body: { "error" => { "code" => "kernel_input_immutable", "message" => "A kernel-origin input is not editable" } })
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, input_delete: refusal, input_update: refusal)
    daemon = member_ready(boot, api)
    store.remember(Rho::Host::Conversation.new(public_id: "c-1"), workspace: "ws-1")

    dropped = request(daemon, :post, "/inputs/delete", token: bearer(daemon),
      body: { public_id: "c-1", input_public_id: "cin-k" })
    assert_equal "409", dropped.code
    assert_equal "kernel_input_immutable", JSON.parse(dropped.body).dig("error", "code")
    edited = request(daemon, :post, "/inputs/update", token: bearer(daemon),
      body: { public_id: "c-1", input_public_id: "cin-k", text: "no" })
    assert_equal "409", edited.code
    assert_match(/not editable/, JSON.parse(edited.body).dig("error", "message"))
  end

  def test_queue_writes_address_an_unfollowed_conversation_in_its_original_workspace
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE,
      workspaces: [{ public_id: "ws-1", name: "Original" }, { public_id: "ws-2", name: "New default" }])
    daemon = member_ready(boot, api)
    daemon.home.write_setting("workspace", "ws-2")
    body = { public_id: "c-1", input_public_id: "cin-1", host_type: "conversation", workspace_public_id: "ws-1" }

    deleted = request(daemon, :post, "/inputs/delete", token: bearer(daemon), body: body)
    edited = request(daemon, :post, "/inputs/update", token: bearer(daemon), body: body.merge(text: "Corrected"))

    assert_equal "200", deleted.code, deleted.body
    assert_equal "200", edited.code, edited.body
    paths = api.requests.map(&:first).grep(%r{/inputs/cin-1\z})
    assert_equal ["/agent_api/v1/workspaces/ws-1/conversations/c-1/inputs/cin-1"] * 2, paths
    refute api.requests.any? { |path, _| path.include?("/runs/c-1") }
    assert_nil store.find("c-1"), "editing the queue does not attach a follower"

    refused = request(daemon, :post, "/inputs/delete", token: bearer(daemon), body: body.merge(host_type: "unknown"))
    assert_equal "400", refused.code
    assert_equal 1, api.input_deletes.length
  end
end
