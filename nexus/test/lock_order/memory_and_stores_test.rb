require "test_helper"
require_relative "../test_helpers/lock_order_test_helper"

class MemoryAndStoresLockOrderTest < ActiveSupport::TestCase
  include LockOrderTestHelper

  # THE MEMORY VERBS: the anchor row FIRST, in ladder order — `users` for `user/`, `workspaces` for
  # `workspace/` — then the conversation for the fence. Before this step `revising` held the
  # conversation and `Write` locked the anchor under it: conversations → workspaces on every
  # `workspace/` write from a loop-backed turn, an inversion this guard had never seen because no
  # memory flow was driven.
  def memory_write_node(path)
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    @account = account
    @human = users(:member)
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @human)
    seam = create_run_backed_turn(conversation: conversation, acting_user: @human)
    memory_tools = Nexus::ToolRegistry::LIVE.filter_map do |canonical, tool|
      next unless canonical.start_with?("nexus.memory.")

      { "type" => "function", "function" => tool.wire_schema }
    end
    appended = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.authored(
      agent_run: seam.agent_run,
      steps: [model("ask", "prompt" => "use memory", "tools" => memory_tools)]
    ))
    assert_predicate appended, :applied?
    schedule_loop!(seam.agent_run)
    run_loop_round!(seam.agent_run, sse_success("calling", tool_calls: [
      { id: "call_m", name: "memory_write",
        arguments: JSON.generate("path" => path, "content" => "x") },
    ]))
    seam.agent_run.agent_run_tasks.find_by!(tool_name: "memory_write")
  end

  test "memory_write user/ from a loop-backed turn descends users then the conversation" do
    node = memory_write_node("user/notes.md")

    sequences = assert_ladder_order("memory write user/") do
      AgentRuns::Memory::Run.call(node: node)
    end

    seen = sequences.flatten
    assert_operator seen.index("users"), :<, seen.index("conversations")
    assert MemoryDocument.for_user(users(:member).id).exists?(name: "notes.md")
  end

  test "memory_write workspace/ from a loop-backed turn descends workspaces then the conversation" do
    node = memory_write_node("workspace/notes.md")

    sequences = assert_ladder_order("memory write workspace/") do
      AgentRuns::Memory::Run.call(node: node)
    end

    seen = sequences.flatten
    assert_operator seen.index("workspaces"), :<, seen.index("conversations")
  end

  test "the member door's user/ write descends users then the conversation" do
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: users(:member))

    sequences = assert_ladder_order("member door memory write user/") do
      result = Conversations::Memory::Apply.write(expected: memory_expectation_for(conversation: conversation, path: "user/notes.md", by: users(:member)),
        conversation: conversation, path: "user/notes.md", content: "x", by: users(:member)
      )
      assert_predicate result, :accepted?, result.outcome.inspect
    end

    seen = sequences.flatten
    assert_operator seen.index("users"), :<, seen.index("conversations")
  end

  test "the member door's workspace/ write descends workspaces then the conversation" do
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: users(:member))

    sequences = assert_ladder_order("member door memory write workspace/") do
      result = Conversations::Memory::Apply.write(expected: memory_expectation_for(conversation: conversation, path: "workspace/notes.md", by: users(:member)),
        conversation: conversation, path: "workspace/notes.md", content: "x", by: users(:member)
      )
      assert_predicate result, :accepted?, result.outcome.inspect
    end

    seen = sequences.flatten
    assert_operator seen.index("workspaces"), :<, seen.index("conversations")
  end

  # THE THREE STORE CREATES: the cap count serializes on the host row, and each host descends the
  # ladder from its own rung.
  test "store entry create keeps cap and local writer locks in ladder order" do
    sequences = assert_ladder_order("store entry create") do
      result = StoreEntries::Create.call(
        host: workspaces(:shared), by: users(:member),
        namespace: "guard", key: "k", value: nil
      )
      assert_equal :created, result.outcome
    end

    seen = sequences.flatten.uniq
    assert_includes seen, "workspaces"
    assert_includes seen, "users"
  end

  test "store entry create on a conversation host descends users then the conversation" do
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: users(:member))

    sequences = assert_ladder_order("store entry create conversation host") do
      result = StoreEntries::Create.call(
        host: conversation, by: users(:agent), namespace: "guard", key: "k", value: nil
      )
      assert_equal :created, result.outcome
    end

    seen = sequences.flatten
    assert_operator seen.index("users"), :<, seen.index("conversations")
    assert_not_includes seen, "workspaces", "the workspace is read lock-free on this host"
  end

  test "store entry create on the user host takes the users rows alone" do
    sequences = assert_ladder_order("store entry create user host") do
      result = StoreEntries::Create.call(
        host: users(:agent), by: users(:agent), namespace: "guard", key: "k", value: nil
      )
      assert_equal :created, result.outcome
    end

    assert_equal ["users"], sequences.flatten.uniq
  end
end
