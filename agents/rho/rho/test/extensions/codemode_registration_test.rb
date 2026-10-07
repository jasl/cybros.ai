require "test_helper"

class CodemodeRegistrationTest < Minitest::Test
  def test_default_extension_loads_in_every_mode_including_headless_hosts
    %w[full agent runner].each do |mode|
      host = RhoTest.host.with(config: Rho::Config.from_hash({ "mode" => mode, "api_only" => true }))
      sources = Rho::Extensions.sources(host.home, host.config)
      assert_includes sources.gems, "rho/codemode"

      loaded = Rho::Extensions.load(host:, extensions: [], gems: ["rho/codemode"])
      assert_predicate loaded, :ok?
      assert_equal(mode == "runner" ? [] : ["code"], loaded.registry.serving(:agent).names)
      assert_equal(mode == "agent" ? [] : ["code"], loaded.registry.serving(:runner).names)
      assert_equal ["rho.codemode"], loaded.extensions.map(&:name)
      assert_equal "gem:rho/codemode", loaded.extensions.first.source
    end
  end

  def test_standalone_runner_loads_the_same_extension_without_agent_state
    loaded = Rho::Runner::Extensions::Loader.call(builtin: [], gems: ["rho/codemode"])
    assert_predicate loaded, :ok?
    assert_equal ["code"], loaded.registry.serving(:runner).names
    assert_empty loaded.registry.serving(:agent).names
    announcement = Rho::RunDeclaration.announcement(registry: loaded.registry)
    assert_equal %w[description effect_profile input_schema name], announcement.first.keys.sort
  end
end
