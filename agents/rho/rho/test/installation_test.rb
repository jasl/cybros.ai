require "test_helper"

class InstallationTest < Minitest::Test
  include RhoTest::DaemonHarness

  SETUP_URL = "https://nexus.example/setup#setup_secret=private-installation-secret".freeze

  def test_ordinary_installations_keep_the_existing_connection_flow
    daemon = boot
    response = request(daemon, :get, "/installation", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    assert_equal({ "enabled" => false, "password_required" => false, "nexus_ready" => nil,
                   "setup_url" => nil, "error" => nil }, JSON.parse(response.body))
  end

  def test_only_an_authenticated_browser_with_a_saved_password_receives_the_setup_link
    daemon, state = installation
    state.write("nexus_ready" => false, "setup_url" => SETUP_URL, "error" => nil)

    denied = request(daemon, :get, "/installation")
    assert_equal "401", denied.code
    refute_includes denied.body, "private-installation-secret"
    refute_includes get(daemon, "/").body, "private-installation-secret"
    assert_equal "401", request(daemon, :patch, "/settings", body: { access_passphrase: "visitor-password" }).code

    initial = status(daemon)
    assert_equal true, initial.fetch("enabled")
    assert_equal true, initial.fetch("password_required"), "the generated ENV seed is not a user's saved password"
    assert_equal false, initial.fetch("nexus_ready")
    assert_nil initial.fetch("setup_url")
    rejected = request(daemon, :patch, "/settings", token: bearer(daemon), body: { access_passphrase: "short" })
    assert_equal "422", rejected.code
    assert status(daemon).fetch("password_required")

    saved = request(daemon, :patch, "/settings", token: bearer(daemon), body: { access_passphrase: "my-rho-password" })
    assert_equal "200", saved.code, saved.body
    refute_includes saved.body, "my-rho-password"
    ready = status(daemon)
    assert_equal false, ready.fetch("password_required")
    assert_equal SETUP_URL, ready.fetch("setup_url")
    assert_nil daemon.lineage.connection, "reading installation progress never starts a device ceremony"
    assert_equal 0o600, File.stat(daemon.home.settings_path).mode & 0o777
  end

  def test_the_helper_projection_is_read_fresh_and_never_exposes_a_finished_setup_link
    daemon, state = installation
    Rho::Core.new(home: daemon.home).update_settings("access_passphrase" => "my-rho-password")
    state.write("nexus_ready" => false, "setup_url" => SETUP_URL, "error" => nil)
    assert_equal SETUP_URL, status(daemon).fetch("setup_url")

    state.write("nexus_ready" => true, "setup_url" => SETUP_URL,
      "error" => "Existing rho registration requires a manual reconnect. Run ./cybros connect.")
    current = status(daemon)
    assert_equal true, current.fetch("nexus_ready")
    assert_nil current.fetch("setup_url")
    assert_includes current.fetch("error"), "manual reconnect"
    assert_nil daemon.lineage.connection
  end

  def test_an_unpublished_projection_waits_and_a_broken_projection_is_actionable
    daemon, state = installation
    current = status(daemon)
    assert_equal true, current.fetch("enabled")
    assert_nil current.fetch("nexus_ready")
    assert_nil current.fetch("setup_url")

    state.write("nexus_ready" => false, "setup_url" => SETUP_URL, "error" => nil)
    File.write(state.path, '{"broken":"private-installation-secret"')
    refused = request(daemon, :get, "/installation", token: bearer(daemon))
    assert_equal "503", refused.code
    assert_equal "installation_unavailable", JSON.parse(refused.body).dig("error", "code")
    refute_includes refused.body, "private-installation-secret"
    refute_includes refused.body, state.path
    assert_includes refused.body, "./cybros up"
  end

  def test_installation_state_is_a_deployment_setting_and_not_a_browser_writable_file_path
    daemon, = installation
    response = request(daemon, :patch, "/settings", token: bearer(daemon),
      body: { installation_file: File.join(@root, "other.json") })
    assert_equal "422", response.code
    assert_includes response.body, "not an editable agent setting"
  end

  def test_saved_password_survives_restart_and_replaces_the_installer_seed
    daemon, state = installation
    home = daemon.home
    Rho::Core.new(home: home).update_settings("access_passphrase" => "my-rho-password")
    daemon.stop

    config = Rho::Config.load(home.settings_path, env: {
      "RHO_ACCESS_PASSPHRASE" => "installer-random-password",
      "RHO_INSTALLATION_FILE" => state.path,
    })
    restarted = boot(config: config)
    assert_equal "200", request(restarted, :post, "/unlock", body: { passphrase: "my-rho-password" }).code
    assert_equal "401", request(restarted, :post, "/unlock", body: { passphrase: "installer-random-password" }).code
    assert_equal false, status(restarted).fetch("password_required")
    assert_equal true, status(restarted).fetch("enabled")
  end

  def test_invalid_projection_values_do_not_become_browser_links
    daemon, state = installation
    Rho::Core.new(home: daemon.home).update_settings("access_passphrase" => "my-rho-password")
    [
      { "nexus_ready" => "false", "setup_url" => SETUP_URL, "error" => nil },
      { "nexus_ready" => false, "setup_url" => "javascript:alert(1)", "error" => nil },
    ].each do |document|
      state.write(document)
      response = request(daemon, :get, "/installation", token: bearer(daemon))
      assert_equal "503", response.code
      assert_equal "installation_unavailable", JSON.parse(response.body).dig("error", "code")
    end
  end

  private

    def installation
      path = File.join(@root, "installation", "status.json")
      config = Rho::Config.from_hash("installation_file" => path, "access_passphrase" => "installer-random-password")
      [boot(config: config), Rho::StateFile.new(path)]
    end

    def status(daemon)
      response = request(daemon, :get, "/installation", token: bearer(daemon))
      assert_equal "200", response.code, response.body
      JSON.parse(response.body)
    end
end
