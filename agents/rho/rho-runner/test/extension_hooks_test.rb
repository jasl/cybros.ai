require "test_helper"

# THE TWO HOOKS AROUND A TOOL CALL, and the two opposite postures that
# make them safe: a gate that can be bypassed by raising is not a gate,
# and an observer that can destroy a real answer is not an observer.
class ExtensionHooksTest < Minitest::Test
  Hooks = Rho::Runner::Extensions::Hooks

  def host(*registrations) = Hooks::Host.new(registrations)

  def registration(event, extension = "rho.x", &handler)
    Hooks::Registration.new(event: event, extension: extension, handler: handler)
  end

  def test_no_hooks_means_the_arguments_and_the_result_pass_straight_through
    empty = Hooks::Host.new
    args = { "path" => "a.rb" }
    result = Rho::Runner::Result.ok("done")

    assert_same args, empty.before_call("read", args)
    assert_same result, empty.after_result("read", result)
    refute empty.any?(:tool_call)
  end

  def test_a_tool_call_hook_may_rewrite_the_arguments
    rewriting = host(registration(:tool_call) do |_name, args|
      Hooks::Rewrite.new(arguments: args.merge("path" => "safe.rb"))
    end)

    assert_equal({ "path" => "safe.rb" }, rewriting.before_call("read", { "path" => "/etc/passwd" }))
  end

  def test_a_handler_with_no_opinion_changes_nothing
    quiet = host(registration(:tool_call) { |_name, _args| nil })
    assert_equal({ "x" => 1 }, quiet.before_call("read", { "x" => 1 }))
  end

  # FAIL-CLOSED: a gate that raises has not decided, and for a gate that
  # is a refusal. Anything else means a hook can be bypassed by throwing.
  def test_a_raising_tool_call_hook_vetoes_rather_than_letting_the_call_through
    exploding = host(registration(:tool_call) { |_name, _args| raise "boom" })

    veto = exploding.before_call("bash", { "command" => "rm -rf /" })

    assert_instance_of Hooks::Veto, veto
    assert_match(/boom/, veto.reason)
  end

  # The FIRST veto stops the chain — a refusal is not something a later
  # hook gets to overturn.
  def test_the_first_veto_stops_the_chain
    reached = []
    chained = host(
      registration(:tool_call, "first") { |_n, _a| Hooks::Veto.new(extension: "first", reason: "no") },
      registration(:tool_call, "second") { |_n, _a| reached << :second; nil }
    )

    assert_instance_of Hooks::Veto, chained.before_call("bash", {})
    assert_empty reached, "a later hook must not get to overturn a refusal"
  end

  # FAIL-OPEN: the tool already ran and the work is done. Losing a real
  # answer because a formatter raised turns an observer into a destroyer.
  def test_a_raising_tool_result_hook_leaves_the_answer_intact
    original = Rho::Runner::Result.ok("the real answer")
    exploding = host(registration(:tool_result) { |_name, _result| raise "boom" })

    assert_same original, exploding.after_result("read", original)
  end

  def test_a_tool_result_hook_may_replace_the_answer
    rewriting = host(registration(:tool_result) do |_name, result|
      Rho::Runner::Result.ok(result.content.upcase)
    end)

    assert_equal "LOUD", rewriting.after_result("read", Rho::Runner::Result.ok("loud")).content
  end

  def test_a_hook_answering_something_that_is_not_a_result_is_ignored
    confused = host(registration(:tool_result) { |_name, _result| "just a string" })
    original = Rho::Runner::Result.ok("kept")

    assert_same original, confused.after_result("read", original)
  end

  # THE THIRD ARGUMENT: both hooks receive the `Toolset::Tool`
  # being run, whose `effect_profile` is the profile the tool ANNOUNCED —
  # so a hook keys off "is this a write" by the profile, never a name list
  # of its own. A caller with no tool in hand (a unit driving the chain by
  # name) passes none and the handler reads nil.
  def test_both_hooks_receive_the_tool_as_their_third_argument
    tool = Rho::Runner::Toolset::Tool.new(
      name: "write", description: "w", parameters: { "type" => "object" }, handler: ->(_a, _c) { nil },
      effect_profile: Rho::Runner::Tools::Write::EFFECT_PROFILE
    )
    seen = []
    chain = host(
      registration(:tool_call) { |name, args, given| seen << [:call, name, args, given]; nil },
      registration(:tool_result) { |name, result, given| seen << [:result, name, result, given]; nil }
    )
    result = Rho::Runner::Result.ok("ok")

    chain.before_call("write", { "path" => "a" }, tool)
    chain.after_result("write", result, tool)
    chain.before_call("write", { "path" => "b" })

    assert_equal [:call, "write", { "path" => "a" }, tool], seen[0]
    assert_same tool, seen[0].last
    assert_equal "write", seen[0].last.effect_profile.fetch("kind"), "the profile as announced rides the tool"
    assert_equal [:result, "write", result, tool], seen[1]
    assert_equal [:call, "write", { "path" => "b" }, nil], seen[2], "no tool in hand: nil"
  end

  # A TWO-PARAMETER BLOCK STILL RUNS (pinned, M-s7): a proc drops what it
  # does not name, so every hook written as `|name, arguments|` — the
  # guard's, the process table's — keeps running under the three-argument
  # contract; a two-parameter LAMBDA raises on the third and `tool_call`
  # turns that into a Veto, as the contract line says (no-compat).
  def test_a_two_parameter_block_still_runs_and_a_two_parameter_lambda_is_a_veto
    tool = Rho::Runner::Toolset::Tool.new(
      name: "read", description: "r", parameters: { "type" => "object" }, handler: ->(_a, _c) { nil }
    )
    reached = []
    blocks = host(
      registration(:tool_call) { |name, args| reached << [name, args]; nil },
      registration(:tool_result) { |name, result| reached << [name, result.content]; nil }
    )
    assert_equal({ "x" => 1 }, blocks.before_call("read", { "x" => 1 }, tool))
    assert_equal "kept", blocks.after_result("read", Rho::Runner::Result.ok("kept"), tool).content
    assert_equal [["read", { "x" => 1 }], ["read", "kept"]], reached

    strict = host(registration(:tool_call, "rho.strict", &->(_name, _args) { nil }))
    veto = strict.before_call("read", {}, tool)
    assert_instance_of Hooks::Veto, veto
    assert_equal "rho.strict", veto.extension
    assert_match(/ArgumentError/, veto.reason)
  end

  # A CANCELLATION IS THE TASK'S: the chain runs on the worker under the
  # task's context now, so a hook that blocks (the capture's git) meets the
  # deadline or a stop through `raise_if_cancelled!` — passed through
  # whole by BOTH chains, never turned into a Veto ("blocked by") or
  # swallowed as a formatter's failure, so the run answers it as data.
  def test_a_cancellation_raised_inside_a_hook_passes_through_both_chains
    cancelled = Rho::Runner::ExecutionContext::Cancelled.new("execution deadline exceeded", reason: :deadline)
    closed = host(registration(:tool_call) { |_n, _a, _t| raise cancelled })
    open = host(registration(:tool_result) { |_n, _r, _t| raise cancelled })

    error = assert_raises(Rho::Runner::ExecutionContext::Cancelled) { closed.before_call("bash", {}) }
    assert_equal :deadline, error.reason
    assert_raises(Rho::Runner::ExecutionContext::Cancelled) { open.after_result("bash", Rho::Runner::Result.ok("x")) }
  end
end
