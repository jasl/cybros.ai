require "test_helper"
require "async"

class ExecutionContextFiberTest < Minitest::Test
  def test_overlapping_fibers_keep_their_own_context_and_restore_it_after_nested_binding
    first = Rho::Runner::ExecutionContext.new(task_key: "first")
    second = Rho::Runner::ExecutionContext.new(task_key: "second")
    resume = Thread::Queue.new
    observed = []
    Async do |parent|
      one = parent.async do
        Rho::Runner::ExecutionContext.with(first) do
          resume.pop
          observed << Rho::Runner::ExecutionContext.current
          Rho::Runner::ExecutionContext.with(second) do
            assert_same second, Rho::Runner::ExecutionContext.current
          end
          observed << Rho::Runner::ExecutionContext.current
        end
      end
      two = parent.async do
        Rho::Runner::ExecutionContext.with(second) do
          resume << true
          sleep 0.01
          observed << Rho::Runner::ExecutionContext.current
        end
      end
      one.wait
      two.wait
      assert_nil Rho::Runner::ExecutionContext.current
    end.wait
    assert_equal [first, first, second], observed
    assert_nil Rho::Runner::ExecutionContext.current
  end
end

class ExecutionContextStartupTest < Minitest::Test
  def test_queued_work_keeps_control_checks_without_renewal_or_an_overdue_ask_busy_wait
    time = 0.0
    clock = -> { time }
    asks = []
    extension = Rho::Runner::DeadlineExtension.new(park_seconds: 2,
      deadline_at: "initial", clock: clock) do
      asks << true
      [20.0, "extended", 10.0]
    end
    posted = []
    progress = Rho::Runner::Progress.new(clock: clock, post: ->(text) { posted << text; true })
    context = Rho::Runner::ExecutionContext.new(deadline: 10.0, clock: clock, extension: extension,
      progress: progress)
    time = 3.0
    assert_equal 0.25, context.wait_slice(extend: false), "an overdue ask must not spin while startup is queued"
    progress.tail("waiting")
    context.renew!(extend: false)
    assert_equal ["waiting"], posted
    assert_empty asks
    assert_equal 10.0, context.deadline
    assert_equal 0, context.wait_slice
    context.renew!
    assert_equal [true], asks
    assert_equal 20.0, context.deadline
  end

  def test_queued_work_still_reads_and_cancels_an_inactive_claim
    time = 0.0
    clock = -> { time }
    reads = []
    transport = lambda do |path, **request|
      reads << [path, request]
      CybrosAgent::Response.new(status: 200, headers: {}, body: { "claim" => { "active" => false } })
    end
    executor = CybrosAgent::ExecutorClient.new(base_url: "http://nexus.test", transport: transport,
      credential_provider: -> { "executor-token" })
    poller = Rho::Runner::ClaimStatusPoller.new(task: executor.inbox_task(run_public_id: "run", task_key: "queued"),
      claim_token: "original-claim", worker_count: 1, clock: clock, log: nil)
    context = Rho::Runner::ExecutionContext.new(deadline: 10.0, clock: clock, claim_poller: poller)
    time = 5.0
    context.renew!(extend: false)
    assert_equal 1, reads.length
    assert_equal :canceled, context.reason
    assert context.cancelled?
  end
end

# THE PLACEMENT ON THE CONTEXT: the run sets the
# resolved env and the record ONCE, inside the pool block, before the
# `tool_call` chain — the hook chain's view (the Guard resolves a relative
# path through it; the capture hook reads its store). Nothing built outside
# a run has one; a test hands one in at construction.
class ExecutionContextPlacementTest < Minitest::Test
  Context = Rho::Runner::ExecutionContext
  Binding = Rho::Runner::Environment::Binding

  def env = Rho::Runner::ToolEnv.new(root: Dir.tmpdir, artifacts_dir: File.join(Dir.tmpdir, "a"))

  def test_a_context_carries_no_placement_until_placed
    context = Context.new

    assert_nil context.tool_env
    assert_nil context.binding
  end

  def test_placed_once_inside_the_run_and_a_second_placement_is_refused
    context = Context.new
    placed = env
    binding = Binding.new(root: placed.root, directories: [], anchor: "conv-1")

    context.place(tool_env: placed, binding: binding)

    assert_same placed, context.tool_env
    assert_same binding, context.binding
    assert_raises(ArgumentError) { context.place(tool_env: env, binding: nil) }
    assert_same placed, context.tool_env, "the first placement stands"
  end

  def test_a_placement_at_construction_is_the_tests_shape_and_zero_has_no_record
    placed = env
    context = Context.new(tool_env: placed)

    assert_same placed, context.tool_env
    assert_nil context.binding
    assert_raises(ArgumentError) { context.place(tool_env: placed, binding: nil) }
  end
end

# THE PORT ON THE CONTEXT: the port is a
# PER-CALL LOOKUP through a resolver keyed by the binding's anchor — set
# once per dispatch with the placement, never a member of the frozen
# `ToolEnv` — so a port dropped between two calls is gone at the second,
# and a context with no anchor (placement zero, a standalone loop) asks
# the resolver nothing.
class ExecutionContextPortTest < Minitest::Test
  Context = Rho::Runner::ExecutionContext
  Binding = Rho::Runner::Environment::Binding

  def env = Rho::Runner::ToolEnv.new(root: Dir.tmpdir, artifacts_dir: File.join(Dir.tmpdir, "a"))

  def test_no_port_until_placed_with_a_resolver
    assert_nil Context.new.port
    context = Context.new
    context.place(tool_env: env, binding: Binding.new(root: Dir.tmpdir, directories: [], anchor: "conv-1"))
    assert_nil context.port, "placed with no resolver: no port"
  end

  def test_the_resolver_is_asked_with_the_anchor_on_every_call
    port = Object.new
    asked = []
    table = { "conv-1" => port }
    context = Context.new
    context.place(tool_env: env, binding: Binding.new(root: Dir.tmpdir, directories: [], anchor: "conv-1"),
      ports: ->(anchor) { asked << anchor; table[anchor] })

    assert_same port, context.port
    table.delete("conv-1")
    assert_nil context.port, "a per-call lookup sees the drop"
    assert_equal %w[conv-1 conv-1], asked
  end

  def test_a_context_with_no_anchor_asks_nothing
    asked = []
    context = Context.new(tool_env: env, ports: ->(anchor) { asked << anchor; Object.new })

    assert_nil context.port, "placement zero has no anchor"
    assert_empty asked
  end

  def test_the_resolver_at_construction_is_the_tests_shape
    port = Object.new
    context = Context.new(tool_env: env, binding: Binding.new(root: Dir.tmpdir, directories: [], anchor: "a"),
      ports: ->(_anchor) { port })

    assert_same port, context.port
    assert_raises(ArgumentError) { context.place(tool_env: env, binding: nil, ports: nil) }
  end
end
