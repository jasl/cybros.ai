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
    answer = @bridge.submit("conversation", text: "hello", speaker: "speaker", idempotency_key: "event", model: "dev/mock-text")
    assert_equal "input", answer.dig("input", "public_id")
    assert_equal [:say, "conversation", "hello", { mode: "queue", idempotency_key: "event",
      speaker_actor_public_id: "speaker", kind: nil, model: "dev/mock-text", wait: false }], @core.calls.last

    @bridge.submit("conversation", text: "background", speaker: "speaker", idempotency_key: "observed-event", observe: true, model: "dev/mock-text")
    assert_equal({ mode: "queue", idempotency_key: "observed-event", speaker_actor_public_id: "speaker",
      kind: "message", model: nil, wait: false }, @core.calls.last.last)
  end

  def test_task_status_reads_the_exact_loop_in_its_original_workspace
    @client.loops = [Data.define(:public_id, :status).new(public_id: "original-loop", status: "completed")]

    assert_equal({ "status" => "completed" }, @bridge.task_execution("original-loop", workspace_public_id: "original"))
    assert_includes @client.calls, [:workspace, "original"]
    assert_includes @client.calls, [:agent_loop, "original-loop"]
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

  def test_group_open_resolves_only_this_instances_registered_profile
    @client.named_agents = [Agent.new(name: "telegram-group", public_id: "wrong", derived_from_public_id: "sibling"),
      Agent.new(name: "telegram-group", public_id: "group", derived_from_public_id: "own")]
    assert_equal "conversation", @bridge.open(idempotency_key: "open-event", group: true)
    assert_equal [:open, { idempotency_key: "open-event", agent: "group", workspace_public_id: nil }], @core.calls.last
  end

  def test_read_only_tools_come_from_the_actual_profile_and_kernel_alias_meaning
    @client.tool_definitions = [tool("read"), tool("bash"), tool("Workflow", canonical: "nexus.graph.compose"),
      tool("Agent", canonical: "nexus.conversation.spawn"), tool("ReadHelper", canonical: "nexus.graph.task"), tool("Agent")]
    group = Data.define(:name, :public_id, :derived_from_public_id, :configuration)
    @client.named_agents = [group.new(name: "telegram-group", public_id: "group", derived_from_public_id: "own",
      configuration: Configuration.new(tool_definitions: [tool("ls"), tool("edit"), tool("ask")]))]

    assert_equal %w[read Workflow ReadHelper], @bridge.read_only_tool_names(group: false)
    assert_equal %w[ls ask], @bridge.read_only_tool_names(group: true)
  end

  def test_execution_read_only_check_uses_frozen_declarations_in_the_exact_workspace
    detail = Data.define(:tool_definitions)
    resource = Object.new
    calls = @client.calls
    definitions = [tool("read"), tool("Worker", canonical: "nexus.graph.task"), { "name" => "nexus.graph.wait" }]
    resource.define_singleton_method(:task) do |key|
      calls << [:task, key]
      detail.new(tool_definitions: definitions)
    end
    @client.define_singleton_method(:agent_loop) { |id| calls << [:agent_loop, id]; resource }

    assert @bridge.read_only_execution?("original-loop", workspace_public_id: "original")
    assert_equal [[:workspace, "original"], [:agent_loop, "original-loop"], [:task, "r1"]], calls
    definitions << tool("read", canonical: "nexus.conversation.send")
    refute @bridge.read_only_execution?("original-loop", workspace_public_id: "original")
    definitions.clear
    assert @bridge.read_only_execution?("original-loop", workspace_public_id: "original")
    definitions = nil
    refute @bridge.read_only_execution?("original-loop", workspace_public_id: "original")
  end

  def test_missing_or_pruned_execution_details_cannot_resume_member_work
    resource = Object.new
    failure = CybrosAgent::Api::NotFound.new("Missing task")
    resource.define_singleton_method(:task) { |_key| raise failure }
    @client.define_singleton_method(:agent_loop) { |_id| resource }

    refute @bridge.read_only_execution?("old-loop", workspace_public_id: "original")
    failure = CybrosAgent::Api::Error.new("Pruned", code: "execution_details_pruned")
    refute @bridge.read_only_execution?("old-loop", workspace_public_id: "original")
  end

  def test_steer_preserves_the_original_input_owner_and_uses_core_admission
    answer = @bridge.submit("conversation", text: "Preserve the current tools", speaker: "speaker",
      idempotency_key: "steer-event", mode: "steer", workspace_public_id: "original", expected_steering_loop_public_id: "original-loop")

    assert_equal "input", answer.dig("input", "public_id")
    assert_equal [[:say, "conversation", "Preserve the current tools", {
      mode: "steer", idempotency_key: "steer-event", speaker_actor_public_id: "speaker",
      kind: nil, model: nil, wait: false, workspace_public_id: "original", expected_steering_loop_public_id: "original-loop",
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

  def test_archived_submission_explains_recovery_and_restoration_keeps_the_original_request_scope
    archived = true
    accepted = []
    @core.define_singleton_method(:say) do |id, text, **options|
      @calls << [:say, id, text, options]
      if archived
        raise Rho::Core::Refused.new("This daemon is not following #{id} — attach it first",
          code: "host_not_followed", status: 404)
      end
      accepted << [id, text, options]
      { "input" => { "public_id" => "restored-input" } }
    end
    @core.define_singleton_method(:conversation) do |id, **options|
      @calls << [:conversation, id, options]
      { "public_id" => id, "archived_at" => ("2026-09-30T12:00:00Z" if archived) }.compact
    end
    request = { text: "Continue", speaker: "speaker", idempotency_key: "event", workspace_public_id: "original" }

    error = assert_raises(Rho::Error) { @bridge.submit("conversation", **request) }
    assert_equal "This conversation is archived. Restore it before continuing, or use /new to start another conversation.", error.message
    assert_empty accepted
    assert_equal [:conversation, "conversation", { workspace_public_id: "original" }], @core.calls.last

    archived = false
    assert_equal "restored-input", @bridge.submit("conversation", **request).dig("input", "public_id")
    assert_equal 1, accepted.length
    assert_equal "original", accepted.first.last.fetch(:workspace_public_id)
    assert_equal "event", accepted.first.last.fetch(:idempotency_key)
    assert_equal 1, @core.calls.count { |call| call.first == :conversation }, "successful submissions need no extra lifecycle read"
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

  def test_missing_group_profile_refuses_instead_of_using_the_personal_profile
    assert_raises(Rho::Error) { @bridge.open(idempotency_key: "event", group: true) }
    assert_empty @core.calls
  end

  def test_register_speaker_uses_the_bot_scoped_external_identity
    assert_equal "speaker", @bridge.register_speaker(bot_id: 7, user: { "id" => 42, "first_name" => "First", "last_name" => "Last" })
    assert_equal [:register_ingress_actor, { channel_key: "telegram:7", external_id: "42", display_name: "First Last" }], @client.calls.last
  end

  def test_disconnection_is_retryable_before_an_ingress_actor_or_input_exists
    bridge = Bridge.new(host: Host.new(home: nil, member_plane: ->(**) { nil }), core: @core)
    assert_raises(Rho::ConnectionError) { bridge.register_speaker(bot_id: 7, user: { "id" => 42 }) }
    assert_empty @core.calls
    assert_empty @client.calls
  end

  def test_long_display_names_preserve_graphemes_within_the_actor_boundary
    @bridge.register_speaker(bot_id: 7, user: { "id" => 42, "first_name" => "😀" * 64, "last_name" => "名" * 64 })
    name = @client.calls.last.last.fetch(:display_name)
    assert_operator name.length, :<=, 100
    assert_predicate name, :valid_encoding?
    assert_match(/\A😀+/, name)
  end

  def test_turns_exposes_only_final_text_and_keeps_unfinished_positions
    @core.turn_rows = [
      { "public_id" => "first", "position" => 2, "kind" => "direct_reply", "status" => "completed",
        "active_variant" => { "agent_loop_public_id" => "loop-1", "content" => "Final answer" } },
      { "public_id" => "second", "position" => 3, "kind" => "direct_reply", "status" => "running",
        "active_variant" => { "agent_loop_public_id" => "loop-2", "content" => "Not yet delivered" } },
    ]
    rows = @bridge.turns("conversation", after_position: 1)
    assert_equal "Final answer", rows.first.fetch("text")
    assert_equal "", rows.last.fetch("text")
    assert_equal [2, 3], rows.map { |row| row.fetch("position") }
    assert_equal "loop-2", rows.last.fetch("loop_public_id")
    assert_equal [:turns, "conversation", { after_position: 1 }], @core.calls.last
  end

  def test_first_read_does_not_skip_the_zero_position_turn
    @core.turn_rows = [{ "public_id" => "first", "position" => 0, "kind" => "direct_reply", "status" => "completed",
      "active_variant" => { "agent_loop_public_id" => "loop-1", "content" => "First answer" } }]
    assert_equal "First answer", @bridge.turns("conversation").first.fetch("text")
    assert_equal [:turns, "conversation", { after_position: nil }], @core.calls.last
  end

  def test_delivery_source_reads_one_exact_position_and_preserves_variant_identity
    @core.turn_rows = [{ "public_id" => "first", "position" => 0, "kind" => "direct_reply", "status" => "completed",
      "active_variant" => { "public_id" => "variant", "agent_loop_public_id" => "loop-1", "content" => "First answer" } }]
    assert_equal "variant", @bridge.turn_source("conversation", position: 0).fetch("variant_public_id")
    assert_equal [:turns, "conversation", { before_position: 1, limit: 1 }], @core.calls.last
    assert_nil @bridge.turn_source("conversation", position: 1), "an earlier visible row cannot replace a deleted target"
  end

  def test_snapshot_shows_safe_progress_and_controls_address_the_exact_loop
    @core.run = { "loop_status" => "running", "loop" => "loop-2", "reasoning" => "private reasoning",
      "tasks" => [{ "status" => "needs_approval", "kind" => "tool_task", "input" => { "secret" => "hidden" } }] }
    assert_equal({ "status" => "running", "loop_public_id" => "loop-2", "action" => "Waiting for approval" }, @bridge.snapshot("conversation"))
    @bridge.stop("loop-2", host_type: "agent_loop")
    @bridge.approve("loop-2", "task-1", workspace_public_id: "original")
    @bridge.deny("loop-2", "task-2", reason: "No", workspace_public_id: "original")
    @bridge.answer("loop-2", "task-3", "Yes", workspace_public_id: "original")
    assert_equal [[:stop, "loop-2", { host_type: "agent_loop" }], [:approve, "loop-2", "task-1", { workspace_public_id: "original" }],
      [:deny, "loop-2", "task-2", { reason: "No", workspace_public_id: "original" }], [:answer, "loop-2", "task-3", "Yes", { workspace_public_id: "original" }]], @core.calls.last(4)
  end

  def test_local_run_index_includes_side_followers_and_a_supplied_missing_run_does_not_relist
    @core.run_rows = [{ "public_id" => "main", "sequence" => 11 }]
    @core.side_run_rows = [{ "public_id" => "side", "sequence" => 7, "side" => { "parent" => "main" } }]

    index = @bridge.runs
    assert_equal ["main", "side"], index.keys
    assert_equal 7, index.fetch("side").fetch("sequence")
    assert_equal [[:loops, { side: false }], [:loops, { side: true }]], @core.calls

    @core.calls.clear
    @bridge.snapshot("side", run: index.fetch("side"))
    assert_equal [:inputs], @core.calls.map(&:first)
    @core.calls.clear
    @bridge.snapshot("forgotten", run: nil, workspace_public_id: "original")
    assert_equal %i[attach inputs], @core.calls.map(&:first), "the caller already supplied this pass's local index"
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
    @core.run_rows = [{ "public_id" => "conversation", "loop_status" => "running", "loop" => "loop-1",
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
    @core.input_rows = [{ "public_id" => "input-2", "state" => "blocked", "blocked_reason" => "loop_held" }]
    refute @bridge.snapshot("conversation").key?("blocked_input_public_id"), "a held loop reports its actual pending request"
  end

  def test_pending_includes_owned_children_but_not_siblings_and_marks_unaddressable_work_local
    @host_workspaces["conversation"] = "original-workspace"
    @client.loops = [held_loop("own-loop", "conversation", "ask"), held_loop("child-loop", "child", "approval"),
      held_loop("other-loop", "other", "ask"), held_loop("peer-loop", "child", "peer")]
    @client.parents = { "child" => "conversation", "other" => nil }
    @core.asks = [{ "agent_loop_public_id" => "own-loop", "workspace_public_id" => "original-workspace", "task_key" => "ask", "kind" => "ask", "prompt" => "Which option?" },
      { "agent_loop_public_id" => "child-loop", "workspace_public_id" => "original-workspace", "task_key" => "approval", "kind" => "approval", "tool_name" => "bash", "tool_input" => { "command" => "make test" } }]
    rows = @bridge.pending("conversation")
    assert_equal %w[own-loop child-loop peer-loop], rows.map { |row| row.fetch("loop_public_id") }
    assert_equal %w[ask approval local], rows.map { |row| row.fetch("kind") }
    assert_equal ["original-workspace"] * 2, rows.first(2).map { |row| row.fetch("workspace_public_id") }
    assert_includes rows[1].fetch("question"), "make test"
    assert_equal "peer", rows[2].fetch("task_key"), "an unaddressable peer is visible without a blind button"
    refute_includes @client.calls, [:agent_loop, "other-loop"]
    assert_equal 1, @client.calls.count([:conversation, "child"]), "a page resolves each parent once"
    assert_includes @client.calls, [:list, { attention: "any", limit: Bridge::ATTENTION_LIMIT }]
    assert_includes @client.calls, [:workspace, "original-workspace"]
    refute_includes @client.calls, [:workspace, "workspace"], "changing the default must not move old approvals"
    refute_includes @core.calls, [:conversation, "conversation"], "each poll uses the local host binding, without another Nexus read"
  end

  def test_commands_read_fresh_attention_instead_of_reusing_the_previous_follower_pass
    @client.loops = [held_loop("own-loop", "conversation", "ask")]
    @core.asks = [{ "agent_loop_public_id" => "own-loop", "workspace_public_id" => "workspace", "task_key" => "ask",
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
    question = Data.define(:prompt)
    @client.task_details = { ["group-loop", "ask"] => question.new(prompt: "Which report?"),
      ["child-loop", "ask"] => question.new(prompt: "Which section?") }

    rows = @bridge.pending("conversation", workspace_public_id: "original")

    assert_equal %w[ask ask], rows.map { |row| row.fetch("kind") }
    assert_equal ["Which report?", "Which section?"], rows.map { |row| row.fetch("question") }
    assert_equal ["original", "original"], rows.map { |row| row.fetch("workspace_public_id") }
    assert_equal %w[group-loop child-loop], rows.map { |row| row.fetch("loop_public_id") }
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
    assert_equal %w[foreign tokened approval], rows.map { |row| row.fetch("loop_public_id") }
    refute @client.calls.any? { |call| call.first == :task }, "only unaddressed model asks need their question body"
  end

  def test_an_unaddressed_model_question_keeps_the_same_size_limit
    @client.loops = [held_loop("group-loop", "conversation", "ask")]
    question = Data.define(:prompt)
    @client.task_details[["group-loop", "ask"]] = question.new(prompt: "x" * (Bridge::QUESTION_LIMIT + 1))

    row = @bridge.pending("conversation").fetch(0)

    assert_equal "local", row.fetch("kind")
    assert_equal "group-loop", row.fetch("loop_public_id")
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

    assert_equal %i[turns turns loops loops attach inputs asks say stop], @core.calls.map(&:first)
    assert_equal [:inputs, "conversation", { host_type: "conversation", workspace_public_id: "original" }],
      @core.calls.find { |call| call.first == :inputs }, "archive can forget the host before the queue read"
    scoped = @core.calls.reject { |call| %i[loops asks].include?(call.first) }
    assert scoped.all? { |call| call.last.fetch(:workspace_public_id) == "original" }
    assert_includes @client.calls, [:workspace, "original"]
    refute_includes @client.calls, [:workspace, "workspace"]
    refute @core.calls.any? { |call| call.first == :conversation }, "no extra remote read is needed to recover scope"
  end

  def test_durable_events_remain_readable_after_archive_removes_the_local_follower
    @core.define_singleton_method(:host_events) do |id, **|
      raise Rho::Core::Refused.new("This daemon is not following #{id}", code: "host_not_followed", status: 404)
    end
    event = CybrosAgent::Api::ConversationEvent.new(public_id: "event", sequence: 9, cursor: "event-cursor",
      type: "input_materialized", resource_type: "conversation", resource_public_id: "conversation",
      occurred_at: "2026-09-30T12:00:00Z", payload: { "input_public_id" => "input", "turn_public_id" => "turn" })
    page = CybrosAgent::Api::ConversationEventPage.new(items: [event], next_after: "next-cursor", watermark: 10)
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

  def test_workspace_operations_use_core_and_open_passes_only_the_selected_scope
    assert_equal "workspace", @bridge.default_workspace.fetch("public_id")
    assert_equal ["workspace"], @bridge.workspaces.map { |row| row.fetch("public_id") }
    assert_equal "chosen", @bridge.workspace("chosen").fetch("public_id")
    assert_equal "New", @bridge.create_workspace(name: "New", idempotency_key: "create-event").fetch("name")
    assert_equal [:create_workspace, { name: "New", idempotency_key: "create-event" }], @core.calls.last
    @bridge.open(idempotency_key: "open-event", workspace_public_id: "chosen")
    assert_equal [:open, { idempotency_key: "open-event", agent: nil, workspace_public_id: "chosen" }], @core.calls.last
    @core.conversation_workspace_id = "original"
    assert_equal "original", @bridge.conversation_workspace("old").fetch("public_id")
  end

  def test_missing_default_workspace_reports_a_business_refusal_with_recovery
    @core.define_singleton_method(:workspaces) do
      { "workspace" => nil, "selection" => "unavailable", "workspaces" => [] }
    end
    error = assert_raises(Rho::Error) { @bridge.default_workspace }
    assert_includes error.message, "/workspace list"
    assert_includes error.message, "/workspace use ID"
  end

  def test_oversized_approval_and_unrepresented_attention_remain_visible_without_buttons
    @client.loops = [held_loop("large", "conversation", "approval"), held_loop("failed", "conversation", nil)]
    @client.more = "next"
    @core.asks = [{ "agent_loop_public_id" => "large", "task_key" => "approval", "kind" => "approval", "tool_name" => "bash",
      "tool_input" => { "command" => "x" * Bridge::QUESTION_LIMIT } }]
    rows = @bridge.pending("conversation")
    assert_equal %w[local local local], rows.map { |row| row.fetch("kind") }
    assert_equal ["large", "failed", nil], rows.map { |row| row.fetch("loop_public_id") }
    refute_includes rows[0].fetch("question"), "x" * 100
  end

  private

    def tool(name, **fields) = { "type" => "function", "function" => { "name" => name } }.merge(fields.transform_keys(&:to_s))

    def held_loop(id, owner, key)
      HeldLoop.new(public_id: id, turn: TurnOwner.new(conversation_public_id: owner),
        tasks: key ? [Task.new(key: key, status: key == "ask" ? "awaiting_input" : "needs_approval",
          kind: key == "ask" ? "await_task" : "tool_task")] : [])
    end
end
