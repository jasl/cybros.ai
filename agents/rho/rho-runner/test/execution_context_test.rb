require "test_helper"

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
