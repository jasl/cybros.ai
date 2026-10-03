require "test_helper"
require "async"
require "cgi/escape"
require "securerandom"
require "support/actor_provisioning"
require "support/realtime_lane"

# THE KERNEL'S OWN FRAMES, CROSS-PROCESS.
#
# A round dialled, a tool row live with its name, an executor's claim —
# three facts no row or settled item carries at the instant they happen —
# ride the host's `progress` feed as EPHEMERAL FRAMES the kernel mints at
# its own seams. This lane authors ONE standalone loop through the shipped
# SDK on the mock: a model step that calls the kernel's `task` with
# `wait: true` (W-mf5 / M-mf4), so the branch is spliced under the
# continuation and the whole run is a strict chain on ONE stream — the
# order of the SEAMS is then a fact, not a race — and subscribes through
# the shipped `agent_loop.progress(realtime:)` and `transcript(realtime:)`
# BEFORE the loop starts, as a consumer must.
#
# ONE ORDER THE STREAM DOES NOT STATE: the two `step_started` frames of one call key — the park and
# the release — are published by two `after_commit` hooks at one commit with no sequence
# between them (`ProgressStream.transition`), so their wire order is no stated fact of the kernel's;
# `at` is minted at each decision and is the one monotonic fact. The lane reads one call key's
# frames by `at` before asserting (`ordered_within_call`); the product answer — a per-host sequence
# on frames the SDK orders by — is the owner's.
#
# What it asserts is the SEQUENCE and the IDENTITIES: the authored round
# dialled first (`spine: true`, the model, attempt 1, and `request_bytes`
# EQUAL to the task read's — the stored size, never a second copy), the
# `task` call held then run (the approval stage crosses under `bypass` as
# well — both transitions are news — and a kernel tool runs in the
# kernel's own job: no executor, no grant, no claim), the branch root
# dialled off the spine, the continuation dialled on it, and nothing else
# (no wake round exists under `wait: true`). NO timing bound anywhere, no
# `elapsed` (there is none: a round's END is the settled `round` on
# `transcript`, whose `started_at`/`completed_at` are the timing — asserted
# here by presence), no count over a table window, no late-subscriber
# negative. The claim word, the hidden gate, the eager decision and "a
# frame writes no row" are nexus unit pins (`progress_stream_test`).
class LoopTimingsTest < Minitest::Test
  include E2E::RealtimeLane

  MODEL = "dev/mock-text".freeze
  LOOP_TIMEOUT = 90
  POLL = 0.5
  AT = /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/
  # The kernel's spelling off an authored first round: `round1` reads no
  # `r<n>` fan of its own, its calls take the CONTINUATION's number (`r1`
  # is free, so `r1t0` is the call and `r1` the round that reads it), and
  # the waited branch's root hangs under the call by prefix.
  ROUND = "round1".freeze
  CALL = "r1t0".freeze
  ROOT = "r1t0-model-1".freeze
  CONTINUATION = "r1".freeze

  def setup
    @base_url = E2E.base_url
    @actor = E2E::ActorProvisioning.world(@base_url).shared_human
    @api = CybrosAgent::Client.new(base_url: @base_url, credential: @actor.member_token)
    E2E.enable_dev_lane!
    E2E.hosts.start
    @workspace = @api.workspaces.create(
      name: "Loop timings #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid
    )
  end

  def test_the_kernel_narrates_a_round_dialled_a_step_started_and_the_branch_under_a_waited_task_call_in_order
    context = author_waiting_loop!
    frames = []
    items = []

    with_reactor do
      endpoint = CybrosAgent::Realtime::Endpoint.new(base_url: @base_url, credential: @actor.member_token)
      @client = CybrosAgent::Realtime::Client.new(endpoint: endpoint)
      progress = context.progress(realtime: @client).call
      transcript = context.transcript(realtime: @client).call
      pumps = [
        Async { progress.each { |frame| frames << frame } },
        Async { transcript.each { |item| items << item } },
      ]
      context.start
      await("the loop's completion") do
        row = context.fetch
        flunk "the loop failed: #{row.inspect}" if row.status == "failed"
        row if row.status == "completed"
      end
      # THE END IS THE TRANSCRIPT'S: the frames are published before the
      # rows they narrate settle, and the CONTINUATION's `round` item is
      # the last row this loop settles — so the pumps stop once it has
      # arrived with its end stamped, never on a wall-clock silence.
      await("the continuation's settled round on the transcript feed") do
        items.find { |item| item.round? && item.task_key == CONTINUATION && item.payload.dig("round", "completed_at") }
      end
      [progress, transcript].each(&:unsubscribe)
      pumps.each { |pump| quiet(pump) }
    end

    # (1) THE SEQUENCE, on one stream: the round dialled, the call held and
    # run, the branch root dialled, the continuation dialled — and nothing
    # else. Under `wait: true` no wake round exists; a kernel tool has no
    # claimant, so `step_claimed` never appears. The call's own pair is
    # read by `at` (the header's seam); every other position is the wire's.
    ordered = ordered_within_call(frames)
    assert_equal [
      ["round_started", ROUND], ["step_started", CALL], ["step_started", CALL],
      ["round_started", ROOT], ["round_started", CONTINUATION],
    ], ordered.map { |frame| [frame.type, frame.task_key] }, frames.map(&:to_h).inspect
    assert_equal %w[needs_approval running], ordered.select(&:step_started?).map { |frame| frame.payload.fetch("status") },
      "the stage crosses under bypass (held), then the kernel's own job runs the call — by `at`, the decisions' order"
    assert_equal ["task", "task"], ordered.select(&:step_started?).map(&:tool_name), "the row's name rides with its status"
    assert frames.none?(&:step_claimed?), "a kernel tool runs in the kernel's own job: nobody claims it"
    frames.each do |frame|
      assert_equal context.agent_loop_public_id, frame.agent_loop_public_id
      assert_nil frame.executor_public_id, "no executor anywhere in this loop: #{frame.to_h.inspect}"
      assert_match AT, frame.at, "milliseconds on the wire"
      refute frame.payload.key?("elapsed"), "an end is the settled snapshot's, never a frame's"
    end
    assert_equal ordered.map(&:at), ordered.map(&:at).sort,
      "`at` never runs backwards along one stream: each seam's commit lands after the last one's"

    # (2) THE IDENTITIES: the mark, the model, the attempt, and the sealed
    # size EQUAL to the task read's — one stored fact, read twice.
    started, root, continuation = ordered.select(&:round_started?)
    assert_equal({ "spine" => true, "attempt" => 1, "model" => MODEL }, started.payload.except("request_bytes"))
    assert_equal context.task(ROUND).request_bytes, started.payload.fetch("request_bytes"),
      "`request_bytes` is the size the request was sealed with, the number the task read serves"
    assert_kind_of Integer, started.payload.fetch("request_bytes")
    assert_equal false, root.payload.fetch("spine"), "the branch root is off the spine"
    assert_equal true, continuation.payload.fetch("spine"), "the continuation is on it"
    assert_equal [1, 1], [root, continuation].map { |frame| frame.payload.fetch("attempt") }
    assert_equal context.task(CONTINUATION).request_bytes, continuation.payload.fetch("request_bytes")

    # (3) THE END IS THE SNAPSHOT: each round's `round` item on the
    # transcript feed carries its timing under the SAME keys the frame
    # carried, so a client correlates the two feeds by one field.
    settled = items.select(&:round?).to_h { |item| [item.task_key, item.payload.fetch("round")] }
    assert_equal [ROUND, ROOT, CONTINUATION].sort, settled.keys.sort, items.map(&:to_h).inspect
    settled.each_value do |round|
      refute_nil round["started_at"], "a settled round carries its start: #{round.inspect}"
      refute_nil round["completed_at"], "and its end — the timing a client subtracts: #{round.inspect}"
    end
    assert items.select(&:round?).all? { |item| item.agent_loop_public_id == context.agent_loop_public_id }
    assert_equal [true, false, true], [ROUND, ROOT, CONTINUATION].map { |key| settled.fetch(key).fetch("spine") }

    # (4) THE GRAPH AGREES: the trace holds exactly those keys, in that
    # family — the mock made one call, the kernel ran it, waited, and went on.
    tasks = context.fetch.tasks
    assert_equal [ROUND, CALL, ROOT, CONTINUATION].sort, tasks.map(&:key).sort, tasks.map(&:to_h).inspect
    assert_equal "task", tasks.find { |task| task.key == CALL }.tool_name
    assert tasks.all? { |task| task.status == "completed" }, tasks.map(&:to_h).inspect
  end

  private

    # The shape: one authored model round on the mock calling the kernel's
    # `task` — its definition spliced verbatim from the catalog — with the
    # branch's own prompt and `wait: true`, under `bypass`. Created, not
    # started: the subscriptions open first.
    def author_waiting_loop!
      definition = @api.tools.definitions_for(["nexus.graph.task"]).first
      arguments = CGI.escape(JSON.generate("prompt" => "!mock -- the branch's answer", "wait" => true))
      created = @api.workspace(@workspace.public_id).agent_loops.create(
        steps: [{ "model" => {
          "key" => ROUND, "model" => { "model" => MODEL }, "tools" => [definition],
          "prompt" => "!mock tool_call=task tool_args=#{arguments} -- the round after the branch",
        } }],
        approval_mode: "bypass", idempotency_key: SecureRandom.uuid
      )
      @api.workspace(@workspace.public_id).agent_loop(created.agent_loop.public_id)
    end

    # ONE CALL KEY'S FRAMES BY `at` (the header's seam): the `step_started`
    # frames of each call key are re-read in `at` order at the positions
    # they arrived in — two frames of one key with one millisecond keep the
    # wire's order — and every other frame keeps its place, so the seams'
    # order stays the wire's fact and only the pair's is the decisions'.
    def ordered_within_call(frames)
      replacements = frames.each_index.select { |index| frames[index].step_started? }
        .group_by { |index| frames[index].task_key }
        .flat_map do |_key, positions|
          positions.zip(positions.sort_by.with_index { |index, arrival| [frames[index].at, arrival] })
        end.to_h { |position, source| [position, frames[source]] }
      frames.each_with_index.map { |frame, index| replacements.fetch(index, frame) }
    end

    def await(what)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LOOP_TIMEOUT
      loop do
        result = yield
        return result if result
        flunk("the deployment never reached #{what}") if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep POLL
      end
    end

    # A pump ends when its subscription does; whichever way, it is not the
    # lane's assertion.
    def quiet(pump)
      pump.wait
    rescue StandardError
      nil
    end
end
