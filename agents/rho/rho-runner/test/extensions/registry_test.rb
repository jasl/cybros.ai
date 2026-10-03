require "test_helper"
require "tmpdir"

class ExtensionRegistryTest < Minitest::Test
  Extensions = Rho::Runner::Extensions

  def test_a_late_collision_publishes_none_of_the_failed_extensions_tools_or_hooks
    original = tool_class("shared", "original")
    loaded = Extensions::Loader.call(builtin: [
      extension("rho.original") { |api| api.register_tool(original) },
      extension("rho.failed") do |api|
        api.register_tool(tool_class("partial", "must not run"))
        api.register_tool(tool_class("shared", "replacement"))
        api.on(:tool_call) do |_name, _args, _tool|
          Extensions::Hooks::Veto.new(extension: "rho.failed", reason: "not ready")
        end
        api.on(:shutdown) { }
        api.describe_environment { |_env| "failed environment" }
      end,
      extension("rho.after") { |api| api.register_tool(tool_class("after", "after")) },
    ])

    refute_predicate loaded, :ok?
    assert_equal 1, loaded.failures.length
    assert_match(/already registered there by rho\.original/, loaded.failures.first.message)
    assert_equal %w[after shared], loaded.registry.names.sort,
      "a failed extension must not publish tools without its veto and shutdown hooks"
    assert_equal %w[after shared], loaded.registry.announcement.map { |row| row.fetch("name") }
    assert_equal %w[rho.original rho.after], loaded.committed.map(&:extension_name)
    assert_empty loaded.registry.hooks.names(:tool_call)
    assert_empty loaded.committed.flat_map(&:lifecycle)
    assert_empty loaded.registry.environment_fragments(Rho::Runner::Environment.local(root: Dir.tmpdir))
    toolset = loaded.registry.toolset(env: tool_env)
    assert_raises(KeyError) { toolset.fetch("partial") }
    assert_equal "original", toolset.fetch("shared").handler.call({}, nil).content
    assert_equal "after", toolset.fetch("after").handler.call({}, nil).content
  end

  def test_duplicate_names_within_one_extension_leave_the_name_available_to_the_next_extension
    loaded = Extensions::Loader.call(builtin: [
      extension("rho.failed") do |api|
        api.register_tool(tool_class("repeated", "first"))
        api.register_tool(tool_class("repeated", "second"))
      end,
      extension("rho.after") { |api| api.register_tool(tool_class("repeated", "after")) },
    ])

    refute_predicate loaded, :ok?
    assert_equal 1, loaded.failures.length,
      "the failed handle must not reserve a name and reject the following valid extension"
    assert_match(/already registered there by rho\.failed/, loaded.failures.first.message)
    assert_equal ["rho.after"], loaded.committed.map(&:extension_name)
    assert_equal ["repeated"], loaded.registry.names
    assert_equal "after", loaded.registry.toolset(env: tool_env).fetch("repeated").handler.call({}, nil).content
  end

  private

    def tool_env
      Rho::Runner::ToolEnv.new(root: Dir.tmpdir, artifacts_dir: Dir.tmpdir)
    end

    def extension(name, &register)
      Module.new do
        const_set(:NAME, name)
        define_singleton_method(:register) { |api| register.call(api) }
      end
    end

    def tool_class(name, answer)
      Class.new do
        const_set(:NAME, name)
        const_set(:DESCRIPTION, "answers #{name}")
        const_set(:SCHEMA, { "type" => "object", "properties" => {} })
        const_set(:EFFECT_PROFILE, {
          "kind" => "read_only", "destructive" => false, "world" => "closed",
          "idempotency" => "intrinsic", "reconciliation" => "none",
        })
        define_method(:initialize) { |env:| nil }
        define_method(:call) { |_args| Rho::Runner::Result.ok(answer) }
      end
    end
end
