require "test_helper"
require "tmpdir"

# ---- `serves:` — which address a tool is served on ----
class ExtensionsServesTest < Minitest::Test
  Extensions = Rho::Runner::Extensions

  def tool_class(name)
    Class.new do
      const_set(:NAME, name)
      const_set(:DESCRIPTION, "does #{name}")
      const_set(:SCHEMA, { "type" => "object", "properties" => {} })
      const_set(:EFFECT_PROFILE, {
        "kind" => "read_only", "destructive" => false, "effect_scope" => "closed",
        "idempotency" => "intrinsic", "reconciliation" => "none",
      })
      define_method(:initialize) { |env:| @env = env }
      define_method(:call) { |_args| Rho::Runner::Result.ok("ok") }
    end
  end

  def extension(name, &block)
    Module.new do
      const_set(:NAME, name)
      define_singleton_method(:register) { |api| block.call(api) }
    end
  end

  def test_a_tool_serves_the_runner_by_default_and_the_registration_says_so
    api = Extensions::Api.new(extension_name: "rho.net", source: "<test>")
    api.register_tool(tool_class("net_fetch"))

    registration, *rest = api.tools
    assert_empty rest
    assert_equal :runner, registration.serves
    assert_equal "net_fetch", registration.klass::NAME
    assert_equal %i[runner agent], Extensions::Api::SERVES
  end

  # A STANDALONE RUNNER HOSTS NO AGENT TOOL: an agent-source tool needs a
  # daemon's member plane behind it, so the base handle refuses it by name
  # rather than serving a tool that would fail every call.
  def test_the_base_handle_refuses_an_agent_tool_and_an_unknown_source
    api = Extensions::Api.new(extension_name: "rho.compaction", source: "<test>")

    error = assert_raises(Extensions::RegistrationError) { api.register_tool(tool_class("summarize"), serves: :agent) }
    assert_match(/a standalone runner hosts no agent tool/, error.message)
    assert_match(/serves: :agent/, error.message)
    error = assert_raises(Extensions::RegistrationError) { api.register_tool(tool_class("x"), serves: :kernel) }
    assert_match(/serves must be :runner or :agent/, error.message)
    assert_empty api.tools
  end

  # The registry keeps the source on every entry and answers a narrowed
  # registry per source — the SAME hooks (a guard veto applies wherever the
  # tool runs), the environment descriptions the runner's alone.
  def test_serving_partitions_the_entries_and_shares_the_hooks
    vetoed = []
    result = Extensions::Loader.call(builtin: [
      Extensions::Coding,
      extension("rho.guard") { |api| api.on(:tool_call) { |name, _args| vetoed << name; nil } },
      extension("rho.summary") do |api|
        # An agent tool reaches the registry through a handle that admits
        # it — the daemon's subclass; the base handle stands in here.
        api.define_singleton_method(:register_tool) do |klass, serves: :runner|
          validator = Extensions::Tool.validate(klass, extension: extension_name)
          @tools << Extensions::Api::Registration.new(klass: klass, serves: serves, validator: validator)
          self
        end
        api.register_tool(Class.new(Object) do
          const_set(:NAME, "summarize_history")
          const_set(:DESCRIPTION, "summarize")
          const_set(:SCHEMA, { "type" => "object", "properties" => {} })
          const_set(:EFFECT_PROFILE, { "kind" => "pure", "destructive" => false, "effect_scope" => "closed",
                                       "idempotency" => "intrinsic", "reconciliation" => "none" })
          define_method(:initialize) { |env:| nil }
          define_method(:call) { |_args| Rho::Runner::Result.ok("s") }
        end, serves: :agent)
      end,
    ])

    registry = result.registry
    assert_predicate result, :ok?
    assert_equal %i[agent runner], registry.entries.map(&:serves).uniq.sort
    runner = registry.serving(:runner)
    agent = registry.serving(:agent)
    assert_equal %w[bash edit file_import file_publish files_bytes find grep ls read skill write], runner.names.sort
    assert_equal %w[summarize_history], agent.names
    assert_equal registry.names.sort, (runner.names + agent.names).sort, "a partition: nothing lost, nothing twice"
    env = Rho::Runner::Environment.local(root: Dir.tmpdir)
    assert_equal registry.environment_fragments(env), runner.environment_fragments(env)
    assert_empty agent.environment_fragments(env), "the environment document is the runner address's"
    runner.hooks.before_call("bash", { "command" => "ls" })
    agent.hooks.before_call("summarize_history", {})
    assert_equal %w[bash summarize_history], vetoed, "the same hook chain under both"
    toolset = agent.toolset(env: Rho::Runner::ToolEnv.new(root: Dir.tmpdir, artifacts_dir: Dir.tmpdir))
    assert_equal ["summarize_history"], toolset.names
  end
end
