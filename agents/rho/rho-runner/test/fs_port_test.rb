require "test_helper"

# THE FILE-SYSTEM PORT'S DUCK AND ITS ONE TABLE: rho-runner owns the contract (`serves?`, `read_text`, `write_text`,
# `drop`, `client`) and the errors an implementation raises; the routing
# predicate and the two table rows every tool shares — a cancel from the
# port is the runner's cancel path, an `Unavailable` drops the port — live
# here, so the tools carry no failure logic of their own.
class FsPortTest < Minitest::Test
  include RunnerTest::Helpers

  FsPort = Rho::Runner::FsPort
  Context = Rho::Runner::ExecutionContext

  def test_every_error_is_a_runner_error_and_refused_names_its_code
    [FsPort::Unavailable, FsPort::Refused, FsPort::NotFound, FsPort::BeyondEof, FsPort::Cancelled].each do |kind|
      assert_operator kind, :<, FsPort::Error
      assert_operator kind, :<, Rho::Runner::Error
    end
    refused = FsPort::Refused.new("read-only buffer", code: "editor_refused")

    assert_equal "editor_refused", refused.code
    assert_equal "read-only buffer", refused.message
    assert_equal "editor_refused", FsPort::Refused.new("x").code, "the client's other errors are editor_refused"
  end

  def test_the_client_name_defaults_on_the_duck_and_an_implementation_may_name_it
    bare = Class.new { include Rho::Runner::FsPort }.new

    assert_equal "the editor", bare.client
    assert_equal "zed", RunnerTest::PortDouble.new(client: "zed").client
  end

  # ---- the routing predicate: `routed(env, path, *needs)` ----

  def test_no_context_or_no_port_routes_nothing
    with_tool_env do |env, root|
      assert_nil FsPort.routed(env, File.join(root, "a.rb"), :read), "a context with no port"
    end
    Dir.mktmpdir do |tmp|
      env = Rho::Runner::ToolEnv.new(root: tmp, artifacts_dir: File.join(tmp, "a"))
      assert_nil FsPort.routed(env, File.join(tmp, "a.rb"), :read), "no context at all"
    end
  end

  def test_a_path_inside_the_root_set_routes_when_every_need_is_served
    port = RunnerTest::PortDouble.new
    Dir.mktmpdir do |other|
      with_ported_env(port, directories: [other]) do |env, root|
        assert_same port, FsPort.routed(env, File.join(root, "lib", "a.rb"), :read)
        assert_same port, FsPort.routed(env, File.join(other, "b.rb"), :write), "a bound directory is in the set"
        assert_same port, FsPort.routed(env, File.join(root, "a.rb"), :read, :write), "edit needs both"
      end
    end
  end

  def test_a_path_outside_the_root_set_is_never_routed
    port = RunnerTest::PortDouble.new
    with_ported_env(port) do |env, root|
      assert_nil FsPort.routed(env, File.join(File.dirname(root), "elsewhere", "a.rb"), :read)
      assert_nil FsPort.routed(env, File.join(root, "..", "x.rb"), :read), "`..` is judged on the spelling"
    end
  end

  def test_a_method_the_port_does_not_serve_is_not_routed_and_edit_needs_both
    read_only = RunnerTest::PortDouble.new(write: false)
    write_only = RunnerTest::PortDouble.new(read: false)
    with_ported_env(read_only) do |env, root|
      assert_same read_only, FsPort.routed(env, File.join(root, "a.rb"), :read)
      assert_nil FsPort.routed(env, File.join(root, "a.rb"), :write)
      assert_nil FsPort.routed(env, File.join(root, "a.rb"), :read, :write), "one flag: disk for both halves"
    end
    with_ported_env(write_only) do |env, root|
      assert_nil FsPort.routed(env, File.join(root, "a.rb"), :read)
      assert_same write_only, FsPort.routed(env, File.join(root, "a.rb"), :write)
      assert_nil FsPort.routed(env, File.join(root, "a.rb"), :read, :write)
    end
  end

  def test_the_port_is_looked_up_per_call_through_the_anchor
    port = RunnerTest::PortDouble.new
    table = { "conv-1" => port }
    with_ported_env(port, resolver: ->(anchor) { table[anchor] }) do |env, root|
      assert_same port, FsPort.routed(env, File.join(root, "a.rb"), :read)
      table.delete("conv-1")
      assert_nil FsPort.routed(env, File.join(root, "a.rb"), :read), "a dropped port is gone at the next call"
    end
  end

  # ---- the shared rows: `ask(port) { … }` ----

  def test_ask_answers_the_blocks_value
    port = RunnerTest::PortDouble.new
    with_ported_env(port) do |_env, _root|
      assert_equal "text", FsPort.ask(port) { "text" }
    end
  end

  def test_a_cancel_from_the_port_is_the_runners_cancel_path
    port = RunnerTest::PortDouble.new
    with_ported_env(port) do |_env, _root|
      error = assert_raises(Context::Cancelled) { FsPort.ask(port) { raise FsPort::Cancelled, "-32800" } }
      assert_equal :cancelled, error.reason
      assert_includes error.message, "zed"
      assert_empty port.dropped, "a cancel drops nothing"
    end
  end

  def test_a_cancel_from_the_port_under_a_cancelled_context_carries_the_contexts_reason
    port = RunnerTest::PortDouble.new
    with_ported_env(port) do |_env, _root|
      Context.current.cancel(:shutdown)
      error = assert_raises(Context::Cancelled) { FsPort.ask(port) { raise FsPort::Cancelled, "-32800" } }
      assert_equal :shutdown, error.reason, "the worker's own cancel finished the request; its reason stands"
    end
  end

  def test_unavailable_drops_the_port_once_and_re_raises_for_the_callers_half_of_the_table
    port = RunnerTest::PortDouble.new
    with_ported_env(port) do |_env, _root|
      error = assert_raises(FsPort::Unavailable) { FsPort.ask(port) { raise FsPort::Unavailable, "connection refused" } }
      assert_equal "connection refused", error.message
      assert_equal ["connection refused"], port.dropped
    end
  end

  def test_the_other_errors_pass_through_untouched
    port = RunnerTest::PortDouble.new
    with_ported_env(port) do |_env, _root|
      assert_raises(FsPort::NotFound) { FsPort.ask(port) { raise FsPort::NotFound, "gone" } }
      assert_raises(FsPort::BeyondEof) { FsPort.ask(port) { raise FsPort::BeyondEof, "past" } }
      assert_raises(FsPort::Refused) { FsPort.ask(port) { raise FsPort::Refused, "no" } }
      assert_empty port.dropped
    end
  end
end
