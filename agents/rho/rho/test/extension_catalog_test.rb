require "test_helper"
require "open3"

class ExtensionCatalogTest < Minitest::Test
  def test_installed_gem_metadata_is_discovered_without_activating_or_loading_the_plugin
    output, status = Open3.capture2e({ "RUBYOPT" => nil }, Gem.ruby,
      "-rbundler/setup", "-I", File.expand_path("../lib", __dir__), "-e", <<~RUBY)
        require "rho"
        # Bundler activates all bundle members. A plain gem installation has
        # the WebUI installed but not activated by rho's dependencies.
        Gem.loaded_specs.delete("rho-webui")
        default = Rho::Config.from_hash({})
        disabled = Rho::Config.from_hash({ "plugins" => { "rho.webui" => { "enabled" => false } } })
        descriptor = default.catalog.fetch("rho.webui")
        puts JSON.generate(
          id: descriptor.id, source: descriptor.source,
          default_enabled: default.plugin_enabled?(descriptor.id),
          disabled_enabled: disabled.plugin_enabled?(descriptor.id),
          activated: Gem.loaded_specs.key?("rho-webui"),
          loaded: $LOADED_FEATURES.any? { |path| path.end_with?("/rho/webui.rb") },
          failures: default.catalog.failures
        )
      RUBY

    assert_predicate status, :success?, output
    result = JSON.parse(output)
    assert_equal "rho.webui", result.fetch("id")
    assert_equal "gem", result.dig("source", "kind")
    assert_equal "rho/webui", result.dig("source", "feature")
    assert result.fetch("default_enabled")
    refute result.fetch("disabled_enabled")
    refute result.fetch("activated")
    refute result.fetch("loaded")
    assert_empty result.fetch("failures")
  end
end
