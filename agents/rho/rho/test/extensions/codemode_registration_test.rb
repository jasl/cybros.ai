require "test_helper"

class CodemodeRegistrationTest < Minitest::Test
  def test_default_extension_serves_both_roles_including_headless_hosts
    host = RhoTest.host.with(config: Rho::Config.from_hash({ "api_only" => true }))
    sources = Rho::Extensions.sources(host.home, host.config)
    assert_includes sources.gems, "rho/codemode"

    loaded = Rho::Extensions.load(host:, extensions: [], gems: ["rho/codemode"])
    assert_predicate loaded, :ok?
    assert_equal ["code"], loaded.registry.serving(:agent).names
    assert_equal ["code"], loaded.registry.serving(:runner).names
    assert_equal ["rho.codemode"], loaded.extensions.map(&:name)
    assert_equal "gem:rho/codemode", loaded.extensions.first.source
  end

  def test_environment_loader_loads_the_same_extension_without_agent_state
    loaded = Rho::Env::Extensions::Loader.call(builtin: [], gems: ["rho/codemode"])
    assert_predicate loaded, :ok?
    assert_equal ["code"], loaded.registry.serving(:runner).names
    assert_empty loaded.registry.serving(:agent).names
    announcement = Rho::RunDeclaration.announcement(registry: loaded.registry)
    assert_equal %w[description effect_profile input_schema name], announcement.first.keys.sort
  end
end
