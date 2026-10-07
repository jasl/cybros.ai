require "test_helper"
require_relative "../support/contract_fixtures"

# THE EXECUTOR'S INBOX: the inbox is the truth, a claim is
# exclusive by token and time, and the commit carries two axes that must
# not collapse into one. Every door here rides the EXECUTOR plane on the
# transport credential — a runner is `executor_client` alone.
class ApiExecutorInboxTest < Minitest::Test
  RUN_ID = "019f0000-0000-7000-8000-000000000601".freeze
  WORKSPACE_ID = "019f0000-0000-7000-8000-000000000101".freeze
  EXECUTOR_ID = "019f0000-0000-7000-8000-000000000701".freeze
  INBOX_PATH = "/agent_api/v1/executor/inbox".freeze
  TASK_PATH = "#{INBOX_PATH}/#{RUN_ID}/r1t0".freeze

  # A standalone run's row: the kernel states both conversation members
  # on every row, null when there is none.
  ROW = {
    "kind" => "tool_call",
    "run_public_id" => RUN_ID,
    "workspace_public_id" => WORKSPACE_ID,
    "conversation_public_id" => nil,
    "parent_public_id" => nil,
    "task_key" => "r1t0",
    "tool_name" => "read_file",
    "tool_input" => { "path" => "a.rb" },
    "tool_call_id" => "call_a",
    "started_at" => "2026-08-31T00:00:00Z",
    "deadline_at" => "2026-08-31T00:10:00Z",
    "timeout_ms" => 600_000,
    "claimed" => false,
    "addressed_to" => { "role" => "runner", "executor_public_id" => EXECUTOR_ID },
  }.freeze

  def executor_client(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::ExecutorClient.new(base_url: "http://example.test", credential: "sk-transport",
      transport: @transport)
  end

  def inbox_task(script)
    executor_client(script).inbox_task(run_public_id: RUN_ID, task_key: "r1t0")
  end

  def request(index = 0)
    @transport.requests.fetch(index)
  end

  def test_the_inbox_lists_parked_work_with_manual_pagination
    page = executor_client([[200, {}, {
      "tasks" => [ROW],
      "pagination" => { "next_after" => "cursor-1" },
    }]]).inbox.list(after: "cursor-0", limit: 10)

    assert_equal :get, request.fetch(:method)
    assert_equal INBOX_PATH, request.fetch(:path)
    assert_equal "sk-transport", request.fetch(:credential)
    assert_equal({ "after" => "cursor-0", "limit" => 10 }, request.fetch(:params))

    assert_equal 1, page.items.length
    task = page.items.first
    assert_equal "tool_call", task.kind
    assert_equal "r1t0", task.task_key
    assert_equal "read_file", task.tool_name
    assert_equal({ "path" => "a.rb" }, task.tool_input)
    assert_equal "call_a", task.tool_call_id
    assert_equal "runner", task.addressed_to.role
    assert_equal EXECUTOR_ID, task.addressed_to.executor_public_id
    refute_predicate task, :claimed?
    assert_equal "cursor-1", page.next_after
  end

  # THE INBOX STAYS COMPLETE — claimed rows included — because a runner
  # returning from a crash must be able to see the work it already holds.
  # `claimed` is EVER claimed in this generation, never "taken by me".
  def test_a_claimed_row_is_still_listed
    page = executor_client([[200, {}, {
      "tasks" => [ROW.merge("claimed" => true)],
      "pagination" => { "next_after" => nil },
    }]]).inbox.list

    assert_predicate page.items.first, :claimed?
    assert_nil page.next_after
    assert_nil request.fetch(:params)
  end

  # A tool called with no arguments reads as {} rather than nil, so a runner
  # never has to tell "no arguments" from "not told".
  def test_a_compacted_row_reads_as_empty_arguments
    page = executor_client([[200, {}, {
      "tasks" => [ROW.reject { |k, _| %w[tool_input tool_call_id claimed].include?(k) }],
      "pagination" => { "next_after" => nil },
    }]]).inbox.list

    assert_equal 1, page.items.length
    task = page.items.first
    assert_equal({}, task.tool_input)
    assert_nil task.tool_call_id
    refute_predicate task, :claimed?
  end

  # An ask row: the agent application's own question to answer,
  # with its prompt and no tool name — listed beside tool rows, never
  # claimed, and never a reason the page fails to parse.
  def test_an_ask_row_parses_with_its_prompt_and_no_tool_name_and_is_never_claimed
    page = executor_client([[200, {}, {
      "tasks" => [ROW, {
        "kind" => "ask", "run_public_id" => RUN_ID, "workspace_public_id" => WORKSPACE_ID,
        "conversation_public_id" => nil,
        "parent_public_id" => nil, "task_key" => "r1t0-ask-1",
        "prompt" => "which database?", "started_at" => "2026-08-31T00:00:00Z",
        "deadline_at" => "2026-09-01T00:00:00Z", "claimed" => false,
        "addressed_to" => { "role" => "agent_application", "executor_public_id" => EXECUTOR_ID },
      }],
      "pagination" => { "next_after" => nil },
    }]]).inbox.list

    ask = page.items.fetch(1)
    assert_equal "ask", ask.kind
    assert_equal "which database?", ask.prompt
    assert_nil ask.tool_name
    assert_equal({}, ask.tool_input)
    refute_predicate ask, :claimed?
    assert_equal "agent_application", ask.addressed_to.role
    assert_nil page.items.fetch(0).prompt, "a tool row carries no question"
  end

  # A kind this gem predates is carried, not refused: the vocabulary grows
  # on the server first and the client must keep listing.
  def test_an_unknown_kind_is_carried_not_refused
    page = executor_client([[200, {}, {
      "tasks" => [ROW.merge("kind" => "zz_future_kind")],
      "pagination" => { "next_after" => nil },
    }]]).inbox.list

    assert_equal "zz_future_kind", page.items.first.kind
  end

  # A pool row names a role and no executor, or no address at
  # all; both parse. `addressed_to` is nil only when nothing names a role.
  def test_a_row_without_addressed_to_parses
    page = executor_client([[200, {}, {
      "tasks" => [
        ROW.reject { |k, _| k == "addressed_to" },
        ROW.merge("addressed_to" => { "role" => "runner" }),
        ROW.merge("addressed_to" => {}),
      ],
      "pagination" => { "next_after" => nil },
    }]]).inbox.list

    unaddressed, by_role, emptied = page.items
    assert_nil unaddressed.addressed_to
    assert_equal "runner", by_role.addressed_to.role
    assert_nil by_role.addressed_to.executor_public_id
    assert_nil emptied.addressed_to
  end

  # The task read's `addressed_to` carries the addressee's presence and
  # contact sample; the inbox row never does, and both parse
  # through the one reader.
  def test_an_addressed_to_carrying_presence_parses_and_one_without_stays_nil_there
    page = executor_client([[200, {}, {
      "tasks" => [
        ROW.merge("addressed_to" => { "role" => "runner", "executor_public_id" => "0199-r",
                                      "presence" => "offline", "last_seen_at" => "2026-09-07T00:00:00Z" }),
        ROW,
      ],
      "pagination" => { "next_after" => nil },
    }]]).inbox.list

    with_presence, without = page.items
    assert_equal "offline", with_presence.addressed_to.presence
    assert_equal "2026-09-07T00:00:00Z", with_presence.addressed_to.last_seen_at
    assert_nil without.addressed_to.presence
    assert_nil without.addressed_to.last_seen_at
    assert_equal "runner", CybrosAgent::Api::AddressedTo.new(role: "runner").role,
      "additive on the constructor: the two presence members default to nil"
  end

  # EVERY ROW NAMES ITS KIND: the kernel writes it on each row it lists and
  # each row a claim or an extension answers with, so a row without one
  # breaks the contract. Reading it as nil would hand a runner a row it
  # has to guess about, and a guess decides whether it runs a tool.
  def test_a_row_without_its_kind_is_malformed
    context = executor_client([[200, {}, { "tasks" => [ROW.except("kind")],
                                           "pagination" => { "next_after" => nil } }]]).inbox

    assert_raises(CybrosAgent::Api::MalformedResponse) { context.list }
  end

  # The constructor mirrors the wire: a consumer that builds a row itself
  # (a runner's test double) names the kind the kernel always writes, and
  # may leave out the members the kernel compacts away, which read as nil.
  def test_the_constructor_requires_the_kind_and_defaults_the_compacted_members
    members = { run_public_id: RUN_ID, workspace_public_id: WORKSPACE_ID,
                task_key: "r1t0", tool_name: "read_file",
                tool_input: {}, tool_call_id: nil, started_at: nil, deadline_at: nil, timeout_ms: nil,
                claimed: false }
    task = CybrosAgent::Api::InboxTask.new(kind: "tool_call", **members)

    assert_equal "tool_call", task.kind
    assert_nil task.addressed_to
    assert_nil task.scope, "a row built without the stamp carries none"
    assert_nil task.conversation_public_id
    assert_equal "r1t0", task.task_key
    assert_raises(ArgumentError) { CybrosAgent::Api::InboxTask.new(**members) }
    assert_raises(ArgumentError) do
      CybrosAgent::Api::InboxTask.new(kind: "tool_call", **members.except(:workspace_public_id))
    end
  end

  def test_workspace_follows_each_task_instead_of_the_consumers_default_or_parent
    other_workspace = "019f0000-0000-7000-8000-000000000102"
    child = ROW.merge("conversation_public_id" => "child", "parent_public_id" => "parent",
      "workspace_public_id" => other_workspace)
    context = executor_client([[200, {}, {
      "tasks" => [ROW, child], "pagination" => { "next_after" => nil },
    }], [200, {}, { "task" => child, "claim" => { "claim_token" => "child-claim" } }]])

    standalone, spawned = context.inbox.list.items
    assert_equal WORKSPACE_ID, standalone.workspace_public_id
    assert_nil standalone.conversation_public_id
    assert_equal other_workspace, spawned.workspace_public_id
    assert_equal other_workspace, spawned.to_h.fetch(:workspace_public_id)
    claimed = context.inbox_task(run_public_id: RUN_ID, task_key: "r1t0").claim
    assert_equal other_workspace, claimed.task.workspace_public_id
    assert_equal 2, @transport.requests.length, "no ownership lookup is needed"
  end

  def test_missing_null_or_empty_workspace_is_malformed_on_inbox_and_claim
    [ROW.except("workspace_public_id"), ROW.merge("workspace_public_id" => nil),
      ROW.merge("workspace_public_id" => "")].each do |row|
      context = executor_client([[200, {}, {
        "tasks" => [row], "pagination" => { "next_after" => nil },
      }], [200, {}, { "task" => row, "claim" => { "claim_token" => "claim" } }]])

      assert_raises(CybrosAgent::Api::MalformedResponse) { context.inbox.list }
      assert_raises(CybrosAgent::Api::MalformedResponse) do
        context.inbox_task(run_public_id: RUN_ID, task_key: "r1t0").claim
      end
    end
  end

  # EVERY ROW NAMES ITS CONVERSATION (the process lifecycle follows the conversation): the run's conversation, or an explicit
  # null for a standalone run, which reads as nil.
  def test_every_row_names_its_conversation_null_for_a_standalone_run
    conversation = "019f0000-0000-7000-8000-000000000301"
    page = executor_client([[200, {}, {
      "tasks" => [ROW.merge("conversation_public_id" => conversation), ROW.merge("conversation_public_id" => nil)],
      "pagination" => { "next_after" => nil },
    }]]).inbox.list

    backed, standalone = page.items
    assert_equal conversation, backed.conversation_public_id
    assert_nil standalone.conversation_public_id
  end

  # STATED, NEVER COMPACTED: the kernel merges both conversation members
  # after its compaction, so a row missing either one breaks the contract.
  # Reading the gap as nil would hand a runner a standalone run's row for
  # a conversation's call, and the runner owns what it starts by that key.
  def test_a_row_without_its_conversation_or_its_parent_is_malformed
    %w[conversation_public_id parent_public_id].each do |member|
      context = executor_client([[200, {}, { "tasks" => [ROW.except(member)],
                                             "pagination" => { "next_after" => nil } }]]).inbox

      assert_raises(CybrosAgent::Api::MalformedResponse, member) { context.list }
    end
  end

  # THE PARENT ON EVERY ROW: a spawned child's row names its PARENT conversation's
  # public id beside its own — the kernel's snapshot, the same kind of
  # fact as `conversation_public_id` — so a runner elsewhere resolves a
  # child's environment by its parent's received binding; an explicit
  # null on a root conversation's row and on a standalone run's, nil
  # here either way.
  def test_every_row_names_its_parent_null_for_a_root_conversation_and_a_standalone_run
    parent = "019f0000-0000-7000-8000-000000000302"
    child = "019f0000-0000-7000-8000-000000000303"
    page = executor_client([[200, {}, {
      "tasks" => [
        ROW.merge("conversation_public_id" => child, "parent_public_id" => parent),
        ROW.merge("conversation_public_id" => child, "parent_public_id" => nil),
        ROW.merge("conversation_public_id" => nil, "parent_public_id" => nil),
      ],
      "pagination" => { "next_after" => nil },
    }]]).inbox.list

    spawned, root, standalone = page.items
    assert_equal parent, spawned.parent_public_id
    assert_equal child, spawned.conversation_public_id, "the row stays the child's own"
    assert_nil root.parent_public_id
    assert_nil standalone.parent_public_id
    assert_nil CybrosAgent::Api::InboxTask.new(
      kind: "tool_call", run_public_id: RUN_ID, workspace_public_id: WORKSPACE_ID,
      task_key: "r1t0", tool_name: "read_file",
      tool_input: {}, tool_call_id: nil, started_at: nil, deadline_at: nil, timeout_ms: nil, claimed: false
    ).parent_public_id, "the constructor defaults it to nil"
    assert_equal parent, spawned.to_h.fetch(:parent_public_id), "and the projection's hash carries it"
  end

  # THE KERNEL'S SCOPE STAMP: present only on a row whose tool is
  # an overridden kernel name — the kernel stating whose row this is beside
  # `tool_input`, which passes through untouched. An opaque frozen map, not a
  # typed struct: the provider decides what it means. Absent on every other
  # row, and absent reads as nil, never as an empty map.
  def test_a_skill_row_carries_the_scope_stamp_as_a_frozen_map_and_every_other_row_none
    scope = { "workspace_public_id" => "019f0000-0000-7000-8000-000000000101",
              "conversation_public_id" => nil,
              "user_public_id" => "019f0000-0000-7000-8000-000000000201" }
    page = executor_client([[200, {}, {
      "tasks" => [
        ROW.merge("tool_name" => "skill", "tool_input" => { "name" => "commit-style" },
                  "scope" => scope,
                  "addressed_to" => { "role" => "tool_provider", "executor_public_id" => EXECUTOR_ID }),
        ROW,
      ],
      "pagination" => { "next_after" => nil },
    }]]).inbox.list

    stamped, plain = page.items
    assert_equal scope, stamped.scope
    assert_predicate stamped.scope, :frozen?
    assert_nil stamped.scope.fetch("conversation_public_id"), "a standalone run's null survives as nil"
    assert_raises(FrozenError) { stamped.scope["user_public_id"] = "other" }
    assert_equal({ "name" => "commit-style" }, stamped.tool_input)
    assert_nil plain.scope
    refute ROW.key?("scope"), "the runner row has no stamp to begin with"
  end

  def test_memory_scope_preserves_named_bindings_and_an_explicit_empty_scope
    binding = { "name" => "group", "scope" => "conversation", "access" => "read",
                "conversation_public_id" => "019f0000-0000-7000-8000-000000000801" }
    scopes = [{ "bindings" => [binding] }, { "bindings" => [] }]
    page = executor_client([[200, {}, {
      "tasks" => scopes.map { |scope| ROW.merge("tool_name" => "memory_read", "scope" => scope) },
      "pagination" => { "next_after" => nil },
    }]]).inbox.list

    assert_equal scopes, page.items.map(&:scope)
    assert_predicate page.items.first.scope.fetch("bindings"), :frozen?
    assert_predicate page.items.first.scope.fetch("bindings").first, :frozen?
    assert_raises(FrozenError) { page.items.first.scope.fetch("bindings").first["access"] = "read_write" }
    assert_empty page.items.last.scope.fetch("bindings")
  end

  # THE PARK'S BUDGET ON THE ROW: the number the kernel cut `deadline_at`
  # from, stated so a runner names the budget it was held to without a
  # clock of its own. An extension moves the deadline and never the
  # budget; a budget that is not an integer breaks the contract.
  def test_a_row_states_its_parks_budget_and_an_extension_keeps_it
    task = executor_client([[200, {}, { "tasks" => [ROW], "pagination" => { "next_after" => nil } }]])
      .inbox.list.items.first
    assert_equal 600_000, task.timeout_ms

    extended = inbox_task([[200, {}, {
      "task" => ROW.merge("claimed" => true, "deadline_at" => "2026-08-31T00:25:00Z"),
      "claim" => { "claim_token" => "tok-1", "deadline_at" => "2026-08-31T00:25:00Z" },
    }]]).extend(claim_token: "tok-1", timeout_ms: 900_000)
    assert_equal "2026-08-31T00:25:00Z", extended.task.deadline_at, "the clock moved"
    assert_equal 600_000, extended.task.timeout_ms, "the budget did not"

    context = executor_client([[200, {}, { "tasks" => [ROW.merge("timeout_ms" => "soon")],
                                           "pagination" => { "next_after" => nil } }]]).inbox
    assert_raises(CybrosAgent::Api::MalformedResponse) { context.list }
  end

  # CLAIMING IS ALSO THE FETCH: the grant answers with the executable row, so
  # a runner nudged with a task key goes straight here and never lists.
  def test_a_grant_answers_with_the_executable_row_and_the_token
    claimed = inbox_task([[200, {}, {
      "task" => ROW.merge("claimed" => true),
      "claim" => { "claim_token" => "tok-1", "deadline_at" => "2026-08-31T00:10:00Z" },
    }]]).claim

    assert_equal :post, request.fetch(:method)
    assert_equal "#{TASK_PATH}/claim", request.fetch(:path)
    assert_equal "sk-transport", request.fetch(:credential)
    assert_equal "tok-1", claimed.claim_token
    assert_equal({ "path" => "a.rb" }, claimed.task.tool_input,
      "the grant carries what to RUN, not merely what the task IS")
    assert_equal "tool_call", claimed.task.kind
    assert_equal "2026-08-31T00:10:00Z", claimed.deadline_at
  end

  # THE CLAIMANT'S EXTENSION (executor.md "Extend"): the one clock moved
  # by a bounded budget from now, answered in the claim's own shape with
  # the token unrotated. A malformed budget never leaves the process.
  def test_the_claimant_extends_its_own_deadline_and_reads_the_claim_shape_back
    extended = inbox_task([[200, {}, {
      "task" => ROW.merge("claimed" => true, "deadline_at" => "2026-08-31T00:25:00Z"),
      "claim" => { "claim_token" => "tok-1", "deadline_at" => "2026-08-31T00:25:00Z" },
    }]]).extend(claim_token: "tok-1", timeout_ms: 900_000)

    assert_equal :post, request.fetch(:method)
    assert_equal "#{TASK_PATH}/extend", request.fetch(:path)
    assert_equal({ "claim_token" => "tok-1", "timeout_ms" => 900_000 }, request.fetch(:body))
    assert_equal "tok-1", extended.claim_token, "nothing rotates"
    assert_equal "2026-08-31T00:25:00Z", extended.deadline_at
    assert_equal "2026-08-31T00:25:00Z", extended.task.deadline_at

    # The signature refuses a non-Integer and a missing token; the door
    # refuses a non-positive budget and an empty token before any request leaves.
    context = inbox_task([])
    assert_raises(ArgumentError) { context.extend(claim_token: "tok-1", timeout_ms: 0) }
    assert_raises(ArgumentError) { context.extend(claim_token: "", timeout_ms: 1000) }
    assert_empty @transport.requests
  end

  # ONE EPHEMERAL FRAME (executor.md "Progress"): one verb, the key inside
  # the frame, `202` whether broadcast or dropped, the fences as conflicts.
  def test_report_progress_posts_one_frame_and_reads_the_fences_as_conflicts
    frame = { "run_public_id" => RUN_ID, "task_key" => "r1t0", "claim_token" => "tok-1",
              "text_tail" => "3/9\n" }
    assert_nil executor_client([[202, {}, ""]]).report_progress(frame)

    assert_equal :post, request.fetch(:method)
    assert_equal "#{INBOX_PATH.delete_suffix("/inbox")}/progress", request.fetch(:path)
    assert_equal({ "frame" => frame }, request.fetch(:body), "the envelope is {frame}")
    assert_equal "sk-transport", request.fetch(:credential)

    %w[not_claimant not_bound].each do |code|
      client = executor_client([[409, {}, { "error" => { "code" => code, "message" => "Refused" } }]])
      error = assert_raises(CybrosAgent::Api::Conflict) { client.report_progress(frame) }
      assert_equal code, error.code
    end
    # The sig types the frame as a Hash, so under the type hook the call is
    # a TypeError before Ruby's own refusal (workspaces_test's precedent).
    return if ENV["RBS_TEST_TARGET"]

    assert_raises(ArgumentError) { executor_client([]).report_progress("nope") }
    assert_empty @transport.requests
  end

  def test_a_refused_extension_is_the_doors_typed_conflict
    context = inbox_task([[409, {}, { "error" => { "code" => "extension_too_long", "message" => "Refused" } }]])
    error = assert_raises(CybrosAgent::Api::Conflict) { context.extend(claim_token: "tok-1", timeout_ms: 1) }
    assert_equal "extension_too_long", error.code
  end

  # THE TWO AXES. `is_error` is DATA — the tool ran and errored, and the model
  # reads that and self-corrects. `outcome` is CONTROL — "failed" says it
  # could not run at all and takes the task's own failure policy.
  def test_a_tool_that_ran_and_errored_is_completed_with_is_error
    inbox_task([[200, {}, { "task" => { "key" => "r1t0" } }]])
      .commit(claim_token: "tok-1", content: "No such file", is_error: true,
        outcome: "completed", title: "read_file a.rb")

    assert_equal :post, request.fetch(:method)
    assert_equal "#{TASK_PATH}/commit", request.fetch(:path)
    assert_equal({ "claim_token" => "tok-1", "content" => "No such file",
                   "is_error" => true, "outcome" => "completed",
                   "title" => "read_file a.rb" }, request.fetch(:body),
      "the door reads the envelope flat; a nesting key sends claim_token nowhere")
  end

  # Omission is not falsity: an unsent field is absent from the wire, so the
  # server applies its own default rather than the client's guess.
  def test_an_unsent_field_never_reaches_the_wire
    inbox_task([[200, {}, { "task" => { "key" => "r1t0" } }]])
      .commit(claim_token: "tok-1", content: "done")

    assert_equal({ "claim_token" => "tok-1", "content" => "done" }, request.fetch(:body))
  end

  # AN ASK'S COMMIT CARRIES NO TOKEN: the row names its addressee and that
  # is the door. A nil token sends no field; a non-string is still
  # the caller's bug, refused before any request leaves.
  def test_a_nil_claim_token_is_an_asks_commit_and_sends_none
    inbox_task([[200, {}, { "task" => { "key" => "r1t0" } }]])
      .commit(claim_token: nil, content: "Postgres")

    assert_equal :post, request.fetch(:method)
    assert_equal "#{TASK_PATH}/commit", request.fetch(:path)
    assert_equal({ "content" => "Postgres" }, request.fetch(:body),
      "the address is the door: no claim_token key on the wire, not even a null")
  end

  def test_an_empty_claim_token_is_the_callers_bug_not_a_server_refusal
    context = inbox_task([])
    assert_raises(ArgumentError) { context.commit(claim_token: "") }
    assert_empty @transport.requests
  end

  # Ids are percent-encoded into one opaque path segment: a task key cannot
  # re-address another route.
  def test_identifiers_cannot_escape_their_path_segment
    executor_client([[200, {}, {
      "task" => ROW, "claim" => { "claim_token" => "t" },
    }]]).inbox_task(run_public_id: RUN_ID, task_key: "a/../../b").claim

    assert_includes request.fetch(:path), "#{INBOX_PATH}/#{RUN_ID}/a%2F..%2F..%2Fb/claim"
  end

  def test_a_2xx_that_breaks_the_contract_is_malformed_here
    context = executor_client([[200, {}, { "tasks" => [{ "task_key" => "r1t0" }],
                                           "pagination" => { "next_after" => nil } }]]).inbox
    assert_raises(CybrosAgent::Api::MalformedResponse) { context.list }
  end
end
