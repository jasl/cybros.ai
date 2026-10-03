require "test_helper"
require "net/http"

class WebuiRegistrationTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rho-webui-registration")
    @bundle = File.join(@root, "page")
    FileUtils.mkdir_p(@bundle)
    File.write(File.join(@bundle, "index.html"), "<html>custom page</html>")
    @daemons = []
  end

  def teardown
    @daemons.each(&:stop)
    FileUtils.remove_entry(@root)
  end

  def extension(name, &block)
    Module.new do
      const_set(:NAME, name)
      define_singleton_method(:register) { |api| block.call(api) }
    end
  end

  def host(settings = {}) = RhoTest.host.with(config: Rho::Config.from_hash(settings))

  def boot(settings = {})
    daemon = Rho::Daemon.boot(
      home: Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(@root, "home")),
      config: Rho::Config.from_hash(settings)
    )
    @daemons << daemon
    daemon
  end

  def get(daemon, path)
    uri = URI.join(daemon.endpoint, path)
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(Net::HTTP::Get.new(uri)) }
  end

  def test_a_failed_factory_contributes_no_page_and_does_not_reserve_the_mount
    failed = extension("rho.failed_page") do |api|
      api.register_webui(root: "/discarded")
      raise "broken factory"
    end
    page = extension("rho.page") { |api| api.register_webui(root: @bundle) }
    loaded = Rho::Extensions.load(host: host, extensions: [failed, page])

    assert_equal @bundle, loaded.webui_root
    assert_equal ["broken factory"], loaded.failures.map(&:message)
    assert_equal ["rho.page"], loaded.extensions.map(&:name)
  end

  def test_two_committed_page_owners_refuse_the_load_and_name_both
    pages = %w[rho.first_page rho.second_page].map do |name|
      extension(name) { |api| api.register_webui(root: @bundle) }
    end
    error = assert_raises(Rho::Runner::Extensions::RegistrationError) do
      Rho::Extensions.load(host: host, extensions: pages)
    end

    assert_includes error.message, "rho.first_page"
    assert_includes error.message, "rho.second_page"
  end

  def test_registration_rejects_an_empty_root_and_a_second_root
    api = Rho::Extensions::Api.new(host: host, extension_name: "rho.page", source: "<test>")
    assert_raises(Rho::Runner::Extensions::RegistrationError) { api.register_webui(root: "") }
    api.register_webui(root: @bundle)
    assert_raises(Rho::Runner::Extensions::RegistrationError) { api.register_webui(root: "/second") }
  end

  def test_default_feature_is_selected_once_for_full_and_agent_and_never_for_headless_modes
    %w[full agent].each do |mode|
      config = Rho::Config.from_hash("mode" => mode, "extensions" => ["rho/webui", "rho/web-tools"])
      assert_equal ["rho/ingress-telegram", "rho/webui", "rho/web-tools"], Rho::Extensions.sources(host.home, config).gems
    end
    assert_empty Rho::Extensions.sources(host.home, Rho::Config.from_hash("mode" => "runner")).gems
    assert_equal ["rho/ingress-telegram"],
      Rho::Extensions.sources(host.home, Rho::Config.from_hash("api_only" => true)).gems
  end

  def test_the_plugin_loads_through_the_real_loader_and_is_listed_in_the_inventory
    loaded = Rho::Extensions.load(host: host, extensions: [], gems: ["rho/webui"])

    assert_predicate loaded, :ok?
    assert Rho::StaticFiles.available?(loaded.webui_root)
    assert_equal ["rho.webui"], loaded.inventory.map { |entry| entry.fetch("name") }
    assert_equal ["gem:rho/webui"], loaded.extensions.map(&:source)
    assert_empty loaded.registry.names
  end

  def test_runner_hosts_accept_the_same_plugin_without_mounting_a_page
    page = extension("rho.page") { |api| api.register_webui(root: @bundle) }
    loaded = Rho::Extensions.load(host: host("mode" => "runner"), extensions: [page])
    assert_predicate loaded, :ok?
    assert_nil loaded.webui_root

    standalone = Rho::Runner::Extensions::Loader.call(builtin: [page])
    assert_predicate standalone, :ok?
  end

  def test_agent_mode_serves_the_default_plugin
    daemon = boot("mode" => "agent")

    assert_predicate daemon, :page?
    assert_equal "200", get(daemon, "/").code
    assert_equal "200", get(daemon, "/console.js").code
  end

  def test_an_explicit_bundle_overrides_the_registered_plugin
    daemon = boot("webui_root" => @bundle)

    assert_equal "<html>custom page</html>", get(daemon, "/").body
  end

  def test_api_only_disables_even_an_explicitly_loaded_plugin_and_bundle
    daemon = boot("api_only" => true, "extensions" => ["rho/webui"], "webui_root" => @bundle)

    refute_predicate daemon, :page?
    assert_equal "404", get(daemon, "/").code
    assert_equal "200", get(daemon, "/healthz").code
  end

  def test_runner_mode_never_serves_a_page_even_with_an_explicit_plugin_and_bundle
    daemon = boot("mode" => "runner", "extensions" => ["rho/webui"], "webui_root" => @bundle)

    refute_predicate daemon, :page?
    assert_equal "404", get(daemon, "/").code
    assert_equal "200", get(daemon, "/healthz").code
  end

  def test_an_uninstalled_default_plugin_costs_only_the_page
    loader = Rho::Runner::Extensions::Loader
    require_feature = loader.method(:require_feature)
    loader.define_singleton_method(:require_feature) do |feature|
      raise LoadError, "rho-webui is not installed" if feature == "rho/webui"

      require_feature.call(feature)
    end
    daemon = boot

    refute_predicate daemon, :page?
    assert_equal "404", get(daemon, "/").code
    assert_equal "200", get(daemon, "/healthz").code
    assert_equal ["gem:rho/webui"], daemon.context.failures.map(&:source)
  ensure
    loader.define_singleton_method(:require_feature, require_feature)
  end
end
