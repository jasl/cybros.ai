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

  def test_reloading_reuses_only_selected_extensions_without_registering_them_again
    registrations = Hash.new(0)
    extensions = %w[kept removed added].to_h do |name|
      [name, extension("rho.#{name}") do |api|
        registrations[name] += 1
        api.register_tool(tool_class(name, "#{name}:#{registrations[name]}"))
      end]
    end
    original = Extensions::Loader.call(builtin: extensions.values_at("kept", "removed"))
    reloaded = Extensions::Loader.call(builtin: extensions.values_at("kept", "added"), reuse: original.committed)

    assert_predicate reloaded, :ok?, reloaded.failures.inspect
    assert_equal({ "kept" => 1, "removed" => 1, "added" => 1 }, registrations)
    assert_same original.committed.first, reloaded.committed.first
    assert_equal %w[rho.kept rho.added], reloaded.committed.map(&:extension_name)
    assert_equal %w[added kept], reloaded.registry.names.sort
    assert_equal "kept:1", reloaded.registry.toolset(env: tool_env).fetch("kept").handler.call({}, nil).content
    assert_equal %w[kept removed], original.registry.names.sort
  end

  def test_a_reused_extension_still_passes_the_new_registrys_whole_extension_collision_guard
    registrations = 0
    reused = extension("rho.reused") do |api|
      registrations += 1
      api.register_tool(tool_class("partial", "must not run"))
      api.register_tool(tool_class("shared", "original"))
      api.on(:tool_call) { Extensions::Hooks::Veto.new(extension: "rho.reused", reason: "blocked") }
    end
    original = Extensions::Loader.call(builtin: [reused])
    first = extension("rho.first") { |api| api.register_tool(tool_class("shared", "new owner")) }
    reloaded = Extensions::Loader.call(builtin: [first, reused], reuse: original.committed)

    refute_predicate reloaded, :ok?
    assert_equal 1, registrations
    assert_equal 1, reloaded.failures.length
    assert_match(/already registered there by rho\.first/, reloaded.failures.first.message)
    assert_equal ["rho.first"], reloaded.committed.map(&:extension_name)
    assert_equal ["shared"], reloaded.registry.names
    assert_empty reloaded.registry.hooks.names(:tool_call)
    assert_equal "new owner", reloaded.registry.toolset(env: tool_env).fetch("shared").handler.call({}, nil).content
    assert_equal %w[partial shared], original.registry.names.sort
  end

  def test_only_an_explicit_internal_clamp_disables_ordinary_tool_renewal
    [true, false].each do |clamped|
      klass = tool_class("work", "answer")
      klass.const_set(:INTERNAL_CLAMP, clamped)
      loaded = Extensions::Loader.call(builtin: [extension("rho.work") { |api| api.register_tool(klass) }])
      assert_predicate loaded, :ok?
      assert_equal clamped, loaded.registry.toolset(env: tool_env).fetch("work").internal_clamp
      refute loaded.registry.announcement.fetch(0).key?("continuation")
    end
  end

  def test_a_document_load_keeps_its_provider_alive_when_another_extension_owns_the_skill_tool
    started = Thread::Queue.new
    release = Thread::Queue.new
    closed = []
    loaded = Extensions::Loader.call(builtin: [
      extension("rho.skills") { |api| api.register_tool(Rho::Runner::Tools::Skill) },
      extension("rho.documents") do |api|
        api.load_document do |_name, _env|
          started << true
          release.pop
          Rho::Runner::Result.ok("loaded document")
        end
        api.on(:shutdown) { closed << :connection }
      end,
    ])
    skill = loaded.registry.toolset(env: tool_env).fetch("skill")
    call = Thread.new { skill.handler.call({ "name" => "remote-document" }, nil) }
    assert started.pop(timeout: 2), "document load never started"

    refute loaded.committed.last.resources.retire
    assert_empty closed, "document provider closed while its load was running"
    release << true
    assert_equal "loaded document", call.value.content
    assert_equal [:connection], closed
    result = skill.handler.call({ "name" => "remote-document" }, nil)
    assert result.is_error
    assert_match(/skill_unknown/, result.content)
    assert started.empty?, "a stale registry started another call after provider retirement"
  ensure
    release << true if release
    call&.join(2)
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
          "kind" => "read_only", "destructive" => false, "effect_scope" => "closed",
          "idempotency" => "intrinsic", "reconciliation" => "none",
        })
        define_method(:initialize) { |env:| nil }
        define_method(:call) { |_args| Rho::Runner::Result.ok(answer) }
      end
    end
end
