require "test_helper"
require_relative "../../test_helpers/agent_membership_test_helper"

# THE EXECUTOR-ORIGINATED FRAME: the fence the frame's key chooses — a claim's for a task-keyed
# frame, its originating claim for a process-keyed one — then the kernel's stamps and ONE broadcast on
# the host's `progress` feed under `{frame}`. Nothing is stored: the primary row counts do not move
# across an accepted frame. The CADENCE is the door's (`rate_limit` on the controller, keyed by
# `key_of`; its test is the controller's) — this service admits every frame it is handed.
class Executors::ProgressTest < ActiveJob::TestCase
  include AgentMembershipTestHelper
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def tool(key, **over) = super(key, "read_file", "input" => { "path" => key }, **over)

  def start!(agent_run)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
    agent_run
  end

  def claim!(agent_run, key, executor: suite_runner)
    result = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: agent_run, task_key: key, executor: executor
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    result.value.claim_token
  end

  def post(frame, executor: suite_runner)
    Executors::Progress.call(executor: executor, frame: frame)
  end

  # Every broadcast the call made, as `[stream, payload]`.
  def broadcasts
    sent = []
    ActionCable.server.stub(:broadcast, ->(name, payload) { sent << [name, payload] }) { yield }
    sent
  end

  def task_frame(agent_run, key, token, **payload)
    { "run_public_id" => agent_run.public_id, "task_key" => key, "claim_token" => token }.merge(payload)
  end

  def source(agent_run, token, key: "alpha")
    { "run_public_id" => agent_run.public_id, "task_key" => key, "claim_token" => token }
  end

  test "a claim-keyed frame is stamped and broadcast once on the loop's progress feed under {frame}" do
    agent_run = start!(seed(tool("alpha")))
    token = claim!(agent_run, "alpha")

    result = nil
    sent = broadcasts do
      result = post(task_frame(agent_run, "alpha", token, "text_tail" => "3/9 done\n", "structured" => { "n" => 3 }))
    end

    assert_predicate result, :accepted?, result.outcome.inspect
    assert_equal 1, sent.length
    stream, payload = sent.first
    assert_equal "agent_api:v1:run:#{agent_run.public_id}:progress", stream
    assert_equal [:frame], payload.keys, "the envelope is {frame}, never {event}"
    frame = payload.fetch(:frame)
    assert_equal "executor_progress", frame.fetch("type")
    assert_equal [agent_run.public_id, "alpha", "read_file"],
      frame.values_at("run_public_id", "task_key", "tool_name")
    assert_equal suite_runner.public_id, frame.fetch("executor_public_id")
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, frame.fetch("at"), "milliseconds on the wire")
    assert_equal "3/9 done\n", frame.fetch("text_tail")
    assert_equal({ "n" => 3 }, frame.fetch("structured"))
    assert_equal frame, result.value
  end

  test "the claim fence: a wrong token or another executor is not_claimant; a settled row is accepted unpublished, not refused" do
    agent_run = start!(seed(tool("alpha")))
    token = claim!(agent_run, "alpha")

    assert_equal :not_claimant, post(task_frame(agent_run, "alpha", "wrong", "text_tail" => "x")).outcome
    other = connect_provider(identifier: "other-provider", tools: %w[read_file])
    assert_equal :not_claimant, post(task_frame(agent_run, "alpha", token, "text_tail" => "x"), executor: other).outcome

    settled = Executors::Commit.call(Executors::Commit::Command.new(
      agent_run: agent_run, task_key: "alpha", executor: suite_runner, claim_token: token,
      content: "done", structured_content: nil, result_type: nil, outcome: "completed", is_error: false,
      title: nil, metadata: nil
    ))
    assert_equal :applied, settled.outcome, settled.inspect
    late = nil
    sent = broadcasts { late = post(task_frame(agent_run, "alpha", token, "text_tail" => "late")) }
    assert_predicate late, :accepted?, late.outcome.inspect
    assert_nil late.value, "accepted with nothing published"
    assert_empty sent, "a settled row's progress is nobody's news"

    assert_equal :not_found, post(task_frame(agent_run, "nope", token, "text_tail" => "x")).outcome
    assert_equal :not_found, post(task_frame(agent_run, "alpha", token).merge("run_public_id" => SecureRandom.uuid)).outcome
  end

  test "a process frame proves its originating claim on both hosts and never broadcasts its token" do
    standalone = start!(seed(tool("alpha")))
    token = claim!(standalone, "alpha")
    frame = { "run_public_id" => standalone.public_id, "process_id" => "p1",
              "source" => source(standalone, token), "lines" => ["Listening on :4000"], "exit" => nil }

    result = nil
    sent = broadcasts { result = post(frame) }
    assert_predicate result, :accepted?, result.outcome.inspect
    stream, payload = sent.sole
    assert_equal "agent_api:v1:run:#{standalone.public_id}:progress", stream
    out = payload.fetch(:frame)
    assert_equal "process_output", out.fetch("type")
    assert_equal standalone.public_id, out.fetch("run_public_id")
    assert_nil out["conversation_public_id"]
    assert_equal "p1", out.fetch("process_id")
    assert_equal ["Listening on :4000"], out.fetch("lines")
    assert_nil out.fetch("exit")
    assert_nil out["claim_token"], "nothing the poster sent beside the key and the payload rides out"
    assert_not out.key?("source")
    assert_not out.to_json.include?(token)

    provider = connect_provider(identifier: "loud-provider", tools: %w[read_file])
    assert_equal :not_claimant, post(frame, executor: provider).outcome
    assert_equal :not_claimant, post(frame.merge("source" => source(standalone, "wrong"))).outcome

    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, default_runner_executor: suite_runner)
    hosted = create_answered_loop(tool("alpha"), conversation: conversation, acting_user: @human)
    hosted_token = claim!(hosted, "alpha")
    conversation_frame = { "conversation_public_id" => conversation.public_id, "process_id" => "p2",
      "source" => source(hosted, hosted_token), "lines" => ["up"] }
    sent = broadcasts { result = post(conversation_frame) }
    assert_predicate result, :accepted?, result.outcome.inspect
    assert_equal "agent_api:v1:conversation:#{conversation.public_id}:progress", sent.sole.first
    assert_equal conversation.public_id, sent.sole.last.fetch(:frame).fetch("conversation_public_id")

    conversation.update!(default_runner_executor: nil)
    assert_predicate post(conversation_frame), :accepted?
    assert_equal :not_claimant, post(conversation_frame.merge("source" => source(standalone, token))).outcome
    assert_equal :not_found, post(conversation_frame.merge("conversation_public_id" => SecureRandom.uuid)).outcome
  end

  test "settlement preserves process proof, but retry and pruning invalidate the old source" do
    agent_run = start!(seed(tool("alpha"), tool("tail")))
    token = claim!(agent_run, "alpha")
    frame = { "run_public_id" => agent_run.public_id, "process_id" => "p1",
      "source" => source(agent_run, token), "lines" => ["up"] }
    row = agent_run.agent_run_tasks.find_by!(node_key: "alpha")
    row.update!(status: "failed", completed_at: Time.current)
    assert_predicate post(frame), :accepted?, "a settled source still owns its process"

    retried = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run, task_key: "alpha", acting_user: @human
    ))
    assert_predicate retried, :accepted?
    assert_equal :not_claimant, post(frame).outcome
    assert_equal :not_found, post(frame.merge("source" => source(agent_run, token, key: "collected"))).outcome
    assert_equal :invalid_frame, post(frame.except("source")).outcome
  end

  # THE CADENCE KEY the door limits on: the kind, the poster and the key
  # bytes — another key is another slot, the same key from another
  # executor is its own slot too (a stranger's flood cannot eat a
  # claimant's slot); a frame keyed by neither kind has none.
  test "key_of spells the kind, the poster and the key bytes, and nothing for a keyless frame" do
    runner = suite_runner
    task = { "run_public_id" => "L", "task_key" => "alpha", "claim_token" => "ignored", "text_tail" => "x" }
    assert_equal "task:#{runner.public_id}:L:alpha", Executors::Progress.key_of(runner, task)
    assert_equal "task:#{runner.public_id}:L:alpha", Executors::Progress.key_of(runner, task.merge("text_tail" => "y")),
      "the payload is no part of the key"
    assert_equal "process:#{runner.public_id}:C:p1",
      Executors::Progress.key_of(runner, { "conversation_public_id" => "C", "process_id" => "p1", "lines" => [] })
    assert_equal "process:#{runner.public_id}:L:p1",
      Executors::Progress.key_of(runner, { "run_public_id" => "L", "process_id" => "p1" })
    other = connect_provider(identifier: "other-provider", tools: %w[read_file])
    refute_equal Executors::Progress.key_of(runner, task), Executors::Progress.key_of(other, task)
    assert_nil Executors::Progress.key_of(runner, { "run_public_id" => "L" })
    assert_nil Executors::Progress.key_of(runner, { "run_public_id" => "L", "task_key" => "a", "process_id" => "p" })
    assert_nil Executors::Progress.key_of(runner, "nope")
    assert_nil Executors::Progress.key_of(runner, nil)
  end

  test "the body bound and the frame grammar: too large, keyed by neither kind, or a payload of the wrong type" do
    agent_run = start!(seed(tool("alpha")))
    token = claim!(agent_run, "alpha")

    fat = task_frame(agent_run, "alpha", token, "text_tail" => "x" * (Nexus::SizeBounds.fetch(:envelope_bound) + 1))
    assert_equal :frame_too_large, post(fat).outcome
    assert_equal :invalid_frame, post({ "run_public_id" => agent_run.public_id }).outcome
    assert_equal :invalid_frame, post({ "run_public_id" => agent_run.public_id, "task_key" => "alpha",
                                        "process_id" => "p1" }).outcome, "a key of both kinds names neither"
    assert_equal :invalid_frame, post({ "process_id" => "p1", "lines" => ["a"] }).outcome, "a process frame names a host"
    assert_equal :invalid_frame, post("nope").outcome
    assert_equal :invalid_frame, post(task_frame(agent_run, "alpha", token, "text_tail" => 7)).outcome
    assert_equal :invalid_frame,
      post({ "run_public_id" => agent_run.public_id, "process_id" => "p1", "source" => source(agent_run, token), "lines" => [1] }).outcome
    # `null` is a value of no typed member but `exit` (a signal death):
    # a null tail or null lines is malformed, never a crash and never a frame.
    assert_equal :invalid_frame,
      post({ "run_public_id" => agent_run.public_id, "process_id" => "p1", "source" => source(agent_run, token), "lines" => nil }).outcome
    assert_equal :invalid_frame, post(task_frame(agent_run, "alpha", token, "text_tail" => nil)).outcome
  end

  # A LOOP-BACKED loop's frame lands on its HOST (the way TranscriptStream resolves one): a
  # loop-backed loop has no channel of its own — its channel rejects `conversation_hosted` — so a
  # process frame keyed by the loop rides the conversation's progress feed, keyed by the
  # conversation, fenced by the conversation's binding.
  test "a process frame keyed by a loop-backed loop rides its conversation's progress feed" do
    agent = users(:agent)
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: agent,
      default_runner_executor: suite_runner)
    agent_run = create_answered_loop(tool("alpha"), conversation: conversation, acting_user: @human)
    token = claim!(agent_run, "alpha")
    refute_predicate agent_run, :standalone?
    frame = { "run_public_id" => agent_run.public_id, "process_id" => "p1", "source" => source(agent_run, token), "lines" => ["up"] }

    result = nil
    sent = broadcasts { result = post(frame) }
    assert_predicate result, :accepted?, result.outcome.inspect
    stream, payload = sent.sole
    assert_equal "agent_api:v1:conversation:#{conversation.public_id}:progress", stream
    out = payload.fetch(:frame)
    assert_equal conversation.public_id, out.fetch("conversation_public_id")
    assert_nil out["run_public_id"], "the frame is keyed by the host the feed belongs to"

    conversation.reload.update!(default_runner_executor: nil)
    assert_predicate post(frame), :accepted?, "changing the default does not invalidate a source claim"
  end

  test "nothing is stored: the primary rows do not move across accepted frames" do
    agent_run = start!(seed(tool("alpha")))
    token = claim!(agent_run, "alpha")
    counts = -> { [AgentRunTask.count, ConversationEventItem.count, ContentBody.count] }
    before = counts.call

    broadcasts do
      assert_predicate post(task_frame(agent_run, "alpha", token, "text_tail" => "a")), :accepted?
      assert_predicate post({ "run_public_id" => agent_run.public_id, "process_id" => "p1", "source" => source(agent_run, token), "lines" => ["b"] }),
        :accepted?
    end

    assert_equal before, counts.call
  end

  # THE DISJOINTNESS PIN, by constant reference — the ONE pin for the whole feed: a progress frame's
  # type, the executor's or the kernel's own, can never be mistaken for a durable item on any host,
  # nor for a transcript item, whatever a consumer reads the `type` word by; and the two halves of
  # the feed never share a word.
  test "the frame types are disjoint from every event and transcript vocabulary" do
    taken = ConversationEventItem::ITEM_TYPES | InferenceRequestEventItem::ITEM_TYPES |
      RealtimeEvents::Broadcast::LIFECYCLE_TYPES.values.flatten | Conversations::TranscriptStream::ITEM_TYPES
    feed = Executors::Progress::TYPES + Conversations::ProgressStream::KERNEL_TYPES
    assert_empty feed & taken
    assert_equal feed.uniq, feed, "the two halves of the feed share no word"
    assert_equal %w[executor_progress process_output], Executors::Progress::TYPES
    assert_equal %w[round_started step_started step_claimed], Conversations::ProgressStream::KERNEL_TYPES
  end
end
