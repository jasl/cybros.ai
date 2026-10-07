require "test_helper"
require "fileutils"
require "net/http"
require "tmpdir"
require "support/rho_daemon"
require "support/secret_hygiene"

# A private fresh world keeps shuffled suites from turning first boot into
# ordinary login. All provisioning and assertions use the public product paths.
class ApplicationLoginTest < Minitest::Test
  WAIT = E2E::RhoDaemon::WATCH_TIMEOUT
  ProxyResponse = Data.define(:code, :body)
  SETUP_SECRET = "synthetic-application-login-bootstrap".freeze

  def setup
    E2E.base_url # The outer world owns the already-built assets.
    @root = Dir.mktmpdir("rho-application-login-e2e")
    @server = E2E::NexusServer.new(nexus_root: E2E::NEXUS_ROOT, setup_secret: SETUP_SECRET)
    prepared = ENV["E2E_ASSETS_PREPARED"]
    begin
      ENV["E2E_ASSETS_PREPARED"] = "1"
      @server.start
    ensure
      ENV["E2E_ASSETS_PREPARED"] = prepared
    end
    home = File.join(@root, "home")
    FileUtils.mkdir_p(home)
    File.write(File.join(home, "settings.json"), JSON.generate("settings_version" => 1, "plugins" => {}), perm: 0o600)
    @daemon = E2E::RhoDaemon.new(base_url: @server.base_url, home: home,
      tools_root: File.join(@root, "work"), browser_url: @server.rho_browser_url,
      env: { "RHO_MODE" => "full" })
    @daemon.start
    @browser = E2E::BrowserActor.new(@server.rho_browser_url)
    @page = @browser.page
    @browser.visit("/")
  end

  def teardown
    unless passed? || !@browser
      directory = File.expand_path("../artifacts/application_login/#{name}-#{Process.pid}", __dir__)
      E2E::SecretHygiene.save_screenshot(@browser, File.join(directory, "failure.png"))
      File.write(File.join(directory, "page.html"), E2E::SecretHygiene.redact(@page.html))
      File.write(File.join(directory, "rho.log"), E2E::SecretHygiene.redact(@daemon.log_text))
    end
  ensure
    @browser&.close
    @daemon&.stop
    @server&.stop(dump: !passed?)
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_explicit_setup_secret_protects_first_boot_and_later_device_login_preserves_runtime
    assert @page.has_button?("Connect to Nexus", wait: WAIT)
    refute @page.has_field?("rho access password", wait: 0)
    refute_includes @page.html, SETUP_SECRET
    @page.click_button "Use a device code"
    assert @page.has_link?("Open Nexus setup", wait: WAIT)
    assert @page.has_button?("Continue after setup")
    refute_includes @page.find_link("Open Nexus setup")[:href], SETUP_SECRET

    @page.click_button "Connect to Nexus"
    assert @page.has_field?("Installation name", wait: WAIT)
    assert @page.has_field?("Setup secret")
    @page.fill_in "Installation name", with: "OAuth E2E"
    @page.fill_in "Your name", with: "Application Owner"
    @page.fill_in "Email", with: "application-owner@example.test"
    @page.fill_in "Password", with: "Application-owner-713!"
    @page.fill_in "Repeat password", with: "Application-owner-713!"
    @page.fill_in "Setup secret", with: "wrong-bootstrap-secret"
    @page.click_button "Create installation"
    assert @page.has_text?("The setup secret is incorrect.", wait: WAIT)
    assert @page.has_field?("Setup secret"), "first boot keeps its bootstrap authority check"
    @page.fill_in "Setup secret", with: SETUP_SECRET
    @page.fill_in "Password", with: "Application-owner-713!"
    @page.fill_in "Repeat password", with: "Application-owner-713!"
    @page.click_button "Create installation"
    assert @page.has_text?("Sign in to your application", wait: WAIT)
    assert @page.has_text?("Application Owner")
    refute @page.has_field?("Password", wait: 0), "the first owner is already signed in"
    @page.click_button "Continue"
    assert @page.has_button?("Sign out", wait: WAIT)
    assert_equal URI(@server.rho_browser_url).port, URI(@page.current_url).port
    assert_nil URI(@page.current_url).query, "the callback code is removed from the visible URL"
    assert_nil URI(@page.current_url).fragment
    assert @page.has_css?("dialog.settings-dialog[open]", wait: WAIT)
    assert @page.has_text?("Application Owner")
    assert @page.has_text?(/Configure.*model|model provider|No models/i)
    @daemon.await("rho did not adopt the first OAuth connection") { @daemon.status.dig("workspace", "state") == "adopted" }
    original_identity = @daemon.status.fetch("identity")
    old_bearer = browser_bearer
    profile = proxy_get("/api/v1/profile", old_bearer)
    assert_equal "200", profile.code
    assert_equal "owner", JSON.parse(profile.body).dig("member", "role")
    assert_equal "200", proxy_get("/api/v1/admin/model_providers", old_bearer).code

    @page.click_button "Close", exact: true
    @page.click_button "Sign out"
    assert @page.has_button?("Connect to Nexus", wait: WAIT)
    assert_equal "401", proxy_get("/api/v1/profile", old_bearer).code
    assert_equal original_identity, @daemon.status.fetch("identity"), "Human logout leaves the runtime connection intact"
    @page.click_button "Use a device code"
    assert @page.has_link?("Open Nexus to approve", wait: WAIT)
    approval = @page.window_opened_by { @page.click_link "Open Nexus to approve" }
    @page.within_window(approval) do
      @page.click_button "Continue"
      @page.click_button "Connect", exact: true
      assert @page.has_text?(/Connection ready|This connection is complete/, wait: WAIT)
    end
    approval.close
    assert @page.has_button?("Sign out", wait: WAIT)
    refute_equal old_bearer, browser_bearer
    assert_equal original_identity, @daemon.status.fetch("identity"), "login-only Device Flow must not re-pair the runtime"
    assert_equal "200", proxy_get("/api/v1/profile", browser_bearer).code
    @page.refresh
    assert @page.has_button?("Sign out", wait: WAIT), "the browser session survives an ordinary page refresh"
  end

  private

    def browser_bearer
      value = @page.evaluate_script("sessionStorage.getItem(`rho.bearer.${location.origin}`)")
      refute_nil value
      E2E::SecretHygiene.register(value)
      value
    end

    def proxy_get(path, bearer)
      uri = URI.join(@server.rho_browser_url, "/nexus/request")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{bearer}"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate("path" => path, "method" => "GET")
      response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
      if response.code == "200"
        document = JSON.parse(response.body)
        ProxyResponse.new(code: document.fetch("status").to_s, body: JSON.generate(document["body"]))
      else
        ProxyResponse.new(code: response.code, body: response.body)
      end
    end
end
