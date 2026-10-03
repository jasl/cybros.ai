require "test_helper"

# THE FRAMES → `session/update`: every row of the
# table against recorded frame shapes — the payloads as `HostRun` fans
# them (`text_delta {text}`, `stream_reset {reason}`, `task_status
# {task_key, kind, status}`, the `call` row under `payload.call`, the
# snapshot's `text`/`text_length`/`tasks`) — with the one `Core#task` read
# per first sight counted on the double.
class AcpMappingTest < Minitest::Test
  Agent = Rho::Acp::Agent
  Mapping = Agent::Mapping

  # The agent the mapping talks to: a connection that collects.
  class Collector
    attr_reader :sent, :said

    def initialize
      @sent = []
      @said = []
    end

    def connection = self
    def notify(method, params) = @sent << [method, params]
    def say(sentence) = @said << sentence
    def updates = @sent.map { |_method, params| params.fetch("update") }
  end

  def setup
    @core = RhoAcpTest::CoreDouble.new
    @agent = Collector.new
    @session = Agent::Session.new(id: "cnv_1", mode: "ask", model: nil, root: "/work/project")
    @state = @session.turn_state("trn_1", loop: "alp_1")
    @mapping = Mapping.new(agent: @agent, session: @session, core: @core, state: @state)
  end

  def updates = @agent.updates

  def test_text_deltas_are_message_chunks_and_a_reset_bumps_the_message_id
    @mapping.frame("text_delta", { "text" => "Hel" })
    @mapping.frame("text_delta", { "text" => "lo" })
    @mapping.frame("stream_reset", { "reason" => "replaced" })
    @mapping.frame("text_delta", { "text" => "Again" })

    assert_equal 3, updates.length
    assert_equal({ "sessionUpdate" => "agent_message_chunk", "content" => { "type" => "text", "text" => "Hel" },
                   "messageId" => "trn_1:0" }, updates[0])
    assert_equal "trn_1:0", updates[1]["messageId"]
    assert_equal "trn_1:1", updates[2]["messageId"]
    assert_equal "Again", updates[2].dig("content", "text")
    assert_equal({ "sessionId" => "cnv_1", "update" => updates[0] }, @agent.sent[0][1])
    assert_equal "session/update", @agent.sent[0][0]
  end

  def test_reasoning_deltas_are_thought_chunks
    @mapping.frame("reasoning_delta", { "text" => "hmm", "kind" => "summary" })

    assert_equal [{ "sessionUpdate" => "agent_thought_chunk", "content" => { "type" => "text", "text" => "hmm" },
                    "messageId" => "trn_1:0" }], updates
  end

  def test_a_join_emits_the_snapshot_text_and_a_rejoin_only_the_bytes_past_what_was_emitted
    @mapping.frame("snapshot", { "turn" => "trn_1", "loop" => "alp_1", "text" => "hello", "text_length" => 5 })
    @mapping.frame("text_delta", { "text" => " wor" })
    # The re-join: the daemon accumulated more than this reader sent.
    rejoin = Mapping.new(agent: @agent, session: @session, core: @core, state: @state)
    rejoin.frame("snapshot", { "turn" => "trn_1", "loop" => "alp_1", "text" => "hello world", "text_length" => 11 })
    rejoin.frame("snapshot", { "turn" => "trn_1", "loop" => "alp_1", "text" => "hello world", "text_length" => 11 })

    assert_equal ["hello", " wor", "ld"], updates.map { |update| update.dig("content", "text") }
  end

  def test_a_snapshot_past_the_daemons_bound_uses_text_length_against_the_tail
    @mapping.frame("snapshot", { "turn" => "trn_1", "loop" => "alp_1", "text" => "hello", "text_length" => 5 })
    rejoin = Mapping.new(agent: @agent, session: @session, core: @core, state: @state)
    rejoin.frame("snapshot", { "turn" => "trn_1", "loop" => "alp_1", "text" => "lo world", "text_length" => 11 })

    assert_equal ["hello", " world"], updates.map { |update| update.dig("content", "text") }
  end

  def test_a_snapshot_of_another_turn_moves_nothing
    @mapping.frame("snapshot", { "turn" => "trn_0", "loop" => "alp_0", "text" => "old", "text_length" => 3,
                                 "tasks" => [{ "task_key" => "k9", "kind" => "tool_task", "status" => "running" }] })

    assert_empty updates
    refute @core.called?(:task)
  end

  def test_a_tool_task_first_sight_is_one_read_and_a_tool_call_then_updates
    @core.tasks[["alp_1", "k1"]] = { "tool_name" => "bash", "tool_input" => { "command" => "echo hi\necho there" } }

    @mapping.frame("task_status", { "task_key" => "k1", "kind" => "tool_task", "status" => "needs_approval" })
    @mapping.frame("task_status", { "task_key" => "k1", "kind" => "tool_task", "status" => "needs_approval" })
    @mapping.frame("task_status", { "task_key" => "k1", "kind" => "tool_task", "status" => "running" })
    @mapping.frame("task_status", { "task_key" => "k1", "kind" => "tool_task", "status" => "completed" })

    assert_equal 1, @core.calls_of(:task).length
    assert_equal [["alp_1", "k1"], {}], @core.calls_of(:task).first
    assert_equal({ "sessionUpdate" => "tool_call", "toolCallId" => "alp_1:k1", "title" => "bash echo hi",
                   "kind" => "execute", "status" => "pending",
                   "rawInput" => { "command" => "echo hi\necho there" } }, updates[0])
    assert_equal({ "sessionUpdate" => "tool_call_update", "toolCallId" => "alp_1:k1", "status" => "in_progress" }, updates[1])
    assert_equal({ "sessionUpdate" => "tool_call_update", "toolCallId" => "alp_1:k1", "status" => "completed" }, updates[2])
    assert_equal 3, updates.length
  end

  def test_the_status_table
    expected = {
      "waiting" => "pending", "needs_approval" => "pending", "dispatched" => "in_progress", "running" => "in_progress",
      "completed" => "completed", "failed" => "failed", "timed_out" => "failed", "uncertain" => "failed",
      "canceled" => "failed", "skipped" => "failed",
    }
    assert_equal expected, expected.keys.to_h { |status| [status, Mapping.status_of(status)] }
  end

  def test_the_kind_table
    {
      "read" => "read", "ls" => "read", "read_process" => "read", "list_processes" => "read", "files_bytes" => "read",
      "browser_snapshot" => "read", "browser_screenshot" => "read", "grep" => "search", "find" => "search",
      "write" => "edit", "edit" => "edit", "bash" => "execute", "start_process" => "execute",
      "stop_process" => "execute", "world_restore" => "execute", "web_fetch" => "fetch", "browser_navigate" => "fetch",
      "todo_write" => "think", "skill" => "other", "memory_read" => "other", "spawn" => "other", "task" => "other",
      "compose" => "other", "send" => "other", "mcp__fx__echo" => "other", "delegate_agent" => "other",
      "checkpoints" => "other",
    }.each { |name, kind| assert_equal kind, Mapping.kind_of(name), name }
  end

  def test_a_write_carries_a_diff_and_a_location_absolute_against_the_root
    @core.tasks[["alp_1", "k2"]] = { "tool_name" => "write", "tool_input" => { "path" => "lib/a.rb", "content" => "puts 1\n" } }

    @mapping.frame("task_status", { "task_key" => "k2", "kind" => "tool_task", "status" => "running" })

    call = updates.first
    assert_equal "write lib/a.rb", call["title"]
    assert_equal "edit", call["kind"]
    assert_equal [{ "path" => "/work/project/lib/a.rb" }], call["locations"]
    assert_equal [{ "type" => "diff", "path" => "/work/project/lib/a.rb", "newText" => "puts 1\n" }], call["content"]
  end

  def test_an_edit_carries_one_diff_per_entry
    @core.tasks[["alp_1", "k3"]] = {
      "tool_name" => "edit",
      "tool_input" => { "path" => "/abs/b.rb", "edits" => [{ "oldText" => "a", "newText" => "b" }, { "oldText" => "c", "newText" => "d" }] },
    }

    @mapping.frame("task_status", { "task_key" => "k3", "kind" => "tool_task", "status" => "running" })

    assert_equal [
      { "type" => "diff", "path" => "/abs/b.rb", "oldText" => "a", "newText" => "b" },
      { "type" => "diff", "path" => "/abs/b.rb", "oldText" => "c", "newText" => "d" },
    ], updates.first["content"]
    assert_equal [{ "path" => "/abs/b.rb" }], updates.first["locations"]
  end

  def test_a_non_string_path_is_no_location
    @core.tasks[["alp_1", "k4"]] = { "tool_name" => "read", "tool_input" => { "path" => 12 } }

    @mapping.frame("task_status", { "task_key" => "k4", "kind" => "tool_task", "status" => "running" })

    refute updates.first.key?("locations")
    assert_equal "read", updates.first["title"]
  end

  def test_the_settled_call_row_is_an_update_with_the_preview_and_no_second_read
    @core.tasks[["alp_1", "k1"]] = { "tool_name" => "bash", "tool_input" => { "command" => "ls" } }
    @mapping.frame("task_status", { "task_key" => "k1", "kind" => "tool_task", "status" => "running" })
    @mapping.frame("call", { "type" => "call", "agent_loop_public_id" => "alp_1", "task_key" => "k1",
                             "payload" => { "call" => { "task_key" => "k1", "name" => "bash", "status" => "completed",
                                                        "is_error" => false, "output_preview" => "a.rb\nb.rb" } } })
    @mapping.frame("call", { "type" => "call", "agent_loop_public_id" => "alp_1", "task_key" => "k1",
                             "payload" => { "call" => { "task_key" => "k1", "name" => "bash", "status" => "completed",
                                                        "is_error" => true, "output_preview" => "boom" } } })

    assert_equal 1, @core.calls_of(:task).length
    assert_equal({ "sessionUpdate" => "tool_call_update", "toolCallId" => "alp_1:k1", "status" => "completed",
                   "content" => [{ "type" => "content", "content" => { "type" => "text", "text" => "a.rb\nb.rb" } }] },
      updates[1])
    assert_equal "failed", updates[2]["status"]
  end

  def test_a_completed_todo_write_is_the_plan_whole
    @core.tasks[["alp_1", "k5"]] = {
      "tool_name" => "todo_write",
      "tool_input" => { "todos" => [{ "content" => "one", "status" => "completed" }, { "content" => "two", "status" => "in_progress" }] },
      "result" => { "is_error" => false },
    }

    @mapping.frame("task_status", { "task_key" => "k5", "kind" => "tool_task", "status" => "running" })
    @mapping.frame("task_status", { "task_key" => "k5", "kind" => "tool_task", "status" => "completed" })

    assert_equal "think", updates[0]["kind"]
    assert_equal({ "sessionUpdate" => "plan", "entries" => [
      { "content" => "one", "priority" => "medium", "status" => "completed" },
      { "content" => "two", "priority" => "medium", "status" => "in_progress" },
    ] }, updates.last)
  end

  def test_the_snapshot_seeds_the_task_table
    @core.tasks[["alp_1", "k1"]] = { "tool_name" => "grep", "tool_input" => { "pattern" => "foo", "path" => "." } }

    @mapping.frame("snapshot", { "turn" => "trn_1", "loop" => "alp_1",
                                 "tasks" => [{ "task_key" => "k1", "kind" => "tool_task", "status" => "running" },
                                             { "task_key" => "r1", "kind" => "model_task", "status" => "running" }] })
    @mapping.frame("task_status", { "task_key" => "k1", "kind" => "tool_task", "status" => "completed" })

    assert_equal %w[tool_call tool_call_update], updates.map { |update| update["sessionUpdate"] }
    assert_equal "search", updates.first["kind"]
    assert_equal "grep foo", updates.first["title"]
  end

  def test_the_listed_no_op_frames_and_the_ask_put_nothing_on_the_wire
    %w[round round_result progress usage input_accepted runner_bound task_deadline_extended input_blocked
       attention_required turn_status closed].each do |type|
      @mapping.frame(type, { "task_key" => "x", "status" => "completed", "reason" => "approval_required" })
    end
    @mapping.frame("task_status", { "task_key" => "a1", "kind" => "ask", "status" => "running" })

    assert_empty updates
    refute @core.called?(:task)
  end

  def test_a_frame_of_another_loop_moves_nothing
    @mapping.frame("task_status", { "task_key" => "k1", "kind" => "tool_task", "status" => "running", "agent_loop_public_id" => "alp_other" })

    assert_empty updates
  end

  def test_a_read_the_daemon_refuses_still_names_the_call
    @core.refuse(:task, "the daemon refused the read", code: nil, status: 500)

    @mapping.frame("task_status", { "task_key" => "k7", "kind" => "tool_task", "status" => "running" })

    assert_equal "k7", updates.first["title"]
    assert_equal "other", updates.first["kind"]
    assert_equal({}, updates.first["rawInput"])
    assert_includes @agent.said.join, "the daemon refused the read"
  end

  def test_conversation_ended_marks_the_session
    @mapping.frame("conversation_ended", {})

    assert @session.ended
  end
end
