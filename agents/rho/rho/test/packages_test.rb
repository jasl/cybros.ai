require "test_helper"
require "rho/packages"

class PackagesTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rho-packages-")
    @home = Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(@root, "home"))
    @home.prepare
    @packages = Rho::Packages.new(home: @home)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def source(body: "def self.register(api); end\n", state_schema: "notes-v1", dependencies: {}, configuration_version: 1, schema: nil, migrations: nil)
    directory = Dir.mktmpdir("source-", @root)
    schema ||= { "type" => "object", "properties" => { "prefix" => { "type" => "string" }, "token" => { "type" => "string", "writeOnly" => true } } }
    File.write(File.join(directory, "rho-extension.json"), JSON.generate(name: "notes", id: "personal.notes", description: "Personal notes",
      state_schema: state_schema, dependencies: dependencies, configuration_version: configuration_version,
      configuration_schema: schema, configuration_migrations: migrations && "migrations.rb"))
    File.write(File.join(directory, "extension.rb"), body)
    File.write(File.join(directory, "migrations.rb"), migrations) if migrations
    directory
  end

  def install(**)
    @packages.install(path: source(**)).fetch(:version)
  end

  def select(version, configuration: nil)
    @packages.activate(name: "notes", version: version, configuration: configuration) do |sources, persist|
      persist.call
      { selected: sources.map(&:path) }
    end
  end

  def test_install_copies_complete_version_without_loading_it_and_identical_install_is_idempotent
    path = source(body: 'raise "never evaluate on install"')
    FileUtils.mkdir_p(File.join(path, "test"))
    File.write(File.join(path, "test", "notes_test.rb"), "raise 'only explicit check'\n")
    first = @packages.install(path: path)
    second = @packages.install(path: path)
    assert_equal first, second
    assert_empty @packages.sources
    assert_equal 1, @packages.list.fetch(:packages).length
    installed = File.join(@home.extensions_root, "managed", "notes", first.fetch(:version))
    assert_equal "raise 'only explicit check'\n", File.read(File.join(installed, "test", "notes_test.rb"))
    File.write(File.join(path, "extension.rb"), "changed")
    assert_equal 'raise "never evaluate on install"', File.read(File.join(installed, "extension.rb"))
  end

  def test_selection_and_complete_rollback_snapshot_share_settings_and_disable_preserves_configuration
    a = install
    b = install(body: "def self.register(api); :replacement; end\n")
    select(a, configuration: { "prefix" => "first" })
    before = File.read(@home.settings_path)
    assert_raises(RuntimeError) do
      @packages.activate(name: "notes", version: b, configuration: { "prefix" => "second" }) do |sources, _persist|
        assert_includes sources.first.path, b
        raise "candidate startup failed"
      end
    end
    assert_equal before, File.read(@home.settings_path)
    assert_includes @packages.sources.first.path, a
    select(b, configuration: { "prefix" => "second" })
    fresh = Rho::Packages.new(home: @home)
    assert_equal({ "prefix" => "second" }, fresh.sources.first.configuration)
    assert_equal b[0, 12], fresh.sources.first.revision
    fresh.rollback(name: "notes") { |_sources, persist| persist.call; {} }
    assert_equal({ "prefix" => "first" }, fresh.sources.first.configuration)
    assert_includes fresh.sources.first.path, a
    fresh.disable(name: "notes") { |sources, persist| assert_empty sources; persist.call; {} }
    assert_empty Rho::Packages.new(home: @home).sources
    disabled = JSON.parse(File.read(@home.settings_path)).fetch("plugins").fetch("personal.notes")
    assert_equal a, disabled.dig("source", "version")
    assert_equal({ "prefix" => "first" }, disabled.fetch("configuration"))
    select(nil)
    assert_includes fresh.sources.first.path, a
    assert_equal({ "prefix" => "first" }, fresh.sources.first.configuration)
    refute File.exist?(File.join(@home.extensions_root, "managed", "catalog.json"))
  end

  def test_every_replacement_refuses_incompatible_business_state_without_calling_candidate
    a = install(state_schema: "notes-v1")
    b = install(body: "def self.register(api); :v2; end\n", state_schema: "notes-v2")
    select(a)
    error = assert_raises(Rho::ConfigurationError) { select(b) }
    assert_match(/business-state recovery/, error.message)
    @packages.disable(name: "notes") { |_sources, persist| persist.call; {} }
    assert_raises(Rho::ConfigurationError) { select(b) }
    assert_empty @packages.sources

    # A restored assembly can include an older rollback target beside newer
    # business state. Both explicit version selection and rollback must refuse it.
    current = Rho::Packages::Selection.new(name: "notes", version: b, configuration_version: 1, configuration: {}, state_schema: "notes-v2")
    previous = Rho::Packages::Selection.new(name: "notes", version: a, configuration_version: 1, configuration: {}, state_schema: "notes-v1")
    @home.write_settings("settings_version" => 1, "plugins" => {
      "personal.notes" => Rho::Packages::Entry.new(enabled: true, selection: current, previous: previous).to_h,
    })
    assert_raises(Rho::ConfigurationError) { select(a) }
    assert_raises(Rho::ConfigurationError) { @packages.rollback(name: "notes") { flunk "must not start old code" } }
    assert_includes @packages.sources.first.path, b
  end

  def test_reactivating_identical_selection_preserves_previous_version
    a = install
    b = install(body: "def self.register(api); :replacement; end\n")
    select(a)
    select(b, configuration: { "prefix" => "second" })
    select(b, configuration: { "prefix" => "second" })
    result = @packages.rollback(name: "notes") { |_sources, persist| persist.call; {} }
    assert_equal a, result.fetch(:selected)
    refute result.key?(:active), "the disk owner does not know the running selection"
    assert_equal b, result.fetch(:previous)
  end

  def test_publish_warning_keeps_new_settings_and_does_not_repeat_write
    a = install
    writes = 0
    original = @home.method(:write_settings)
    publisher = lambda do |*arguments|
      writes += 1
      original.call(*arguments)
      raise Rho::StateFile::PublishedError, "settings published; directory sync failed"
    end
    @home.define_singleton_method(:write_settings, publisher)
    result = @packages.activate(name: "notes", version: a) do |_sources, persist|
      persist.call
      { warning: "Applied locally; platform announcement failed." }
    end
    assert_equal 1, writes
    assert_match(/announcement failed/, result.fetch(:warning))
    assert_match(/published/, result.fetch(:warning))
    assert_equal "published_durability_uncertain", result.fetch(:persistence)
    assert_includes Rho::Packages.new(home: @home).sources.first.path, a
  end

  def test_announcement_failure_after_persist_does_not_restore_selection
    a = install
    assert_raises(RuntimeError) do
      @packages.activate(name: "notes", version: a) do |_sources, persist|
        persist.call
        raise "platform announcement unavailable"
      end
    end
    assert_includes Rho::Packages.new(home: @home).sources.first.path, a
  end

  def test_dependency_conflict_requires_restart_and_missing_dependency_does_not_select
    loaded = Gem.loaded_specs.fetch("minitest")
    bad = install(dependencies: { "minitest" => "> #{loaded.version}" })
    error = assert_raises(Rho::ConfigurationError) { select(bad) }
    assert_match(/already loaded.*restart/, error.message)
    assert_empty @packages.sources
    missing = install(dependencies: { "rho-test-missing-dependency" => ">= 1" })
    error = assert_raises(Rho::ConfigurationError) { select(missing) }
    assert_match(/unavailable/, error.message)
    assert_empty @packages.sources
  end

  def test_ambiguous_versions_require_explicit_choice_and_names_cannot_escape_managed_root
    install
    install(body: "changed\n")
    assert_raises(Rho::ConfigurationError) { @packages.activate(name: "notes") { flunk } }
    assert_raises(Rho::ConfigurationError) { @packages.activate(name: "../notes") { flunk } }
    assert_raises(Rho::ConfigurationError) { @packages.activate(name: "notes", version: "../other") { flunk } }
  end

  def test_explicit_check_runs_copied_tests_and_reports_failure_and_bounded_output
    path = source
    FileUtils.mkdir_p(File.join(path, "test"))
    File.write(File.join(path, "test", "notes_test.rb"), "require 'minitest/autorun'\nclass NotesTest < Minitest::Test\n def test_value; assert_equal 2, 1 + 1; end\nend\n")
    version = @packages.install(path: path).fetch(:version)
    result = @packages.check(name: "notes", version: version)
    assert result.fetch(:passed), result.fetch(:output)
    assert_equal 1, result.fetch(:tests)
    File.write(File.join(path, "test", "notes_test.rb"), "STDOUT.write('x' * 100_000); exit 7\n")
    failed_version = @packages.install(path: path).fetch(:version)
    result = @packages.check(name: "notes", version: failed_version)
    refute result.fetch(:passed)
    assert_equal 7, result.fetch(:exit_status)
    assert_equal Rho::Packages::Check::OUTPUT_BYTES, result.fetch(:output).bytesize
    assert_empty @packages.sources
  end

  def test_check_ends_a_hung_test_process
    path = source
    FileUtils.mkdir_p(File.join(path, "test"))
    File.write(File.join(path, "test", "hang_test.rb"), "sleep 30\n")
    result = Rho::Packages::Check.run(path, timeout: 0.1)
    refute result.fetch(:passed)
    assert result.fetch(:timed_out)
  end

  def test_invalid_manifest_and_nonportable_symlink_are_refused_before_install
    path = source
    File.write(File.join(path, "rho-extension.json"), "{invalid")
    assert_raises(Rho::ConfigurationError) { @packages.install(path: path) }
    path = source
    File.symlink(File.join(path, "extension.rb"), File.join(path, "linked.rb"))
    error = assert_raises(Rho::ConfigurationError) { @packages.install(path: path) }
    assert_match(/symlinks/, error.message)
    assert_empty @packages.list.fetch(:packages)
  end

  def test_upgrade_migrates_configuration_and_rollback_restores_the_old_complete_pair
    a = install
    select(a, configuration: { "prefix" => "old", "token" => "private" })
    schema = { "type" => "object", "properties" => {
      "title" => { "type" => "string" }, "token" => { "type" => "string", "writeOnly" => true },
      "limit" => { "type" => "integer", "default" => 3 },
    } }
    b = install(configuration_version: 2, schema: schema, migrations: <<~RUBY)
      MIGRATIONS = { 2 => ->(configuration) { configuration.merge("title" => configuration.delete("prefix")) } }
    RUBY
    select(b)
    stored = settings.fetch("plugins").fetch("personal.notes")

    assert_equal 2, stored.fetch("configuration_version")
    assert_equal({ "title" => "old", "token" => "private" }, stored.fetch("configuration"))
    assert_equal 1, stored.fetch("previous").fetch("configuration_version")
    assert_equal({ "prefix" => "old", "token" => "private" }, stored.fetch("previous").fetch("configuration"))
    assert_equal 3, @packages.sources.first.configuration.fetch("limit")
    refute_includes JSON.generate(@packages.list), "private"
    @packages.rollback(name: "notes") { |_sources, persist| persist.call; {} }
    assert_equal({ "prefix" => "old", "token" => "private" }, @packages.sources.first.configuration)
    assert_equal 1, settings.fetch("plugins").fetch("personal.notes").fetch("configuration_version")
    assert_equal b, settings.dig("plugins", "personal.notes", "previous", "source", "version")
  end

  def test_failed_or_missing_migrations_and_invalid_explicit_configuration_publish_nothing
    a = install
    select(a, configuration: { "prefix" => "old" })
    before = File.read(@home.settings_path)
    broken = install(configuration_version: 2, migrations: 'MIGRATIONS = { 2 => ->(configuration) { configuration.clear; raise "secret detail" } }')
    error = assert_raises(Rho::ConfigurationError) { select(broken) }
    refute_includes error.message, "secret detail"
    assert_equal before, File.read(@home.settings_path)
    missing = install(configuration_version: 3)
    assert_raises(Rho::ConfigurationError) { select(missing) }
    assert_equal before, File.read(@home.settings_path)
    assert_raises(Rho::ConfigurationError) { select(a, configuration: { "prefix" => false }) }
    assert_equal before, File.read(@home.settings_path)
  end

  def test_descriptor_reads_and_pending_sources_never_execute_migrations_or_plugin_code
    version = install(body: 'raise "do not load"', configuration_version: 2, migrations: 'raise "do not migrate on read"')
    manifest = Rho::Packages::Manifest.read(File.join(@home.extensions_root, "managed", "notes", version))
    assert_equal "personal.notes", manifest.descriptor.fetch("id")
    refute manifest.descriptor.fetch("default_enabled")
    assert_equal({ "prefix" => "current" }, manifest.migrate({ "prefix" => "current" }, from: 2).overrides)
    current = Rho::Packages::Selection.new(name: "notes", version: version, configuration_version: 1,
      configuration: { "prefix" => "unmigrated" }, state_schema: "notes-v1")
    @home.write_settings("settings_version" => 1, "plugins" => {
      "personal.notes" => Rho::Packages::Entry.new(enabled: true, selection: current, previous: nil).to_h,
    })
    before = File.read(@home.settings_path)

    assert_equal version, @packages.list.fetch(:packages).first.fetch(:version)
    assert_empty @packages.sources
    assert_equal before, File.read(@home.settings_path)
    error = assert_raises(Rho::ConfigurationError) { select(version) }
    assert_equal "configuration migration file could not be loaded", error.message
    assert_nil error.cause
    assert_equal before, File.read(@home.settings_path)
  end

  def test_saving_a_package_preserves_unrelated_core_and_unmigrated_plugin_fields
    future = { "enabled" => false, "configuration_version" => 99, "configuration" => { "old" => "do not normalize" }, "unknown" => true }
    @home.write_settings("settings_version" => 1, "default_model" => "chosen", "plugins" => { "another.plugin" => future })
    version = install
    select(version, configuration: { "prefix" => "mine" })

    assert_equal "chosen", settings.fetch("default_model")
    assert_equal future, settings.fetch("plugins").fetch("another.plugin")
    @packages.disable(name: "notes") { |_sources, persist| persist.call; {} }
    assert_equal future, settings.fetch("plugins").fetch("another.plugin")
  end

  def test_explicit_source_conflict_refuses_without_overwriting_another_plugin
    configured = { "enabled" => false, "source" => { "kind" => "gem", "feature" => "rho/another" }, "configuration" => {} }
    @home.write_settings("settings_version" => 1, "plugins" => { "personal.notes" => configured })
    version = install

    assert_raises(Rho::ConfigurationError) { select(version) }
    assert_equal configured, settings.fetch("plugins").fetch("personal.notes")
  end

  def test_legacy_import_is_read_only_carries_bodies_and_preserves_disabled_selection
    a = install(body: 'raise "metadata reads must not load code"')
    b = install(body: 'raise "different metadata only code"', configuration_version: 2)
    old = { "active" => { "version" => b, "configuration" => { "old_field" => "keep for plugin migration" }, "state_schema" => "notes-v1" },
      "previous" => { "version" => a, "configuration" => { "prefix" => "previous" }, "state_schema" => "notes-v1" } }
    catalog = Rho::StateFile.new(File.join(@home.extensions_root, "managed", "catalog.json"))
    catalog.write("notes" => old)
    before = File.read(catalog.path)
    plugins = { "rho.webui" => { "enabled" => false } }
    imported = Rho::Packages.import_legacy(@home, plugins)

    assert_equal plugins.fetch("rho.webui"), imported.fetch("rho.webui")
    assert_equal 1, imported.dig("personal.notes", "configuration_version")
    assert_equal({ "old_field" => "keep for plugin migration" }, imported.dig("personal.notes", "configuration"))
    assert_equal a, imported.dig("personal.notes", "previous", "source", "version")
    assert_equal before, File.read(catalog.path)
    refute File.exist?(@home.settings_path)

    catalog.write("notes" => { "active" => nil, "previous" => old.fetch("active") })
    disabled = Rho::Packages.import_legacy(@home, {}).fetch("personal.notes")
    refute disabled.fetch("enabled")
    assert_equal b, disabled.dig("source", "version")
    assert_equal old.fetch("active").fetch("configuration"), disabled.fetch("configuration")
    refute disabled.key?("previous")
  end

  def test_legacy_manifest_without_runtime_id_refuses_without_guessing_or_evaluating
    version = install(body: 'raise "never evaluate to discover NAME"')
    path = File.join(@home.extensions_root, "managed", "notes", version, "rho-extension.json")
    document = JSON.parse(File.read(path)).except("id")
    File.write(path, JSON.generate(document))
    Rho::StateFile.new(File.join(@home.extensions_root, "managed", "catalog.json")).write("notes" => {
      "active" => { "version" => version, "configuration" => {}, "state_schema" => "notes-v1" },
    })

    error = assert_raises(Rho::ConfigurationError) { Rho::Packages.import_legacy(@home, {}) }
    assert_match(/static id.*reinstall/, error.message)
    refute File.exist?(@home.settings_path)
  end

  def test_current_reads_never_consult_retired_catalog
    version = install
    select(version)
    File.write(File.join(@home.extensions_root, "managed", "catalog.json"), "not json")

    assert_equal "personal.notes", @packages.sources.first.id
    assert_equal version, @packages.list.fetch(:packages).first.fetch(:version)
  end

  def test_rollback_refuses_a_snapshot_for_a_different_configuration_version
    a = install
    b = install(body: "second")
    select(a)
    select(b)
    document = settings
    document.fetch("plugins").fetch("personal.notes").fetch("previous")["configuration_version"] = 2
    @home.write_settings(document)

    assert_raises(Rho::ConfigurationError) { @packages.rollback(name: "notes") { flunk "must not apply incompatible configuration" } }
    assert_equal document, settings
  end

  private

  def settings
    JSON.parse(File.read(@home.settings_path))
  end
end
