require "test_helper"

class PackagesSurfaceTest < Minitest::Test
  include RhoTest::CliHarness

  Env = Data.define(:root) do
    def raise_if_cancelled!; end
  end

  def test_command_reads_configuration_and_prints_applied_warning
    path = File.join(@root, "configuration.json")
    File.write(path, JSON.generate("language" => "zh"))
    received = []
    announce(endpoint: recording_routed_endpoint(received, {
      "POST /extensions/packages" => [[200, { "active" => "a" * 64, "warning" => "announcement failed after local publication" }]],
    }))
    Rho::Extensions::Packages.command(cli, ["activate", "notes", "a" * 64], { configuration: path })
    body = JSON.parse(received.find { |request| request.start_with?("POST /extensions/packages") }.partition("\r\n\r\n").last)
    assert_equal({ "action" => "activate", "name" => "notes", "version" => "a" * 64, "configuration" => { "language" => "zh" } }, body)
    assert_includes @out.string, "announcement failed after local publication"
  end

  def test_failed_checks_surface_failure_after_printing_test_output
    announce(endpoint: routed_endpoint("POST /extensions/packages" => [[200, { "passed" => false, "output" => "1 failure" }]]))
    assert_raises(Rho::Error) { Rho::Extensions::Packages.command(cli, ["check", "notes"], {}) }
    assert_includes @out.string, "1 failure"
  end

  def test_model_management_is_an_open_destructive_effect_and_delegates_to_core
    assert_equal({ "kind" => "write", "destructive" => true, "effect_scope" => "open",
      "idempotency" => "none", "reconciliation" => "lookup" }, Rho::Extensions::Packages::Manage::EFFECT_PROFILE)
    received = []
    announce(endpoint: recording_routed_endpoint(received, { "POST /extensions/packages" => [[200, { "active" => "a" * 64 }]] }))
    tool = Rho::Extensions::Packages::Manage.new(env: Env.new(root: "/tmp"), core: core)
    result = tool.call({ "action" => "activate", "name" => "notes", "version" => "a" * 64 })
    body = JSON.parse(received.find { |request| request.start_with?("POST /extensions/packages") }.partition("\r\n\r\n").last)
    assert_equal({ "action" => "activate", "name" => "notes", "version" => "a" * 64 }, body)
    refute result.is_error
    assert_equal "a" * 64, JSON.parse(result.content).fetch("active")
  end

  def test_factory_owns_its_home_without_global_mutation_and_satisfies_tool_contract
    selected = home
    klass = Rho::Extensions::Packages::Manage.for_home(selected)
    Rho::Runner::Extensions::Tool.validate(klass, extension: "rho.packages")
    tool = klass.new(env: Env.new(root: "/tmp"))
    assert_same selected, tool.instance_variable_get(:@core).home
    assert_equal 120_000, klass::TIMEOUT_MS
  end
end
