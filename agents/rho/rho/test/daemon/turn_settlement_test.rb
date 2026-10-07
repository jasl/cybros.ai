require "test_helper"
require_relative "../support/memory_review_fixtures"
require "support/host_follower_harness"

class TurnSettlementTest < Minitest::Test
  include RhoTest::HostFollowerHarness

  Fixtures = RhoTest::MemoryReviewFixtures
  Snapshot = Data.define(:status, :turn, :run_public_id)
  Run = Data.define(:public_id, :snapshot)
  Loaded = Data.define(:daemon_hooks)
  Followed = Data.define(:workspace)
  Client = Data.define(:workspace_row) do
    def workspace(_public_id) = workspace_row
  end

  class Follower
    Snapshot = Data.define(:blocked)
    attr_accessor :blocked
    attr_reader :handlers
    def initialize = @handlers = {}
    def snapshot = Snapshot.new(blocked: @blocked)
    def listen(&handler)
      token = @handlers.length + 1
      @handlers[token] = handler
      token
    end
    def forget(token) = @handlers.delete(token)
  end

  class Context
    attr_reader :followed, :forgotten, :followers
    attr_accessor :on_adopt
    def initialize(workspace)
      @workspace, @followed, @forgotten, @followers = workspace, [], [], {}
    end
    def member_plane(workspace_public_id:) = yield(Client.new(workspace_row: @workspace), workspace_public_id, :about)
    def own_user_public_id = "agent"
    def spawn(&work) = work.call
    def adopt_follower(_about, host, hosted, _body, runs:)
      @followed << host.public_id
      follower = (@followers[host.public_id] ||= Follower.new)
      @on_adopt&.call(hosted, follower)
      follower
    end
    def forget(host) = @forgotten << host.public_id
  end

  class AsyncContext < Context
    attr_reader :jobs
    def initialize(workspace)
      super
      @jobs = []
    end
    def spawn(&work)
      job = Fiber.new(&work)
      @jobs << job
      job.resume
      job
    end
  end

  class QueuedContext < Context
    def initialize(workspace)
      super
      @jobs = []
    end
    def spawn(&work) = @jobs << work
    def drain
      @jobs.shift.call until @jobs.empty?
    end
  end

  class Log
    attr_reader :events
    def initialize = @events = []
    def warn(name, **fields) = @events << [name, fields]
  end

  class Host
    include Rho::Daemon::HostFollowers::Settlement
    include Rho::Daemon::HostFollowers::Sides

    def initialize(hooks, log, context = nil)
      @loaded, @log, @context = Loaded.new(daemon_hooks: hooks), log, context || Context.new(nil)
    end

    def complete(run, hosted) = follow_completed(run, nil, hosted)
    def attention(run, attention, source, hosted)
      follow_attention(run, attention, nil, source, hosted: hosted)
    end
    def follow_settled_model(*) = nil
    def follow_row(*) = Followed.new(workspace: "workspace")
  end

  def setup
    @log = Log.new
    @conversation = Fixtures::Conversation.new
    @source = Fixtures::Turn.new(public_id: "turn", position: 1, kind: "direct_reply", status: "completed",
      visibility: "visible", inherited: false, created_at: "2026-10-07T01:00:00Z",
      active_variant: Fixtures::Variant.new(run_public_id: "source", status: "completed", memory_context: { "bindings" => [] },
        prompt_text: "hello", content: "answer", model: CybrosAgent::Api::ConversationModel.new(
          provider_id: "provider", model_ref: "model", reasoning_effort: nil)))
    @conversation.turns.rows["turn"] = @source
    @run = Run.new(public_id: "conversation-1", snapshot: Snapshot.new(status: "completed", turn: "turn", run_public_id: "source"))
  end

  def test_settlement_hook_carries_status_model_memory_context_and_the_existing_context
    events = []
    context = Context.new(nil)
    host = Host.new([hook { |event, ctx| events << [event, ctx] }], @log, context)
    host.complete(@run, @conversation)

    expected = Rho::TurnSettlement.new(workspace_public_id: "workspace", conversation_public_id: "conversation-1",
      turn_public_id: "turn", run_public_id: "source", status: "completed", model: "provider/model", memory_context: { "bindings" => [] })
    assert_equal [[expected, context]], events
  end

  def test_failed_and_canceled_turns_reach_the_same_formal_settlement_hook
    events = []
    host = Host.new([hook { |event, _ctx| events << event }], @log)
    %w[failed canceled].each do |status|
      @conversation.turns.rows["turn"] = @source.with(status: status, active_variant: @source.active_variant.with(status: status))
      host.complete(@run.with(snapshot: @run.snapshot.with(status: status)), @conversation)
    end
    assert_equal %w[failed canceled], events.map(&:status)
  end

  def test_running_replaced_and_inherited_turns_never_trigger_settlement
    events = []
    host = Host.new([hook { |event, _ctx| events << event }], @log)
    host.complete(@run.with(snapshot: @run.snapshot.with(status: "running")), @conversation)
    [@source.with(kind: "message"), @source.with(inherited: true),
      @source.with(active_variant: @source.active_variant.with(run_public_id: "replacement"))].each do |turn|
      @conversation.turns.rows["turn"] = turn
      host.complete(@run, @conversation)
    end
    assert_empty events
  end

  def test_failed_observer_does_not_revoke_the_result_or_stop_later_observers
    events = []
    host = Host.new([hook { raise Rho::Error, "review failed" }, hook { |event, _ctx| events << event }], @log)
    host.complete(@run, @conversation)

    assert_equal 1, events.length
    assert_equal "completed", @run.snapshot.status
    assert_equal "turn_settled_hook_failed", @log.events.first.first
  end

  def test_a_reference_snapshot_with_no_run_never_triggers_settlement
    events = []
    host = Host.new([hook { |event, _ctx| events << event }], @log)
    @conversation.turns.rows["turn"] = @source.with(reference: true,
      active_variant: @source.active_variant.with(run_public_id: nil))

    host.complete(@run.with(snapshot: @run.snapshot.with(run_public_id: nil)), @conversation)

    assert_empty events
  end

  def test_retirement_waits_for_the_admitted_hook_then_releases_its_resources
    cleaned = false
    resources = Rho::Runner::Extensions::Resources.new(extension: "test")
    resources.own { cleaned = true }
    handler = hook(owner: resources) do |_event, _ctx|
      refute resources.retire
      refute cleaned
      raise Rho::Error, "failed while retiring"
    end
    Host.new([handler], @log).complete(@run, @conversation)

    assert cleaned
    assert resources.disposed?
  end

  def test_a_restarted_follower_replays_the_actual_hook_and_recovers_its_unknown_side
    workspace = Fixtures::Workspace.new
    conversation = workspace.conversation_row
    review = -> { Rho::MemoryReview.new(workspace: workspace, conversation_public_id: "conversation-1") }
    review.call.enable(path: "conversation/review.md")
    conversation.turns.rows["turn"] = @source.with(active_variant: @source.active_variant.with(memory_context: nil))
    workspace.lose_fork = true
    context = Context.new(workspace)

    2.times do
      loaded = Rho::Extensions.load(host: RhoTest.host, extensions: [Rho::Extensions::MemoryReview])
      assert_predicate loaded, :ok?
      owner = Host.new(loaded.daemon_hooks, @log, context)
      follower = run_for([page(settle_event(1, "completed", turn_public_id: "turn", run_public_id: "source"))],
        host: Rho::Host::Conversation.new(public_id: "conversation-1"), run_public_id: "source", turn: "turn",
        on_complete: ->(finished) { owner.complete(finished, conversation); finished.stop })
      follower.follow
      loaded.registrations.each { |registration| registration.resources.retire }
    end

    assert_equal 2, workspace.rows.length
    assert_equal 2, workspace.forks.length
    assert_equal workspace.forks.first, workspace.forks.last
    assert_equal 1, workspace.conversation("side-1").inputs.records.length
    assert review.call.status.fetch("pending")
    assert_equal ["side-1"], context.followed
    assert_equal 1, @log.events.count { |event, _fields| event == "turn_settled_hook_failed" }
  end

  def test_actual_follower_failure_and_cancellation_callbacks_close_the_review
    %w[failed canceled].each do |status|
      workspace = Fixtures::Workspace.new
      conversation = workspace.conversation_row
      review = Rho::MemoryReview.new(workspace: workspace, conversation_public_id: "conversation-1")
      review.enable(path: "conversation/review.md")
      source = @source.with(active_variant: @source.active_variant.with(memory_context: nil))
      conversation.turns.rows["turn"] = source
      review.settled(Rho::TurnSettlement.new(workspace_public_id: "workspace", conversation_public_id: "conversation-1",
        turn_public_id: source.public_id, run_public_id: "source", status: "completed", model: "test/model", memory_context: nil))
      side = workspace.conversation("side-1")
      turn = side.settle(content: "", status: status)
      context = Context.new(workspace)
      loaded = Rho::Extensions.load(host: RhoTest.host, extensions: [Rho::Extensions::MemoryReview])
      owner = Host.new(loaded.daemon_hooks, @log, context)
      follower = run_for([page(settle_event(1, status, run_status: "canceled", turn_public_id: turn.public_id, run_public_id: turn.active_variant.run_public_id))],
        host: Rho::Host::Conversation.new(public_id: side.public_id), run_public_id: turn.active_variant.run_public_id, turn: turn.public_id,
        on_complete: ->(finished) { owner.complete(finished, side); finished.stop })
      follower.follow

      result = Rho::MemoryReview.new(workspace: workspace, conversation_public_id: "conversation-1").status
      assert_equal status, result.fetch("outcome")
      refute result.fetch("pending")
      assert_equal ["side-1"], context.forgotten
      loaded.registrations.each { |registration| registration.resources.retire }
    end
  end

  def test_pending_review_submission_does_not_delay_the_main_completion_event_and_holds_its_owner
    workspace = Class.new(Fixtures::Workspace) do
      def fork(...)
        Fiber.yield
        super
      end
    end.new
    conversation = workspace.conversation_row
    review = -> { Rho::MemoryReview.new(workspace: workspace, conversation_public_id: "conversation-1") }
    review.call.enable(path: "conversation/review.md")
    conversation.turns.rows["turn"] = @source.with(active_variant: @source.active_variant.with(memory_context: nil))
    context = AsyncContext.new(workspace)
    loaded = Rho::Extensions.load(host: RhoTest.host, extensions: [Rho::Extensions::MemoryReview])
    owner = Host.new(loaded.daemon_hooks, @log, context)
    follower = run_for([page(settle_event(1, "completed", turn_public_id: "turn", run_public_id: "source"))],
      host: Rho::Host::Conversation.new(public_id: "conversation-1"), run_public_id: "source", turn: "turn",
      on_complete: ->(finished) { owner.complete(finished, conversation) })
    delivered = []
    follower.listen { |event| delivered << event; follower.stop }
    follower.follow

    assert_equal ["turn_status"], delivered.map(&:type)
    assert_equal "completed", follower.snapshot.status
    assert review.call.status.fetch("pending"), "the exact source snapshot is durable before fork submission waits"
    assert_empty workspace.forks
    resources = loaded.registrations.first.resources
    refute resources.retire, "the accepted callback retains its extension during submission"
    context.jobs.each(&:resume)
    assert_equal 1, workspace.forks.length
    assert_predicate resources, :disposed?
  end

  def test_a_failed_turn_after_the_attention_event_cancels_its_held_review
    workspace = Fixtures::Workspace.new
    conversation = workspace.conversation_row
    review = Rho::MemoryReview.new(workspace: workspace, conversation_public_id: "conversation-1")
    review.enable(path: "conversation/review.md")
    source = @source.with(active_variant: @source.active_variant.with(memory_context: nil))
    conversation.turns.rows["turn"] = source
    review.settled(Rho::TurnSettlement.new(workspace_public_id: "workspace", conversation_public_id: "conversation-1",
      turn_public_id: "turn", run_public_id: "source", status: "completed", model: "test/model", memory_context: nil))
    side = workspace.conversation("side-1")
    turn = side.settle(content: "", status: "failed")
    context = Context.new(workspace)
    loaded = Rho::Extensions.load(host: RhoTest.host, extensions: [Rho::Extensions::MemoryReview])
    owner = Host.new(loaded.daemon_hooks, @log, context)
    run_id = turn.active_variant.run_public_id
    notices = []
    follower = run_for([page(
      note_event(1, "needs_attention", turn_public_id: turn.public_id, run_public_id: run_id),
      event(2, "attention_required", { "reason" => "halt_failure", "run_public_id" => run_id }),
      settle_event(3, "failed", turn_public_id: turn.public_id, run_public_id: run_id)
    )], host: Rho::Host::Conversation.new(public_id: side.public_id), run_public_id: run_id, turn: turn.public_id,
      on_attention: lambda { |current, attention, source_run|
        notices << current.snapshot.status
        owner.attention(current, attention, source_run, side)
        current.stop if current.snapshot.status == "failed"
      })
    follower.follow

    assert_equal %w[pending failed], notices
    assert_equal 1, side.cancellations
    result = Rho::MemoryReview.new(workspace: workspace, conversation_public_id: "conversation-1").status
    assert_equal "failed", result.fetch("outcome")
    refute result.fetch("pending")
    loaded.registrations.each { |registration| registration.resources.retire }
  end

  def test_a_blocked_input_before_attachment_or_after_following_closes_the_review
    %i[before after].each do |timing|
      workspace = Fixtures::Workspace.new
      conversation = workspace.conversation_row
      review = -> { Rho::MemoryReview.new(workspace: workspace, conversation_public_id: "conversation-1") }
      review.call.enable(path: "conversation/review.md")
      conversation.turns.rows["turn"] = @source.with(active_variant: @source.active_variant.with(memory_context: nil))
      context = QueuedContext.new(workspace)
      block_input = ->(side, follower) do
        id, input = side.inputs.records.first
        side.inputs.records[id] = input.with(state: "blocked")
        follower.blocked = { input_public_id: id, blocked_reason: "invalid_input" }
      end
      context.on_adopt = block_input if timing == :before
      loaded = Rho::Extensions.load(host: RhoTest.host, extensions: [Rho::Extensions::MemoryReview])
      Host.new(loaded.daemon_hooks, @log, context).complete(@run, conversation)
      context.drain
      side = workspace.conversation("side-1")
      followed = context.followers.fetch("side-1")
      if timing == :after
        block_input.call(side, followed)
        blocked = event(1, "input_blocked", { "input_public_id" => "input-1", "blocked_reason" => "invalid_input" })
        followed.handlers.values.each { |handler| handler.call(blocked) }
        context.drain
      end

      assert_equal "failed", review.call.status.fetch("outcome")
      refute review.call.status.fetch("pending")
      assert_empty side.inputs.records
      assert_equal 1, side.cancellations
      assert_empty followed.handlers, "finishing removes the observer with its follower"
      loaded.registrations.each { |registration| registration.resources.retire }
    end
  end

  def test_retiring_memory_review_unsubscribes_its_existing_follower
    workspace = Fixtures::Workspace.new
    conversation = workspace.conversation_row
    Rho::MemoryReview.new(workspace: workspace, conversation_public_id: "conversation-1").enable(path: "conversation/review.md")
    conversation.turns.rows["turn"] = @source.with(active_variant: @source.active_variant.with(memory_context: nil))
    context = QueuedContext.new(workspace)
    loaded = Rho::Extensions.load(host: RhoTest.host, extensions: [Rho::Extensions::MemoryReview])
    Host.new(loaded.daemon_hooks, @log, context).complete(@run, conversation)
    context.drain
    follower = context.followers.fetch("side-1")
    assert_equal 1, follower.handlers.length

    loaded.registrations.each { |registration| registration.resources.retire }

    assert_empty follower.handlers
    assert_equal 0, workspace.conversation("side-1").cancellations, "retiring an observer does not cancel accepted kernel work"
  end

  def test_overlapping_source_callbacks_consume_the_busy_source_before_restart_replay
    workspace = Fixtures::Workspace.new
    conversation = workspace.conversation_row
    review = -> { Rho::MemoryReview.new(workspace: workspace, conversation_public_id: "conversation-1") }
    review.call.enable(path: "conversation/review.md")
    turns = [1, 2].map do |position|
      @source.with(public_id: "turn-#{position}", position: position,
        active_variant: @source.active_variant.with(run_public_id: "source-#{position}", memory_context: nil))
    end
    turns.each { |turn| conversation.turns.rows[turn.public_id] = turn }
    settlements = turns.map do |turn|
      Rho::TurnSettlement.new(workspace_public_id: "workspace", conversation_public_id: "conversation-1",
        turn_public_id: turn.public_id, run_public_id: turn.active_variant.run_public_id,
        status: "completed", model: "test/model", memory_context: nil)
    end
    resources = Rho::Runner::Extensions::Resources.new(extension: "memory-review")
    observer = Rho::Extensions::MemoryReview::Observer.new(resources: resources, log: nil)
    context = Context.new(workspace)
    Async do |task|
      gate = Async::Condition.new
      original = conversation.turns.method(:fetch)
      waiting = true
      conversation.turns.define_singleton_method(:fetch) do |id, **options|
        if id == "turn-1" && waiting
          waiting = false
          gate.wait
        end
        original.call(id, **options)
      end
      first = task.async { observer.settled(settlements.first, context) }
      second = task.async { observer.settled(settlements.last, context) }
      gate.signal
      first.wait
      second.wait
    end

    assert_equal 2, review.call.state.after_position
    assert_equal "source-1", review.call.state.pending.input.fetch("run_public_id")
    assert_equal 1, workspace.forks.length
    workspace.conversation("side-1").settle(content: JSON.generate(content: "Reviewed request 1.", summary: ""))
    review.call.resume
    observer.close
    restarted = Rho::Extensions::MemoryReview::Observer.new(resources: resources, log: nil)
    restarted.settled(settlements.last, context)

    refute review.call.status.fetch("pending")
    assert_equal 1, workspace.forks.length, "a source consumed while busy is never extracted after restart"
    restarted.close
    resources.retire
  end

  private

    def hook(owner: nil, &handler)
      Rho::Runner::Extensions::Hooks::Registration.new(event: :turn_settled, extension: "test", handler: handler, owner: owner)
    end
end
