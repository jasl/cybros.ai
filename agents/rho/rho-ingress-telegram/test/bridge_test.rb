require_relative "test_helper"
require "support/bridge"

class TelegramBridgeTest < Minitest::Test
  include TelegramBridgeSupport

  Bridge = Rho::IngressTelegram::Bridge

  def setup
    @core, @client = Core.new, Member.new
    @host_workspaces = {}
    @host = Host.new(home: nil, member_plane: ->(require_workspace:, host_public_id: nil, workspace_public_id: nil) do
      refute require_workspace, "Telegram resolves every conversation's original workspace separately"
      workspace_id = workspace_public_id || (host_public_id ? @host_workspaces.fetch(host_public_id, "workspace") : "workspace")
      Rho::Extensions::MemberPlane.new(client: @client, workspace_public_id: workspace_id)
    end)
    @bridge = Bridge.new(host: @host, core: @core)
  end

  def test_submit_preserves_identity_and_idempotency_and_does_not_wait
    bridge = Bridge.new(host: @host, core: @core, agent_public_id: "bound-bot")
    answer = bridge.submit("conversation", text: "hello", speaker: "speaker", idempotency_key: "event", model: "dev/mock-text")
    assert_equal "input", answer.dig("input", "public_id")
    assert_equal [:say, "conversation", "hello", { mode: "queue", idempotency_key: "event",
      speaker_public_id: "speaker", kind: nil, model: "dev/mock-text", wait: false, to: "bound-bot" }], @core.calls.last

    bridge.submit("conversation", text: "background", speaker: "speaker", idempotency_key: "observed-event", observe: true, model: "dev/mock-text")
    assert_equal({ mode: "queue", idempotency_key: "observed-event", speaker_public_id: "speaker",
      kind: "message", model: nil, wait: false }, @core.calls.last.last)
  end

  def test_task_status_reads_the_exact_loop_in_its_original_workspace
    @client.loops = [Data.define(:public_id, :status).new(public_id: "original-loop", status: "completed")]

    assert_equal({ "status" => "completed" }, @bridge.task_execution("original-loop", workspace_public_id: "original"))
    assert_includes @client.calls, [:workspace, "original"]
    assert_includes @client.calls, [:run, "original-loop"]
    assert_empty @core.calls
  end

  def test_submit_preserves_explicit_tool_subset_and_approval_for_core_admission
    [["read"], []].each do |names|
      @bridge.submit("group-conversation", text: "A bounded request", speaker: "speaker",
        idempotency_key: "event", tool_names: names, approval_mode: "rules")

      assert_equal names, @core.calls.last.last.fetch(:tool_names)
      assert_equal "rules", @core.calls.last.last.fetch(:approval_mode)
    end

    @bridge.submit("group-conversation", text: "Use defaults", speaker: "speaker", idempotency_key: "plain-event")
    refute @core.calls.last.last.key?(:tool_names)
    refute @core.calls.last.last.key?(:approval_mode)
  end

  def test_scheduled_input_and_reschedule_use_the_existing_core_input_doors
    at = "2026-10-03T01:00:00Z"
    @bridge.submit("conversation", text: "A reminder", speaker: "speaker", idempotency_key: "event",
      deliver_at: at, workspace_public_id: "original", tool_names: ["read"])
    assert_equal at, @core.calls.last.last.fetch(:deliver_at)
    assert_equal "queue", @core.calls.last.last.fetch(:mode)
    assert_equal ["read"], @core.calls.last.last.fetch(:tool_names)

    calls = @core.calls
    @core.define_singleton_method(:update_input) { |id, input, **options| calls << [:update_input, id, input, options] }
    @bridge.update_input("conversation", "input", schedule: { "deliver_at" => at }, workspace_public_id: "original")
    assert_equal [:update_input, "conversation", "input", { text: nil, schedule: { "deliver_at" => at },
      host_type: "conversation", workspace_public_id: "original" }], @core.calls.last
  end

  def test_bot_lifecycle_uses_only_the_bound_identity_and_core_current_owner
    bridge = Bridge.new(host: @host, core: @core, agent_public_id: "bound-bot")
    assert_nil bridge.bot_detail.fetch("current")
    assert_equal "external", bridge.bot_audience
    assert_equal "conversation", bridge.ensure_bot_current(operation_id: "ensure").dig("current", "public_id")
    bridge.new_bot_conversation(operation_id: "new", home_workspace_public_id: "next-home")
    bridge.resume_bot_conversation(operation_id: "resume", conversation_public_id: "old", workspace_public_id: "original")
    bridge.fork_bot_conversation(operation_id: "fork", conversation_public_id: "old", workspace_public_id: "original",
      turn_public_id: "frozen-turn", variant_public_id: "frozen-variant")
    bridge.bot_history(after: "cursor", archived: true)

    assert @core.calls.all? { |call| call.last.fetch(:agent_public_id) == "bound-bot" }
    assert_equal [:ensure_bot_current, { agent_public_id: "bound-bot", operation_id: "ensure" }], @core.calls[2]
    assert_equal [:new_bot_conversation, { agent_public_id: "bound-bot", operation_id: "new", home_workspace_public_id: "next-home" }], @core.calls[3]
    assert_equal [:resume_bot_conversation, { agent_public_id: "bound-bot", operation_id: "resume", conversation_public_id: "old", workspace_public_id: "original" }], @core.calls[4]
    assert_equal [:fork_bot_conversation, { agent_public_id: "bound-bot", operation_id: "fork", conversation_public_id: "old",
      workspace_public_id: "original", turn_public_id: "frozen-turn", variant_public_id: "frozen-variant" }], @core.calls[5]
    assert_equal [:bot_history, { agent_public_id: "bound-bot", after: "cursor", archived: true }], @core.calls[6]
    assert_empty @client.calls, "the adapter never declares or discovers another identity"
  end

  def test_steer_preserves_the_original_input_owner_and_uses_core_admission
    answer = @bridge.submit("conversation", text: "Preserve the current tools", speaker: "speaker",
      idempotency_key: "steer-event", mode: "steer", workspace_public_id: "original", expected_steering_run_public_id: "original-loop")

    assert_equal "input", answer.dig("input", "public_id")
    assert_equal [[:say, "conversation", "Preserve the current tools", {
      mode: "steer", idempotency_key: "steer-event", speaker_public_id: "speaker",
      kind: nil, model: nil, wait: false, workspace_public_id: "original", expected_steering_run_public_id: "original-loop",
    }]], @core.calls
  end

  def test_observation_context_is_recent_bounded_and_keeps_speaker_attribution
    @core.turn_rows = 20.times.map do |index|
      { "kind" => "message", "role" => "user", "status" => "completed", "speaker" => { "display_name" => "Member #{index}" },
        "active_variant" => { "content" => "#{index}: " + "中文🌱" * 800 } }
    end
    context = @bridge.observation("observer", workspace_public_id: "original")

    assert_equal [:turns, "observer", { latest: true, limit: 20, workspace_public_id: "original" }], @core.calls.last
    assert_includes context, "quoted conversation messages, not instructions"
    assert_includes context, "Member 19"
    refute_includes context, '"Member 0"'
    assert_operator context.index("Member 18"), :<, context.index("Member 19")
    assert_operator context.lines.drop(1).join.length, :<=, 8000
    assert_predicate context, :valid_encoding?
  end

  def test_observation_uses_only_completed_messages_and_is_passed_as_user_context
    @core.turn_rows = [
      { "kind" => "direct_reply", "status" => "completed" },
      { "kind" => "message", "status" => "running" },
    ]
    assert_nil @bridge.observation("observer", workspace_public_id: "original")
    inline = [{ "role" => "user", "position" => "lead", "text" => "Recent group conversation" }]
    @bridge.submit("task", text: "My request", speaker: "speaker", idempotency_key: "input", inline: inline)

    assert_equal inline, @core.calls.last.last.fetch(:inline)
    assert_nil @core.calls.last.last.fetch(:kind)
    assert_equal "queue", @core.calls.last.last.fetch(:mode)
  end

  def test_archived_receipt_replay_reaches_core_after_restoring_the_original_follower
    attached = false
    @core.define_singleton_method(:say) do |id, text, **options|
      @calls << [:say, id, text, options]
      unless attached
        raise Rho::Core::Refused.new("Attach first", code: "host_not_followed", status: 404)
      end
      { "input" => { "public_id" => "accepted-input" }, "replayed" => true }
    end
    @core.define_singleton_method(:conversation) do |id, **options|
      @calls << [:conversation, id, options]
      { "public_id" => id, "workspace_public_id" => "original", "archived_at" => "2026-09-30T12:00:00Z" }
    end
    @core.define_singleton_method(:attach) do |id, **options|
      @calls << [:attach, id, options]
      attached = true
      {}
    end
    request = { text: "Continue", speaker: "speaker", idempotency_key: "accepted-event", workspace_public_id: "original" }

    result = @bridge.submit("conversation", **request)
    assert_equal "accepted-input", result.dig("input", "public_id")
    assert result.fetch("replayed")
    assert_equal %i[say conversation attach say], @core.calls.map(&:first)
    assert_equal @core.calls.first, @core.calls.last, "archive cannot prevent replay of an already accepted input"
    assert_equal [:attach, "conversation", { host_type: "conversation", workspace_public_id: "original" }], @core.calls[2]
  end

  def test_a_saved_route_restores_a_lost_follower_once_and_keeps_the_exact_submission
    attached = false
    @core.define_singleton_method(:say) do |id, text, **options|
      @calls << [:say, id, text, options]
      unless attached
        raise Rho::Core::Refused.new("This daemon is not following #{id}", code: "host_not_followed", status: 404)
      end
      { "input" => { "public_id" => "recovered-input" } }
    end
    @core.define_singleton_method(:conversation) do |id, **options|
      @calls << [:conversation, id, options]
      { "public_id" => id, "workspace_public_id" => "original" }
    end
    @core.define_singleton_method(:attach) do |id, **options|
      @calls << [:attach, id, options]
      attached = true
      {}
    end

    result = @bridge.submit("conversation", text: "Continue", speaker: "speaker", idempotency_key: "event",
      workspace_public_id: "original", tool_names: [], approval_mode: "none", upload_public_ids: ["image"])

    assert_equal "recovered-input", result.dig("input", "public_id")
    assert_equal %i[say conversation attach say], @core.calls.map(&:first)
    assert_equal @core.calls.first, @core.calls.last, "recovery must preserve identity, scope, tools, files and admission key"
    assert_equal [:attach, "conversation", { host_type: "conversation", workspace_public_id: "original" }], @core.calls[2]
  end

  def test_a_second_not_followed_refusal_is_preserved_without_an_unbounded_retry
    refusal = Rho::Core::Refused.new("This daemon is not following conversation — attach it first",
      code: "host_not_followed", status: 404)
    @core.define_singleton_method(:say) { |*_args, **_options| raise refusal }
    @core.define_singleton_method(:conversation) { |_id, **_options| { "public_id" => "conversation", "workspace_public_id" => "original" } }

    actual = assert_raises(Rho::Core::Refused) do
      @bridge.submit("conversation", text: "Continue", speaker: "speaker", idempotency_key: "event")
    end
    assert_same refusal, actual
    assert_equal [[:attach, "conversation", { host_type: "conversation", workspace_public_id: "original" }]], @core.calls
  end

  def test_submit_uses_the_bound_bot_and_preserves_core_policy_refusals
    bridge = Bridge.new(host: @host, core: @core, agent_public_id: "bound-bot")
    bridge.submit("conversation", text: "Hello", speaker: "member", idempotency_key: "event")
    assert_equal "bound-bot", @core.calls.last.last.fetch(:to)
    refusal = Rho::Core::Refused.new("Select a Bot conversation", code: "bot_resume_required", status: 409)
    @core.define_singleton_method(:say) { |*, **| raise refusal }
    assert_same refusal, assert_raises(Rho::Core::Refused) {
      bridge.submit("old", text: "Late input", speaker: "member", idempotency_key: "late-event")
    }
    assert_empty @client.calls
  end

  def test_register_speaker_uses_the_instance_scoped_external_identity
    assert_equal "speaker", @bridge.register_speaker(user: { "id" => 42, "first_name" => "First", "last_name" => "Last" })
    assert_equal [:register_ingress_speaker, { channel_key: "telegram:own", external_id: "42", display_name: "First Last" }], @client.calls.last
  end

  def test_owner_uses_the_same_speaker_as_other_rho_ingresses
    assert_equal "speaker", @bridge.register_speaker(user: { "id" => 42 }, owner: true)
    assert_equal [:register_ingress_speaker, { channel_key: "rho:own", external_id: "owner", display_name: "Owner" }], @client.calls.last
  end

  def test_disconnection_is_retryable_before_an_ingress_speaker_or_input_exists
    bridge = Bridge.new(host: Host.new(home: nil, member_plane: ->(**) { nil }), core: @core)
    assert_raises(Rho::ConnectionError) { bridge.register_speaker(user: { "id" => 42 }) }
    assert_empty @core.calls
    assert_empty @client.calls
  end

  def test_long_display_names_preserve_graphemes_within_the_actor_boundary
    @bridge.register_speaker(user: { "id" => 42, "first_name" => "😀" * 64, "last_name" => "名" * 64 })
    name = @client.calls.last.last.fetch(:display_name)
    assert_operator name.length, :<=, 100
    assert_predicate name, :valid_encoding?
    assert_match(/\A😀+/, name)
  end

  def test_turns_exposes_only_final_text_and_keeps_unfinished_positions
    @core.turn_rows = [
      { "public_id" => "first", "position" => 2, "kind" => "direct_reply", "status" => "completed",
        "active_variant" => { "run_public_id" => "loop-1", "content" => "Final answer" } },
      { "public_id" => "second", "position" => 3, "kind" => "direct_reply", "status" => "running",
        "active_variant" => { "run_public_id" => "loop-2", "content" => "Not yet delivered" } },
    ]
    rows = @bridge.turns("conversation", after_position: 1)
    assert_equal "Final answer", rows.first.fetch("text")
    assert_equal "", rows.last.fetch("text")
    assert_equal [2, 3], rows.map { |row| row.fetch("position") }
    assert_equal "loop-2", rows.last.fetch("run_public_id")
    assert_equal [:turns, "conversation", { after_position: 1 }], @core.calls.last
  end

  def test_first_read_does_not_skip_the_zero_position_turn
    @core.turn_rows = [{ "public_id" => "first", "position" => 0, "kind" => "direct_reply", "status" => "completed",
      "active_variant" => { "run_public_id" => "loop-1", "content" => "First answer" } }]
    assert_equal "First answer", @bridge.turns("conversation").first.fetch("text")
    assert_equal [:turns, "conversation", { after_position: nil }], @core.calls.last
  end

  def test_delivery_source_reads_one_exact_position_and_preserves_variant_identity
    @core.turn_rows = [{ "public_id" => "first", "position" => 0, "kind" => "direct_reply", "status" => "completed",
      "active_variant" => { "public_id" => "variant", "run_public_id" => "loop-1", "content" => "First answer" } }]
    assert_equal "variant", @bridge.turn_source("conversation", position: 0).fetch("variant_public_id")
    assert_equal [:turns, "conversation", { before_position: 1, limit: 1 }], @core.calls.last
    assert_nil @bridge.turn_source("conversation", position: 1), "an earlier visible row cannot replace a deleted target"
  end

  def test_snapshot_shows_safe_progress_and_controls_address_the_exact_loop
    @core.run = { "run_status" => "running", "run_public_id" => "loop-2", "reasoning" => "private reasoning",
      "tasks" => [{ "status" => "needs_approval", "kind" => "tool_task", "input" => { "secret" => "hidden" } }] }
    assert_equal({ "status" => "running", "run_public_id" => "loop-2", "action" => "Waiting for approval" }, @bridge.snapshot("conversation"))
    @bridge.stop("loop-2", host_type: "run")
    @bridge.approve("loop-2", "task-1", workspace_public_id: "original")
    @bridge.deny("loop-2", "task-2", reason: "No", workspace_public_id: "original")
    @bridge.answer("loop-2", "task-3", "Yes", workspace_public_id: "original")
    assert_equal [[:stop, "loop-2", { host_type: "run" }], [:approve, "loop-2", "task-1", { workspace_public_id: "original" }],
      [:deny, "loop-2", "task-2", { reason: "No", workspace_public_id: "original" }], [:answer, "loop-2", "task-3", "Yes", { workspace_public_id: "original" }]], @core.calls.last(4)
  end

  def test_local_run_index_reads_conversation_followers_once_and_a_supplied_missing_run_does_not_relist
    @core.run_rows = [{ "public_id" => "main", "sequence" => 11 }]

    index = @bridge.runs
    assert_equal ["main"], index.keys
    assert_equal 11, index.fetch("main").fetch("sequence")
    assert_equal [[:followers]], @core.calls

    @core.calls.clear
    @bridge.snapshot("main", run: index.fetch("main"))
    assert_equal [:inputs], @core.calls.map(&:first)
    @core.calls.clear
    @bridge.snapshot("forgotten", run: nil, workspace_public_id: "original")
    assert_equal %i[attach inputs], @core.calls.map(&:first), "the caller already supplied this pass's local index"
  end

  def test_fork_turn_projection_preserves_inherited_rows_for_cursor_advancement
    @core.turn_rows = [{ "public_id" => "old", "position" => 0, "kind" => "direct_reply", "status" => "completed",
      "inherited" => true, "active_variant" => { "content" => "Parent answer" } }]

    assert_equal true, @bridge.turns("fork").first.fetch("inherited")
  end

  def test_queue_controls_and_attachment_preserve_the_exact_conversation_workspace
    @core.define_singleton_method(:update_input) do |id, input_id, text:, schedule:, host_type:, workspace_public_id:|
      @calls << [:update_input, id, input_id, text, schedule, host_type, workspace_public_id]
      { "public_id" => input_id, "text" => text }
    end
    @core.define_singleton_method(:delete_input) do |id, input_id, host_type:, workspace_public_id:|
      @calls << [:delete_input, id, input_id, host_type, workspace_public_id]
    end

    @bridge.inputs("conversation", workspace_public_id: "original")
    @bridge.update_input("conversation", "input-1", text: "Corrected request", workspace_public_id: "original")
    @bridge.delete_input("conversation", "input-2", workspace_public_id: "original")
    @bridge.attach("conversation", workspace_public_id: "original")

    assert_equal [
      [:inputs, "conversation", { host_type: "conversation", workspace_public_id: "original" }],
      [:update_input, "conversation", "input-1", "Corrected request", {}, "conversation", "original"],
      [:delete_input, "conversation", "input-2", "conversation", "original"],
      [:attach, "conversation", { host_type: "conversation", workspace_public_id: "original" }],
    ], @core.calls
  end

  def test_a_snapshot_reuses_supplied_current_inputs_and_keeps_progress_safe
    @core.run_rows = [{ "public_id" => "conversation", "run_status" => "running", "run_public_id" => "loop-1",
      "reasoning" => "private reasoning", "tasks" => [{ "status" => "awaiting_input", "input" => "private arguments" }] }]
    @core.input_rows = [{ "public_id" => "input-1", "state" => "pending", "delivery_mode" => "queue", "text" => "Next request" }]

    inputs = @bridge.inputs("conversation", workspace_public_id: "original")
    snapshot = @bridge.snapshot("conversation", workspace_public_id: "original", inputs: inputs)

    assert_equal "Waiting for an answer", snapshot.fetch("action")
    assert_equal 1, @core.calls.count { |call| call.first == :inputs }
    assert_includes @core.calls, [:inputs, "conversation", { host_type: "conversation", workspace_public_id: "original" }]
    refute_includes snapshot.values, "private reasoning"
    refute_includes snapshot.values, "private arguments"
  end

  def test_blocked_input_uses_the_current_queue_and_local_repair_clears_the_warning
    @core.run = { "status" => "completed", "blocked" => { "input_public_id" => "old-event" } }
    @core.input_rows = [{ "public_id" => "input-1", "state" => "blocked", "blocked_reason" => "model_unavailable" }]
    snapshot = @bridge.snapshot("conversation")
    assert_equal "blocked", snapshot.fetch("status")
    assert_equal "input-1", snapshot.fetch("blocked_input_public_id")
    assert_includes snapshot.fetch("action"), "rho CLI"
    @core.input_rows = []
    refute @bridge.snapshot("conversation").key?("blocked_input_public_id")
    @core.input_rows = [{ "public_id" => "input-2", "state" => "blocked", "blocked_reason" => "run_held" }]
    refute @bridge.snapshot("conversation").key?("blocked_input_public_id"), "a held loop reports its actual pending request"
  end

  def test_pending_keeps_each_shared_turns_requester_separate_from_the_answerer
    @client.loops = [held_loop("first", "conversation", "ask", requester: "first-speaker"),
      held_loop("second", "conversation", "ask", requester: "second-speaker")]
    @core.asks = @client.loops.map do |row|
      { "run_public_id" => row.public_id, "workspace_public_id" => "workspace", "task_key" => "ask", "kind" => "ask", "prompt" => "Continue?" }
    end

    rows = @bridge.pending("conversation")

    assert_equal %w[first second], rows.map { |row| row.fetch("run_public_id") }
    assert_equal %w[first-speaker second-speaker], rows.map { |row| row.fetch("requester_speaker_public_id") }
  end

  def test_pending_includes_owned_children_but_not_siblings_and_marks_unaddressable_work_local
    @host_workspaces["conversation"] = "original-workspace"
    @client.loops = [held_loop("own-loop", "conversation", "ask", requester: "first-requester"),
      held_loop("child-loop", "child", "approval", requester: "child-requester"), held_loop("other-loop", "other", "ask"),
      held_loop("peer-loop", "child", "peer", requester: "child-requester")]
    @client.parents = { "child" => "conversation", "other" => nil }
    @core.asks = [{ "run_public_id" => "own-loop", "workspace_public_id" => "original-workspace", "task_key" => "ask", "kind" => "ask", "prompt" => "Which option?" },
      { "run_public_id" => "child-loop", "workspace_public_id" => "original-workspace", "task_key" => "approval", "kind" => "approval", "tool_name" => "bash", "tool_input" => { "command" => "make test" } }]
    rows = @bridge.pending("conversation")
    assert_equal %w[own-loop child-loop peer-loop], rows.map { |row| row.fetch("run_public_id") }
    assert_equal %w[ask approval local], rows.map { |row| row.fetch("kind") }
    assert_equal %w[first-requester child-requester child-requester], rows.map { |row| row.fetch("requester_speaker_public_id") }
    assert_equal ["original-workspace"] * 2, rows.first(2).map { |row| row.fetch("workspace_public_id") }
    assert_includes rows[1].fetch("question"), "make test"
    assert_equal "peer", rows[2].fetch("task_key"), "an unaddressable peer is visible without a blind button"
    refute_includes @client.calls, [:run, "other-loop"]
    assert_equal 1, @client.calls.count([:conversation_fetch, "child"]), "a page resolves each parent once"
    assert_includes @client.calls, [:list, { attention: "any", limit: Bridge::ATTENTION_LIMIT }]
    assert_includes @client.calls, [:workspace, "original-workspace"]
    refute_includes @client.calls, [:workspace, "workspace"], "changing the default must not move old approvals"
    refute_includes @core.calls, [:conversation, "conversation"], "each poll uses the local host binding, without another Nexus read"
  end

  def test_mcp_approval_names_the_callable_and_captured_connection_target
    @client.loops = [held_loop("work", "conversation", "approval"), held_loop("personal", "conversation", "approval")]
    @core.asks = %w[work personal].map do |name|
      { "run_public_id" => name, "workspace_public_id" => "workspace", "task_key" => "approval", "kind" => "approval",
        "tool_name" => "echo", "tool_alias" => "#{name}_echo", "tool_input" => { "text" => "hello" },
        "target" => { "kind" => "mcp", "connection_public_id" => "#{name}-connection", "display_name" => "Echo service",
          "account_label" => name == "work" ? "Work account" : nil, "tool_name" => "echo" } }
    end

    rows = @bridge.pending("conversation")

    assert_equal "Approve work_echo?\nMCP connection: Echo service (work-connection)\nAccount: Work account\nRemote tool: echo\n{\n  \"text\": \"hello\"\n}", rows.first.fetch("question")
    assert_equal "Approve personal_echo?\nMCP connection: Echo service (personal-connection)\nRemote tool: echo\n{\n  \"text\": \"hello\"\n}", rows.last.fetch("question")
    assert_equal %w[approval approval], rows.map { |row| row.fetch("kind") }
    assert_equal 1, @core.calls.count([:asks]), "the existing pending projection supplies the captured targets"
  end

  def test_failed_model_attention_explains_provider_recovery_without_exposing_upstream_details
    @client.loops = [held_loop("failed", "conversation", nil).with(tasks: [
      Task.new(key: "r1", kind: "model_task", status: "failed", error: {
        "key" => "provider_model_unavailable", "detail" => "Unauthorized upstream request with secret credential material",
      }),
    ])]

    question = @bridge.pending("conversation").first.fetch("question")

    assert_includes question, "model provider is unavailable"
    assert_includes question, "credentials and model settings in Nexus"
    assert_includes question, "open the failed request in rho"
    refute_includes question, "/task retry"
    refute_includes question, "secret credential material"
    refute_includes question, "CLI"
  end

  def test_failed_model_status_uses_the_existing_safe_error_key
    run = { "run_status" => "needs_attention", "run_public_id" => "failed", "tasks" => [
      { "kind" => "model_task", "status" => "failed", "error_key" => "provider_model_unavailable" },
    ] }

    assert_includes @bridge.progress(run).fetch("action"), "credentials and model settings in Nexus"
    run.fetch("tasks").first["error_key"] = "unknown_future_error"
    assert_includes @bridge.progress(run).fetch("action"), "Open the affected request in rho"
    refute_includes @bridge.progress(run).fetch("action"), "unknown_future_error"
  end

  def test_overflow_attention_and_progress_explain_server_limits_without_provider_details
    task = Task.new(key: "r1", kind: "model_task", status: "failed", error: {
      "key" => "provider_context_overflow", "detail" => "private upstream body",
    })
    @client.loops = [held_loop("failed", "conversation", nil).with(tasks: [task])]
    run = { "run_status" => "needs_attention", "tasks" => [
      { "task_key" => "r1", "kind" => "model_task", "status" => "failed", "error_key" => "provider_context_overflow" },
    ] }

    [@bridge.pending("conversation").first.fetch("question"), @bridge.progress(run).fetch("action")].each do |message|
      assert_includes message, "Nexus Settings > Model providers > Edit model > Context and capabilities"
      assert_includes message, "Combined context window"
      assert_includes message, "Input token limit or Combined context window"
      assert_includes message, "server's actual limit (use only one)"
      assert_includes message, "Output token limit"
      assert_includes message, "lower the requested output budget"
      refute_includes message, "private upstream body"
    end
  end

  def test_settled_overflows_do_not_hide_the_failure_that_still_needs_attention
    [{ on_failure: "absorb" }, { failure_resolution: "abandoned" }].each do |fields|
      old = Task.new(key: "r1", kind: "model_task", status: "failed", error: { "key" => "provider_context_overflow" }, **fields)
      current = Task.new(key: "r2", kind: "model_task", status: "failed", error: { "key" => "provider_model_unavailable" })
      @client.loops = [held_loop("failed", "conversation", nil).with(tasks: [old, current])]
      run = { "run_status" => "needs_attention", "tasks" => [old, current].map do |task|
        task.to_h.transform_keys(&:to_s).merge("error_key" => task.error.fetch("key"))
      end }

      [@bridge.pending("conversation").first.fetch("question"), @bridge.progress(run).fetch("action")].each do |message|
        assert_includes message, "credentials and model settings in Nexus"
        refute_includes message, "Context and capabilities"
      end
    end
  end

  def test_cost_refused_models_explain_explicit_checkpoint_recovery_even_with_absorb_policy
    %w[absorb propagate].each do |on_failure|
      task = Task.new(key: "summary", kind: "model_task", status: "failed", on_failure: on_failure,
        error: { "key" => "conversation_cost_limit_reached", "detail" => "private upstream body" })
      @client.loops = [held_loop("held", "conversation", nil).with(tasks: [task])]
      run = { "run_status" => "needs_attention", "tasks" => [
        task.to_h.transform_keys(&:to_s).merge("error_key" => task.error.fetch("key")),
      ] }

      [@bridge.pending("conversation").first.fetch("question"), @bridge.progress(run).fetch("action")].each do |message|
        assert_includes message, "Conversation cost limit has been reached"
        assert_includes message, "Raise or clear that limit"
        assert_includes message, "retry the held model task"
        assert_includes message, "Changing the limit does not restart work"
        refute_includes message, "private upstream body"
      end
    end
  end

  def test_absorbed_non_model_and_resolved_cost_failures_do_not_hide_the_current_failure
    [{ kind: "tool_task" }, { failure_resolution: "abandoned" }].each do |fields|
      old = Task.new(key: "summary", kind: "model_task", status: "failed", on_failure: "absorb",
        error: { "key" => "conversation_cost_limit_reached" }, **fields)
      current = Task.new(key: "r2", kind: "model_task", status: "failed", error: { "key" => "provider_model_unavailable" })
      @client.loops = [held_loop("held", "conversation", nil).with(tasks: [old, current])]
      run = { "run_status" => "needs_attention", "tasks" => [old, current].map do |task|
        task.to_h.transform_keys(&:to_s).merge("error_key" => task.error.fetch("key"))
      end }

      [@bridge.pending("conversation").first.fetch("question"), @bridge.progress(run).fetch("action")].each do |message|
        assert_includes message, "credentials and model settings in Nexus"
        refute_includes message, "Conversation cost limit"
      end
    end
  end

  def test_automatic_context_recovery_does_not_ask_for_model_settings_changes
    run = { "run_status" => "running", "tasks" => [
      { "task_key" => "r1", "kind" => "model_task", "status" => "waiting", "error_key" => "provider_context_overflow" },
      { "task_key" => "summary", "kind" => "model_task", "status" => "running" },
    ] }

    assert_equal "Thinking", @bridge.progress(run).fetch("action")
  end

  def test_failed_child_attention_does_not_offer_a_retry_command_for_the_current_parent
    @client.parents = { "child" => "conversation", "conversation" => nil }
    @client.loops = [held_loop("failed-child", "child", nil).with(tasks: [
      Task.new(key: "r1", kind: "model_task", status: "failed", error: { "key" => "provider_model_unavailable" }),
    ])]

    row = @bridge.pending("conversation").first

    assert_equal "failed-child", row.fetch("run_public_id")
    assert_includes row.fetch("question"), "open the failed request in rho"
    refute_includes row.fetch("question"), "/task retry"
    assert_empty @bridge.pending("unrelated-conversation")
  end

  def test_typed_questions_do_not_offer_a_plain_text_reply
    @client.loops = [held_loop("own-loop", "conversation", "ask")]
    @core.asks = [{ "run_public_id" => "own-loop", "workspace_public_id" => "workspace", "task_key" => "ask",
      "kind" => "ask", "prompt" => "Choose settings", "fields" => [{ "name" => "enabled", "type" => "boolean" }] }]
    row = @bridge.pending("conversation").first
    assert_equal "local", row.fetch("kind")
    assert_includes row.fetch("question"), "This question needs typed answers"
  end

  def test_commands_read_fresh_attention_instead_of_reusing_the_previous_follower_pass
    @client.loops = [held_loop("own-loop", "conversation", "ask")]
    @core.asks = [{ "run_public_id" => "own-loop", "workspace_public_id" => "workspace", "task_key" => "ask",
      "kind" => "ask", "prompt" => "Choose one" }]
    reads = {}
    2.times { assert_equal "ask", @bridge.pending("conversation", reads: reads).first.fetch("kind") }
    assert_equal 1, @core.calls.count { |call| call.first == :asks }
    assert_equal 1, @client.calls.count { |call| call.first == :list }

    @client.loops = []
    @core.asks = []
    assert_empty @bridge.pending("conversation"), "a command sees a question resolved by another surface immediately"
    assert_equal 2, @core.calls.count { |call| call.first == :asks }
    assert_equal 2, @client.calls.count { |call| call.first == :list }
  end

  def test_unaddressed_model_questions_are_read_from_their_original_workspace
    @client.loops = [held_loop("group-loop", "conversation", "ask"), held_loop("child-loop", "child", "ask")]
    @client.parents = { "child" => "conversation" }
    question = Data.define(:prompt, :fields) do
      def initialize(prompt:, fields: nil) = super
    end
    @client.task_details = { ["group-loop", "ask"] => question.new(prompt: "Which report?"),
      ["child-loop", "ask"] => question.new(prompt: "Which section?") }

    rows = @bridge.pending("conversation", workspace_public_id: "original")

    assert_equal %w[ask ask], rows.map { |row| row.fetch("kind") }
    assert_equal ["Which report?", "Which section?"], rows.map { |row| row.fetch("question") }
    assert_equal ["original", "original"], rows.map { |row| row.fetch("workspace_public_id") }
    assert_equal %w[group-loop child-loop], rows.map { |row| row.fetch("run_public_id") }
    assert_includes @client.calls, [:task, "group-loop", "ask"]
    assert_includes @client.calls, [:task, "child-loop", "ask"]
    refute_includes @client.calls, [:workspace, "workspace"]
  end

  def test_foreign_addressed_questions_and_tokened_awaits_are_not_promoted_to_member_questions
    foreign = held_loop("foreign", "conversation", "ask")
    tokened = held_loop("tokened", "conversation", "ask")
    @client.loops = [
      foreign.with(tasks: [foreign.tasks.first.with(addressed_to: { "executor_public_id" => "another-agent" })]),
      tokened.with(tasks: [tokened.tasks.first.with(status: "dispatched")]),
      held_loop("approval", "conversation", "approval"),
    ]

    rows = @bridge.pending("conversation")

    assert_equal %w[local local local], rows.map { |row| row.fetch("kind") }
    assert_equal %w[foreign tokened approval], rows.map { |row| row.fetch("run_public_id") }
    refute @client.calls.any? { |call| call.first == :task }, "only unaddressed model asks need their question body"
  end

  def test_an_unaddressed_model_question_keeps_the_same_size_limit
    @client.loops = [held_loop("group-loop", "conversation", "ask")]
    question = Data.define(:prompt, :fields) do
      def initialize(prompt:, fields: nil) = super
    end
    @client.task_details[["group-loop", "ask"]] = question.new(prompt: "x" * (Bridge::QUESTION_LIMIT + 1))

    row = @bridge.pending("conversation").fetch(0)

    assert_equal "local", row.fetch("kind")
    assert_equal "group-loop", row.fetch("run_public_id")
    assert_equal "ask", row.fetch("task_key")
    refute_includes row.fetch("question"), "x" * 100
  end

  def test_explicit_original_scope_survives_a_forgotten_host_for_reads_and_controls
    @core.turn_rows = [{ "public_id" => "first", "position" => 0, "kind" => "direct_reply", "status" => "completed",
      "active_variant" => { "public_id" => "variant", "content" => "Archived answer" } }]
    @bridge.turns("conversation", workspace_public_id: "original")
    @bridge.turn_source("conversation", position: 0, workspace_public_id: "original")
    @bridge.snapshot("conversation", workspace_public_id: "original")
    @bridge.pending("conversation", workspace_public_id: "original")
    @bridge.submit("conversation", text: "Restored", speaker: "speaker", idempotency_key: "event", workspace_public_id: "original")
    @bridge.stop("conversation", workspace_public_id: "original")

    assert_equal %i[turns turns followers attach inputs asks say stop], @core.calls.map(&:first)
    assert_equal [:inputs, "conversation", { host_type: "conversation", workspace_public_id: "original" }],
      @core.calls.find { |call| call.first == :inputs }, "the local routing hint can be absent before the queue read"
    scoped = @core.calls.reject { |call| %i[followers asks].include?(call.first) }
    assert scoped.all? { |call| call.last.fetch(:workspace_public_id) == "original" }
    assert_includes @client.calls, [:workspace, "original"]
    refute_includes @client.calls, [:workspace, "workspace"]
    refute @core.calls.any? { |call| call.first == :conversation }, "no extra remote read is needed to recover scope"
  end

  def test_durable_events_remain_readable_after_archive_removes_the_local_follower
    @core.define_singleton_method(:host_events) do |id, **|
      raise Rho::Core::Refused.new("This daemon is not following #{id}", code: "host_not_followed", status: 404)
    end
    event = CybrosAgent::Api::Event.new(public_id: "event", sequence: 9, cursor: "event-cursor",
      type: "input_materialized", resource_type: "conversation", resource_public_id: "conversation",
      occurred_at: "2026-09-30T12:00:00Z", payload: { "input_public_id" => "input", "turn_public_id" => "turn" })
    page = CybrosAgent::Api::EventPage.new(items: [event], next_after: "next-cursor", watermark: 10)
    reads = []
    context = Object.new
    context.define_singleton_method(:events) { |**fields| reads << fields; page }
    @client.define_singleton_method(:conversation) do |id|
      @calls << [:conversation, id]
      context
    end

    result = @bridge.events("conversation", after: "previous-cursor", workspace_public_id: "original")

    assert_equal [{ after: "previous-cursor" }], reads
    assert_equal [[:workspace, "original"], [:conversation, "conversation"]], @client.calls
    assert_equal "turn", result.fetch("events").first.fetch("payload").fetch("turn_public_id")
    assert_equal({ "next_after" => "next-cursor", "watermark" => 10 }, result.fetch("pagination"))
  end

  def test_workspace_operations_use_bot_home_and_new_preserves_the_explicit_home
    assert_equal "workspace", @bridge.default_workspace.fetch("public_id")
    assert_equal ["workspace"], @bridge.workspaces.map { |row| row.fetch("public_id") }
    assert_equal "chosen", @bridge.workspace("chosen").fetch("public_id")
    assert_equal "New", @bridge.create_workspace(name: "New", idempotency_key: "create-event").fetch("name")
    assert_equal [:create_workspace, { name: "New", idempotency_key: "create-event" }], @core.calls.last
    @bridge.new_bot_conversation(operation_id: "open-event", home_workspace_public_id: "chosen")
    assert_equal [:new_bot_conversation, { operation_id: "open-event", agent_public_id: nil, home_workspace_public_id: "chosen" }], @core.calls.last
    @core.conversation_workspace_id = "original"
    assert_equal "original", @bridge.conversation_workspace("old").fetch("public_id")
  end

  def test_missing_default_workspace_reports_a_business_refusal_with_recovery
    @core.bot["home_workspace_public_id"] = nil
    error = assert_raises(Rho::Error) { @bridge.default_workspace }
    assert_includes error.message, "home workspace"
    assert_includes error.message, "/new"
  end

  def test_oversized_approval_and_unrepresented_attention_remain_visible_without_buttons
    @client.loops = [held_loop("large", "conversation", "approval"), held_loop("failed", "conversation", nil)]
    @client.more = "next"
    @core.asks = [{ "run_public_id" => "large", "task_key" => "approval", "kind" => "approval", "tool_name" => "bash",
      "tool_input" => { "command" => "x" * Bridge::QUESTION_LIMIT } }]
    rows = @bridge.pending("conversation")
    assert_equal %w[local local local], rows.map { |row| row.fetch("kind") }
    assert_equal ["large", "failed", nil], rows.map { |row| row.fetch("run_public_id") }
    refute_includes rows[0].fetch("question"), "x" * 100
  end

  private

    def tool(name, **fields) = { "type" => "function", "function" => { "name" => name } }.merge(fields.transform_keys(&:to_s))

    def held_loop(id, owner, key, requester: nil)
      HeldLoop.new(public_id: id, turn: TurnOwner.new(conversation_public_id: owner, public_id: "#{id}-turn"), requester_speaker_public_id: requester,
        tasks: key ? [Task.new(key: key, status: key == "ask" ? "awaiting_input" : "needs_approval",
          kind: key == "ask" ? "await_task" : "tool_task")] : [])
    end
end
