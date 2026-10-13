require "test_helper"

# `work_canceled`: when a CLAIMED row is canceled by a stop, the executor holding the claim is told
# on its own stream so it can kill what it spawned. The fact is the row — an unclaimed canceled row
# simply leaves the inbox and nobody is told — and a publish failure never fails the cancel.
class Executors::NudgeTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def tool(key, name = "read_file", **over) = super(key, name, "input" => { "path" => key }, **over)

  def start!(agent_run)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
  end

  def claim!(agent_run, key)
    result = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: agent_run, task_key: key, executor: suite_runner
    ))
    assert_predicate result, :accepted?
    result
  end

  def stop!(agent_run)
    AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(agent_run: agent_run, acting_user: @human))
  end

  # The executor streams only: the loop's own event and transcript feeds
  # narrate the cancel too, and those are the person's mirrors.
  def capturing_broadcasts
    broadcasts = []
    ActionCable.server.stub(:broadcast, ->(stream, payload) { broadcasts << [stream, payload] }) { yield }
    broadcasts.select { |stream, _payload| stream.start_with?("agent_api:v1:executor:") }
  end

  # `work_available` on a pool row fans to every member's own stream — the same lock-free
  # containment query addressing used — and to nobody else: not the bound runner, not a provider
  # outside the loop's eligibility, not one announcing another name.
  test "a pool row is nudged on every member's stream and on no other" do
    members = %w[pool-a pool-b].map { |id| connect_provider(identifier: id, tools: ["net_fetch"]) }
    connect_provider(identifier: "owner-private", tools: ["net_fetch"], assignment_scope: :user_private)
    connect_provider(identifier: "other", tools: ["something_else"])
    agent_run = seed(tool("fetch", "net_fetch"))

    broadcasts = capturing_broadcasts { start!(agent_run) }

    streams = broadcasts.map(&:first).sort
    assert_equal members.map { |m| AgentAPI::V1::ExecutorInboxChannel.stream_name(m.public_id) }.sort, streams
    broadcasts.each do |_stream, payload|
      assert_equal({ type: Executors::Nudge::WORK_AVAILABLE, kind: "tool_call",
                     run_public_id: agent_run.public_id, task_key: "fetch",
                     tool_name: "net_fetch" }, payload.fetch(:event))
    end
  end

  test "a forced stop tells the claimant on its own stream, naming the row and nothing else" do
    agent_run = seed(tool("alpha"))
    start!(agent_run)
    claim!(agent_run, "alpha")

    broadcasts = capturing_broadcasts { stop!(agent_run) }
    stream, payload = broadcasts.sole
    assert_equal AgentAPI::V1::ExecutorInboxChannel.stream_name(suite_runner.public_id), stream
    assert_equal({ type: Executors::Nudge::WORK_CANCELED, run_public_id: agent_run.public_id,
                   task_key: "alpha" }, payload.fetch(:event))
    assert_equal "canceled", agent_run.agent_run_tasks.sole.reload.status
  end

  test "an unclaimed canceled row tells nobody: it simply leaves the inbox" do
    agent_run = seed(tool("alpha"))
    start!(agent_run)

    broadcasts = capturing_broadcasts { stop!(agent_run) }
    assert_equal [], broadcasts
    assert_equal [], Executors::Inbox.call(executor: suite_runner).tasks
  end

  test "a nudge that cannot publish never fails the cancel" do
    agent_run = seed(tool("alpha"))
    start!(agent_run)
    claim!(agent_run, "alpha")

    ActionCable.server.stub(:broadcast, ->(*) { raise "cable down" }) do
      assert_predicate stop!(agent_run), :accepted?
    end
    assert_equal "canceled", agent_run.agent_run_tasks.sole.reload.status
  end

  # THE PRINCIPAL IS THE ANSWERER: a pool row on a Human's loop-backed loop fans to the members
  # eligible for the agent the conversation is answered by — a provider private to its steward
  # included.
  test "a pool row on a loop-backed loop is nudged to the members eligible for the ANSWERER" do
    private_member = connect_provider(identifier: "owner-private", tools: ["net_fetch"], assignment_scope: :user_private)
    answered = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: users(:agent))

    broadcasts = capturing_broadcasts do
      create_answered_loop(tool("fetch", "net_fetch"), conversation: answered, acting_user: @human)
    end

    assert_equal [AgentAPI::V1::ExecutorInboxChannel.stream_name(private_member.public_id)], broadcasts.map(&:first)
  end

  test "a pool row is nudged to the members eligible for the TURN's answerer" do
    private_member = connect_provider(identifier: "owner-private", tools: ["net_fetch"], assignment_scope: :user_private)
    plain = Conversation.create!(workspace: @workspace, creating_user: @human)

    broadcasts = capturing_broadcasts do
      create_answered_loop(tool("fetch", "net_fetch"), conversation: plain, acting_user: @human,
        answering_user: users(:agent))
    end

    assert_equal [AgentAPI::V1::ExecutorInboxChannel.stream_name(private_member.public_id)], broadcasts.map(&:first)
  end
end
