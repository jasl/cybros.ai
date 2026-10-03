require "test_helper"
require_relative "../../../../test_helpers/agent_membership_test_helper"
require_relative "../../../../test_helpers/rate_limit_test_helper"

# POST /agent_api/v1/executor/progress — the ephemeral frames an executor posts, on the executor
# plane beside the inbox doors: `202` for every well-formed frame, broadcast or dropped for cadence;
# the two fences as 409s under one code each; the envelope bound and the grammar as 422s; a member
# bearer 401; a foreign host absence. The NEGATIVES the `progress` journey does not drive live here:
# a stale token, a process frame from a runner that is not the host's binding, a frame over the
# bound, a settled row.
class AgentAPI::V1::Executors::ProgressTest < ActionDispatch::IntegrationTest
  include AgentMembershipTestHelper
  include RateLimitTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @member = create_access_token_fixture(user: @human, name: "Member")
    Executors::Progress::RATE.clear
  end

  teardown { Executors::Progress::RATE.clear }

  def tool(key, **over) = super(key, "read_file", "input" => { "path" => key }, **over)

  def start!(agent_loop, acting_user: @human)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: acting_user))
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    agent_loop
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }

  def runner_bearer = bearer(suite_runner_connection.executor_access_secret)

  def claim!(agent_loop, key)
    result = Executors::Claim.call(Executors::Claim::Command.new(
      agent_loop: agent_loop, task_key: key, executor: suite_runner
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    result.value.claim_token
  end

  def post_frame(frame, headers: runner_bearer)
    post agent_api_v1_executor_progress_path, headers: headers, as: :json, params: { frame: frame }
  end

  def assert_refused(code, status: :conflict)
    assert_response status
    assert_equal code, response.parsed_body.dig("error", "code")
  end

  def task_frame(agent_loop, key, token, **payload)
    { agent_loop_public_id: agent_loop.public_id, task_key: key, claim_token: token }.merge(payload)
  end

  test "a claimant's frame is 202 with an empty body, and a burst on the same key is 202 dropped" do
    agent_loop = start!(seed(tool("alpha")))
    token = claim!(agent_loop, "alpha")

    sent = []
    ActionCable.server.stub(:broadcast, ->(name, payload) { sent << [name, payload] }) do
      post_frame(task_frame(agent_loop, "alpha", token, text_tail: "1/3\n", structured: { "n" => 1 }))
      assert_response :accepted
      assert_empty response.body
      post_frame(task_frame(agent_loop, "alpha", token, text_tail: "2/3\n"))
      assert_response :accepted, "a faster poster is answered 202 and the frame dropped, never refused"
    end
    assert_equal 1, sent.length
    frame = sent.sole.last.fetch(:frame)
    assert_equal "executor_progress", frame.fetch("type")
    assert_equal({ "n" => 1 }, frame.fetch("structured"), "an opaque payload member passes through no permit")
    assert_equal "1/3\n", frame.fetch("text_tail")
  end

  # THE STATED PROPERTY (audit rails-native-21: the door's own `rate_limit`
  # over the service's process-local store): at most one broadcast per key
  # per interval, the cadence taken BEFORE any row is read — a burst on
  # one key costs the primary one read and the cable one row; another key
  # is another slot, the same key from another executor its own slot; a
  # keyless frame has no cadence and is refused every time.
  test "the cadence admits one frame per key per interval, cadence first, and a burst is 202 dropped" do
    agent_loop = start!(seed(tool("alpha")))
    token = claim!(agent_loop, "alpha")
    frame = task_frame(agent_loop, "alpha", token, text_tail: "x")

    sent = []
    ActionCable.server.stub(:broadcast, ->(name, payload) { sent << [name, payload] }) do
      20.times do
        post_frame(frame)
        assert_response :accepted
      end
    end
    assert_equal 1, sent.length, "≤ 1 broadcast per key per interval"

    # Cadence first: a dropped frame reads no row — the claim fence is never
    # consulted for it, so a wrong token on a taken key is 202, not 409.
    post_frame(frame.merge(claim_token: "wrong"))
    assert_response :accepted

    # Another key is another slot; the same key from another executor is its
    # own slot too: a provider's process frame on a fresh key reaches the
    # fence (409 not_bound), and a bare key of neither kind has no slot at
    # all — refused 422 every time, never absorbed into a taken one.
    post_frame({ agent_loop_public_id: agent_loop.public_id, process_id: "p9", lines: ["y"] })
    assert_response :accepted
    provider_bearer = bearer(connect_runner(
      manager: users(:owner), runner_identifier: "burst-provider", display_name: "Burst provider",
      assignment_scope: :account_wide, executor_kind: :tools_provider
    ).executor_access_secret)
    post_frame({ agent_loop_public_id: agent_loop.public_id, process_id: "p9", lines: ["y"] }, headers: provider_bearer)
    assert_refused("not_bound")
    2.times do
      post_frame({ agent_loop_public_id: agent_loop.public_id, text_tail: "x" })
      assert_refused("invalid_frame", status: :unprocessable_entity)
    end

    Executors::Progress::RATE.clear
    ActionCable.server.stub(:broadcast, ->(name, payload) { sent << [name, payload] }) { post_frame(frame) }
    assert_response :accepted
    assert_equal 2, sent.length, "a fresh interval admits the next frame"
  end

  test "the claim fence: a stale token is not_claimant, and a settled row is 202 dropped" do
    agent_loop = start!(seed(tool("alpha")))
    token = claim!(agent_loop, "alpha")

    post_frame(task_frame(agent_loop, "alpha", "stale", text_tail: "x"))
    assert_refused("not_claimant")

    Executors::Progress::RATE.clear
    Executors::Commit.call(Executors::Commit::Command.new(
      agent_loop: agent_loop, task_key: "alpha", executor: suite_runner, claim_token: token,
      content: "done", structured_content: nil, result_type: nil, outcome: "completed", is_error: false,
      title: nil, metadata: nil
    ))
    sent = []
    ActionCable.server.stub(:broadcast, ->(name, payload) { sent << [name, payload] }) do
      post_frame(task_frame(agent_loop, "alpha", token, text_tail: "late"))
    end
    assert_response :accepted
    assert_empty sent
  end

  test "the aggregate progress budget admits its last frame then returns 429 while cadence remains independent" do
    agent_loop = start!(seed(tool("alpha")))
    token = claim!(agent_loop, "alpha")
    frame = task_frame(agent_loop, "alpha", token, text_tail: "progress")
    assert_equal 250, Executors::Progress::MIN_INTERVAL_MS
    limit = AgentAPI::V1::Executors::ProgressController.caller_rate_limit
    sent = []
    ActionCable.server.stub(:broadcast, ->(name, payload) { sent << [name, payload] }) do
      prime_caller_rate_limit(count: limit - 1) do
        post_frame(frame)
        assert_response :accepted
      end
      post_frame(frame)
      assert_response :accepted, "the last caller-budget request is accepted even when cadence drops its frame"
      post_frame(frame)
      assert_response :too_many_requests
    end
    assert_equal "rate_limited", response.parsed_body.dig("error", "code")
    assert_equal "60", response.headers["Retry-After"]
    assert_equal 1, sent.length
  end

  # A tools provider is never a binding: its process frame for a host is
  # `not_bound` however it is keyed — the negative the journey's one
  # runner-kind grant cannot pose.
  test "the binding fence: a process frame from an executor that is not the host's bound runner is not_bound" do
    agent_loop = start!(seed(tool("alpha")))
    provider_bearer = bearer(connect_runner(
      manager: users(:owner), runner_identifier: "frame-provider", display_name: "Frame provider",
      assignment_scope: :account_wide, executor_kind: :tools_provider
    ).executor_access_secret)
    frame = { agent_loop_public_id: agent_loop.public_id, process_id: "p1", lines: ["up"] }

    post_frame(frame, headers: provider_bearer)
    assert_refused("not_bound")

    post_frame(frame)
    assert_response :accepted, "the loop's bound runner posts under its own binding"
  end

  test "the envelope bound and the grammar are unprocessable; a member bearer never reaches the door; a stranger's host is absence" do
    agent_loop = start!(seed(tool("alpha")))
    token = claim!(agent_loop, "alpha")

    post_frame(task_frame(agent_loop, "alpha", token, text_tail: "x" * (Nexus::SizeBounds.fetch(:envelope_bound) + 1)))
    assert_refused("frame_too_large", status: :unprocessable_entity)
    post_frame({ agent_loop_public_id: agent_loop.public_id, text_tail: "x" })
    assert_refused("invalid_frame", status: :unprocessable_entity)
    post agent_api_v1_executor_progress_path, headers: runner_bearer, as: :json, params: { nope: 1 }
    assert_refused("invalid_frame", status: :unprocessable_entity)

    post_frame(task_frame(agent_loop, "alpha", token, text_tail: "x"), headers: bearer(@member.secret))
    assert_response :unauthorized

    post_frame({ conversation_public_id: SecureRandom.uuid, process_id: "p1", lines: ["up"] })
    assert_response :not_found
  end
end
