require "test_helper"

class PluginConfigurationTest < Minitest::Test
  include RhoTest::DaemonHarness

  ID = "test.configuration_probe".freeze
  SCHEMA = {
    "type" => "object", "properties" => {
      "flag" => { "type" => "boolean", "default" => true },
      "count" => { "type" => "integer", "minimum" => 0, "default" => 4 },
      "label" => { "type" => "string", "default" => "inherited" },
      "nullable" => { "type" => ["string", "null"] },
      "items" => { "type" => "array", "items" => { "type" => "integer" }, "default" => [1] },
      "connections" => { "type" => "object", "additionalProperties" => {
        "type" => "object", "properties" => {
          "command" => { "type" => "string" },
          "retries" => { "type" => "integer", "minimum" => 0, "default" => 3 },
          "token" => { "type" => "string", "writeOnly" => true },
        },
      } },
    },
  }.freeze

  def test_disabled_schema_reads_do_not_evaluate_the_factory_write_defaults_or_expose_secrets
    path, marker = plugin
    raw = { "connections" => { "host.example" => { "command" => "first", "token" => "secret-value" } } }
    seed(ID => entry(path, configuration: raw))
    daemon = boot
    writes = record_writes(daemon)
    core = Rho::Core.new(home: daemon.home)
    view = row(core).fetch("configuration")

    refute File.exist?(marker)
    assert_equal raw.except("connections").merge("connections" => { "host.example" => { "command" => "first" } }), view.fetch("overrides")
    assert_equal 4, view.fetch("value").fetch("count")
    assert view.fetch("value").fetch("flag")
    assert_equal 3, view.dig("value", "connections", "host.example", "retries")
    refute_includes JSON.generate(view), "secret-value"
    assert_equal [{ "path" => ["connections", "host.example", "token"], "set" => true }], view.fetch("secrets")
    assert_equal raw, saved(daemon).dig("plugins", ID, "configuration")
    assert_empty writes
  end

  def test_one_field_batch_preserves_sparse_false_zero_empty_null_and_explicit_default_intent
    path, marker = plugin
    future = { "enabled" => false, "configuration_version" => 99, "configuration" => { "old" => "untouched" }, "unknown" => true }
    seed(ID => entry(path), "future.plugin" => future)
    daemon = boot
    writes = record_writes(daemon)
    core = Rho::Core.new(home: daemon.home)
    result = core.configure_extension(ID, operations: [
      set(["flag"], false), set(["count"], 0), set(["label"], ""), set(["nullable"], nil), set(["items"], []),
    ])

    assert result.fetch("saved")
    assert result.fetch("applied")
    assert_equal 1, writes.length
    assert_equal({ "flag" => false, "count" => 0, "label" => "", "nullable" => nil, "items" => [] }, saved(daemon).dig("plugins", ID, "configuration"))
    assert_equal future, saved(daemon).dig("plugins", "future.plugin")
    refute File.exist?(marker)

    core.configure_extension(ID, operations: [set(["count"], 4)])
    assert_equal 4, saved(daemon).dig("plugins", ID, "configuration", "count")
    core.configure_extension(ID, operations: [{ "op" => "unset", "path" => ["count"] }])
    refute saved(daemon).dig("plugins", ID, "configuration").key?("count")
    assert_equal 4, row(core).dig("configuration", "value", "count")
    assert_equal false, saved(daemon).dig("plugins", ID, "configuration", "flag")
    assert_equal future, saved(daemon).dig("plugins", "future.plugin")
  end

  def test_map_edits_preserve_unreturned_secrets_and_other_entries_and_explicit_removal_clears_them
    path, = plugin
    raw = { "connections" => {
      "host.example" => { "command" => "first", "token" => "first-secret" },
      "other" => { "command" => "other-command", "token" => "other-secret" },
    } }
    seed(ID => entry(path, configuration: raw))
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    core.configure_extension(ID, operations: [set(["connections", "host.example", "command"], "changed")])
    current = saved(daemon).dig("plugins", ID, "configuration", "connections")
    assert_equal "first-secret", current.dig("host.example", "token")
    assert_equal raw.fetch("connections").fetch("other"), current.fetch("other")
    refute_includes JSON.generate(row(core)), "first-secret"

    core.configure_extension(ID, operations: [set(["connections", "host.example", "token"], "replacement-secret")])
    assert_equal "replacement-secret", saved(daemon).dig("plugins", ID, "configuration", "connections", "host.example", "token")
    core.configure_extension(ID, operations: [{ "op" => "unset", "path" => ["connections", "host.example", "token"] }])
    refute saved(daemon).dig("plugins", ID, "configuration", "connections", "host.example").key?("token")
    core.configure_extension(ID, operations: [{ "op" => "unset", "path" => ["connections", "other"] }])
    refute saved(daemon).dig("plugins", ID, "configuration", "connections").key?("other")
    refute_includes JSON.generate(row(core)), "other-secret"
  end

  def test_invalid_interactive_value_preserves_the_file_while_current_file_fallback_is_tolerant
    path, = plugin
    seed(ID => entry(path, configuration: { "count" => "invalid-from-file", "label" => "kept", "old" => true }))
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    view = row(core).fetch("configuration")
    assert_equal 4, view.dig("value", "count")
    assert_equal %w[type unknown_field], view.fetch("diagnostics").map { |diagnostic| diagnostic.fetch("reason") }
    refute_includes JSON.generate(view), "invalid-from-file"
    before = File.read(daemon.home.settings_path)
    writes = record_writes(daemon)

    response = request(daemon, :patch, "/extensions/#{ID}/configuration", token: bearer(daemon),
      body: { operations: [set(["count"], -1)] })

    assert_equal "422", response.code, response.body
    refute JSON.parse(response.body).dig("error", "saved")
    assert_equal before, File.read(daemon.home.settings_path)
    assert_empty writes
    core.configure_extension(ID, operations: [set(["label"], "new")])
    assert_equal({ "label" => "new" }, saved(daemon).dig("plugins", ID, "configuration"))
    assert_equal 4, row(core).dig("configuration", "value", "count")
  end

  def test_disjoint_saves_accumulate_and_same_field_follows_save_order
    path, = plugin
    seed(ID => entry(path))
    daemon = boot
    first = Rho::Core.new(home: daemon.home)
    second = Rho::Core.new(home: daemon.home)
    first.configure_extension(ID, operations: [set(["count"], 0)])
    second.configure_extension(ID, operations: [set(["label"], "second-client")])
    first.configure_extension(ID, operations: [set(["count"], 7)])

    assert_equal({ "count" => 7, "label" => "second-client" }, saved(daemon).dig("plugins", ID, "configuration"))
  end

  def test_every_optional_plugin_can_be_off_while_authenticated_management_and_webui_recovery_work
    path, marker = plugin
    seed(ID => entry(path))
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    ids = core.extensions.fetch("plugins").map { |plugin| plugin.fetch("id") }
    response = request(daemon, :post, "/extensions/rho.webui/disable", token: bearer(daemon),
      body: { dependents: ids - ["rho.webui"] })

    assert_equal "200", response.code, response.body
    result = JSON.parse(response.body)
    assert result.fetch("saved")
    assert result.fetch("applied")
    refute result.fetch("restart_required")
    assert core.extensions.fetch("plugins").none? { |plugin| plugin.fetch("active") }
    daemon.stop
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    assert core.extensions.fetch("plugins").none? { |plugin| plugin.fetch("active") }
    assert_empty daemon.context.inventory.flat_map { |extension| extension.fetch("tools") }
    assert_equal "401", request(daemon, :get, "/extensions").code
    assert_equal "200", request(daemon, :get, "/settings", token: bearer(daemon)).code
    assert_equal "404", request(daemon, :get, "/", token: bearer(daemon)).code
    core.configure_extension(ID, operations: [set(["count"], 0)])
    refute File.exist?(marker)
    core.enable_extension(ID)
    assert File.exist?(marker)
    assert row(core).fetch("active")
    assert_equal "200", request(daemon, :get, "/probe/#{ID}", token: bearer(daemon)).code
    core.enable_extension("rho.webui")
    assert_equal "200", request(daemon, :get, "/").code
  end

  def test_dependencies_refuse_an_inconsistent_selection_and_accept_the_explicit_dependent_set
    path, = plugin(requires: ["rho.todo"])
    seed(ID => entry(path, enabled: true))
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    before = File.read(daemon.home.settings_path)
    assert_raises(Rho::Core::Refused) { core.disable_extension("rho.todo") }
    assert_equal before, File.read(daemon.home.settings_path)
    assert row(core).fetch("active")

    core.disable_extension("rho.todo", dependents: [ID])
    refute row(core).fetch("enabled")
    refute row(core).fetch("active")
    assert_raises(Rho::Core::Refused) { core.enable_extension(ID) }
    core.enable_extension("rho.todo")
    core.enable_extension(ID)
    assert row(core).fetch("active")
  end

  def test_webui_self_disable_returns_its_result_and_core_can_enable_it_again
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    result = core.disable_extension("rho.webui")

    assert result.fetch("saved")
    assert result.fetch("applied")
    assert_equal "404", request(daemon, :get, "/").code
    inventory = core.extensions
    assert_equal "rho extensions enable rho.webui", inventory.fetch("recovery_command")
    refute row(core, "rho.webui").fetch("active")
    core.enable_extension("rho.webui")
    assert row(core, "rho.webui").fetch("active")
    assert_equal "200", request(daemon, :get, "/").code
  end

  def test_disabled_pending_migration_is_not_loaded_by_inventory_and_failure_does_not_save
    path, marker = plugin(version: 2, migrations: 'MIGRATIONS = { 2 => ->(_configuration) { raise "migration-secret" } }')
    original = entry(path, configuration: { "old" => "keep" }, version: 1)
    seed(ID => original)
    calls = []
    loader = Rho::Configuration.method(:load_migrations)
    Rho::Configuration.define_singleton_method(:load_migrations) { |file| calls << file; loader.call(file) }
    begin
      daemon = boot
      core = Rho::Core.new(home: daemon.home)
      2.times { assert row(core).fetch("readiness").fetch("issues").any? }
      assert_empty calls
      refute File.exist?(marker)
      writes = record_writes(daemon)
      error = assert_raises(Rho::Core::Refused) do
        core.configure_extension(ID, operations: [set(["count"], 1)])
      end
      refute_includes error.message, "migration-secret"
      assert_equal 1, calls.length
      assert_empty writes
      assert_equal original, saved(daemon).dig("plugins", ID)
      assert_equal "200", request(daemon, :get, "/settings", token: bearer(daemon)).code
    ensure
      Rho::Configuration.define_singleton_method(:load_migrations, loader)
    end
  end

  def test_successful_plugin_migration_publishes_independently_of_another_failed_plugin
    good_id = "test.good_configuration"
    bad_path, bad_marker = plugin(version: 2, migrations: 'MIGRATIONS = { 2 => ->(_configuration) { raise "failed" } }')
    good_path, = plugin(id: good_id, version: 2, migrations: 'MIGRATIONS = { 2 => ->(configuration) { { "count" => configuration.fetch("old_count") } } }')
    bad = entry(bad_path, enabled: true, version: 1, configuration: { "old_count" => 9 })
    home = seed(ID => bad, good_id => entry(good_path, enabled: true, version: 1, configuration: { "old_count" => 7 }))
    writes = []
    original_writer = home.method(:write_settings)
    home.define_singleton_method(:write_settings) { |document| writes << document; original_writer.call(document) }
    lock = Rho::Lock.acquire(home.boot_lock_path)
    begin
      Rho::Settings.prepare(home)
    ensure
      lock.release
    end
    assert_equal 1, writes.length
    assert_equal bad, Rho::Config.read(home.settings_path).dig("plugins", ID)
    assert_equal 2, Rho::Config.read(home.settings_path).dig("plugins", good_id, "configuration_version")

    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    refute File.exist?(bad_marker)
    refute row(core).fetch("active")
    assert row(core, good_id).fetch("active")
    assert_equal 7, row(core, good_id).dig("configuration", "value", "count")
    core.update_settings("default_model" => "chosen")
    assert_equal bad, saved(daemon).dig("plugins", ID)
  end

  def test_invalid_or_newer_root_documents_are_preserved_on_failed_boot
    ["{invalid", JSON.generate(settings_version: 99, plugins: {}), JSON.generate(settings_version: 1, plugins: [])].each_with_index do |document, index|
      root = File.join(@root, index.to_s)
      home = Rho::Home.resolve(base_url: "https://nexus.example", root: root).prepare
      File.write(home.settings_path, document)
      File.chmod(0o600, home.settings_path)
      assert_raises(Rho::ConfigurationError) { boot(root: root) }
      assert_equal document, File.read(home.settings_path)
    end
  end

  def test_sparse_current_settings_boot_and_save_without_inventing_plugin_overrides
    home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root).prepare
    home.write_settings("settings_version" => 1, "default_model" => "initial")
    daemon = boot
    assert_equal "initial", daemon.context.config.default_model
    refute saved(daemon).key?("plugins"), "reading the current format does not write defaults"
    Rho::Core.new(home: home).update_settings("default_model" => "changed")
    assert_equal "changed", saved(daemon).fetch("default_model")
    assert_equal({}, saved(daemon).fetch("plugins"))
  end

  def test_a_newer_plugin_can_be_disabled_without_changing_its_migration_input
    path, marker = plugin
    future = entry(path, enabled: true, version: 99, configuration: { "future" => { "token" => "keep" } })
    seed(ID => future)
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    refute File.exist?(marker)
    core.disable_extension(ID)
    assert_equal future.merge("enabled" => false), saved(daemon).dig("plugins", ID)
    assert_raises(Rho::Core::Refused) { core.enable_extension(ID) }
    assert_equal future.merge("enabled" => false), saved(daemon).dig("plugins", ID)
  end

  def test_startup_with_an_unavailable_dependency_isolates_its_dependents_and_preserves_management
    path, marker = plugin(requires: ["rho.todo"])
    seed(ID => entry(path, enabled: true), "rho.todo" => { "enabled" => false })
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    refute File.exist?(marker)
    assert row(core).fetch("enabled")
    refute row(core).fetch("active")
    assert_includes row(core).dig("readiness", "issues").join, "rho.todo"
    core.configure_extension("rho.coding", operations: [set(["bash_timeout_seconds"], 45)])
    refute File.exist?(marker), "an unrelated save must not activate a broken dependent"
    core.enable_extension("rho.todo")
    assert row(core).fetch("active")
    assert File.exist?(marker)
  end

  def test_a_broken_package_source_does_not_prevent_boot_or_core_disable
    entry = { "enabled" => true, "source" => { "kind" => "package", "name" => "missing", "version" => "typo" },
      "configuration_version" => 1, "configuration" => { "keep" => true } }
    seed("test.missing_package" => entry)
    daemon = boot
    core = Rho::Core.new(home: daemon.home)
    bad = row(core, "test.missing_package")
    refute bad.fetch("active")
    refute_empty bad.dig("readiness", "issues")
    core.disable_extension("test.missing_package")
    assert_equal entry.merge("enabled" => false), saved(daemon).dig("plugins", "test.missing_package")
  end

  def test_launch_mode_leaves_unavailable_plugin_migration_inputs_untouched
    path, marker = plugin(version: 2, migrations: 'MIGRATIONS = { 2 => ->(_old) { { "count" => 7 } } }')
    descriptor_path = path.sub(/\.rb\z/, ".json")
    descriptor = JSON.parse(File.read(descriptor_path)).merge("modes" => ["agent", "full"])
    File.write(descriptor_path, JSON.generate(descriptor))
    original = entry(path, enabled: true, configuration: { "old" => true })
    seed(ID => original)
    daemon = boot(flags: { mode: "runner" })
    assert_equal original, saved(daemon).dig("plugins", ID)
    refute File.exist?(marker)
    assert_includes row(Rho::Core.new(home: daemon.home)).dig("readiness", "issues"), "Unavailable in runner mode"
  end

  private

    def plugin(id: ID, version: 1, migrations: nil, requires: [])
      path = File.join(@root, "#{id}.rb")
      marker = File.join(@root, "#{id}.loaded")
      File.write(path, <<~RUBY)
        File.write(#{marker.inspect}, "loaded")
        module ConfigurationProbe
          NAME = #{id.inspect}
          def self.register(api)
            count = api.configuration["count"]
            api.register_route("GET", #{"/probe/#{id}".inspect}) { |_request, _ctx| [200, { count: count }] }
          end
        end
      RUBY
      descriptor = { "id" => id, "display_name" => id, "default_enabled" => false,
        "configuration_version" => version, "configuration_schema" => SCHEMA, "requires" => requires }
      if migrations
        filename = "#{id}.migrations.rb"
        File.write(File.join(@root, filename), migrations)
        descriptor["configuration_migrations"] = filename
      end
      File.write(path.sub(/\.rb\z/, ".json"), JSON.generate(descriptor))
      [path, marker]
    end

    def entry(path, enabled: false, configuration: {}, version: 1)
      { "source" => { "kind" => "path", "path" => path }, "enabled" => enabled,
        "configuration_version" => version, "configuration" => configuration }
    end

    def seed(plugins)
      home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root).prepare
      home.write_settings("settings_version" => 1, "plugins" => plugins)
      home
    end

    def row(core, id = ID)
      core.extensions.fetch("plugins").find { |plugin| plugin.fetch("id") == id }
    end

    def saved(daemon) = Rho::Config.read(daemon.home.settings_path)
    def set(path, value) = { "op" => "set", "path" => path, "value" => value }

    def record_writes(daemon)
      writes = []
      original = daemon.home.method(:write_settings)
      daemon.home.define_singleton_method(:write_settings) { |document| writes << document; original.call(document) }
      writes
    end
end
