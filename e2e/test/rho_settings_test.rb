require "test_helper"
require "cgi/escape"
require "fileutils"
require "tmpdir"
require "uri"
require "support/actor_provisioning"
require "support/mock_llm/app"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/telegram_http_server"

class RhoSettingsTest < Minitest::Test
  MODEL = "e2e-key/mock-keyed-text".freeze
  WAIT = E2E::RhoDaemon::WATCH_TIMEOUT

  def setup
    @base_url = E2E.base_url
    @people = E2E::ActorProvisioning.world(@base_url)
    @people.owner_browser
    E2E::SessionSignInBudget.consume
    grant = CybrosAgent::Sessions.new(base_url: @base_url).create(email: @people.owner_email, password: @people.owner_password)
    E2E::SecretHygiene.register(grant.token)
    @operator = CybrosAgent::PlatformClient.new(base_url: @base_url, credential: grant.token)
    @dev_was_enabled = provider("dev").fetch.enabled?
    provider("dev").disable(expected_lock_version: provider("dev").fetch.lock_version) if @dev_was_enabled
    reset_keyed_provider
    @root = Dir.mktmpdir("rho-settings-e2e")
    @project, @changed_project = File.join(@root, "project"), File.join(@root, "changed-project")
    @home = File.join(@root, "home")
    FileUtils.mkdir_p([@project, @changed_project, @home])
    File.open(File.join(@home, "settings.json"), File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
      file.write(JSON.generate("settings_version" => 1, "plugins" => {}))
    end
    @artifacts = File.expand_path("../artifacts/rho_settings/#{name}-#{Process.pid}", __dir__)
    @telegram = E2E::TelegramHttpServer.new.start
    E2E::SecretHygiene.register(E2E::TelegramHttpServer::TOKEN)
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home, tools_root: @project,
      browser_url: E2E.handle.fetch("rho_browser_url"),
      env: { "RHO_MODE" => "full", "RHO_DEFAULT_MODEL" => nil, "RHO_TELEGRAM_BOT_TOKEN" => nil,
        "E2E_TELEGRAM_URL" => @telegram.url,
        "RUBYOPT" => "-r#{File.expand_path("../support/telegram_http_prelude.rb", __dir__)}" })
    @daemon.start
    E2E.hosts.start
  end

  def teardown
    if @browser
      FileUtils.mkdir_p(@artifacts)
      File.write(File.join(@artifacts, "browser-console.json"), E2E::SecretHygiene.redact(JSON.pretty_generate(@browser.console_logs)))
      unless passed?
        E2E::SecretHygiene.save_screenshot(@browser, File.join(@artifacts, "failure.png"))
        File.write(File.join(@artifacts, "page.html"), E2E::SecretHygiene.redact(@page.html))
        [@daemon.log_path, @daemon.rho_log_path].each do |path|
          File.write(File.join(@artifacts, File.basename(path)), E2E::SecretHygiene.redact(File.read(path))) if File.file?(path)
        end
      end
    end
  ensure
    @browser&.close
    @daemon&.stop
    @telegram&.stop
    if @operator
      reset_keyed_provider
      provider("dev").enable(expected_lock_version: provider("dev").fetch.lock_version) if @dev_was_enabled
      @operator.session.revoke
    end
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_browser_connects_pairs_telegram_discovers_a_model_and_applies_settings_live
    visit_console
    assert @page.has_css?("dialog.settings-dialog[open]", wait: WAIT)
    @page.within('section[aria-label="Nexus account"]') do
      assert @page.has_text?("Signed in to Nexus as", wait: WAIT)
      assert @page.has_text?("owner")
    end
    @daemon.await_announced(address: "runner")
    @page.find('details[data-plugin-id="rho.ingress_telegram"] > summary').click
    @page.within('details[data-plugin-id="rho.ingress_telegram"]') do
      assert @page.has_text?("Requested: disabled")
      @page.click_button "Enable plugin"
      assert @page.has_text?("Requested: enabled", wait: WAIT)
    end
    @page.within('section[aria-label="Telegram setup"]') do
      assert @page.has_text?("Connect your Telegram bot", wait: WAIT)
    end
    @page.within('section[aria-label="Model setup"]') do
      assert @page.has_text?("To do: add an available text model with tool support in Nexus.")
    end
    assert_nil @daemon.control(:get, "/settings").dig("settings", "default_model")
    @page.find("dialog.settings-dialog").scroll_to(:top)
    screenshot("telegram-unconfigured-desktop")
    resize(390, 844)
    @page.find("dialog.settings-dialog").scroll_to(:top)
    screenshot("telegram-unconfigured-narrow")
    resize(1400, 1000)

    @page.within('section[aria-label="Telegram setup"]') do
      @page.fill_in "Bot token", with: E2E::TelegramHttpServer::TOKEN
      @page.check "Enable Telegram"
      @page.click_button "Verify and save Telegram"
      assert @page.has_field?("Bot token", with: "")
      assert @page.has_text?("Bind your Telegram account", wait: WAIT)
    end
    @daemon.await("Telegram polling never started") { @telegram.calls.any? { |method, _| method == "getUpdates" } }
    @telegram.message(id: 1, user: 101, text: "/start")
    @daemon.await("Telegram /start did not reveal the sender ID") do
      @telegram.messages.any? { |message| message.fetch("text").include?("101") }
    end
    @page.click_button "Refresh status"
    assert @page.has_link?("Open @settings_test_bot", href: "https://t.me/settings_test_bot", wait: WAIT)
    @page.fill_in "Bot owner user ID", with: "101"
    @page.click_button "Save Telegram", exact: true
    @page.within('section[aria-label="Telegram setup"]') do
      assert @page.has_no_text?("Bind your Telegram account", wait: WAIT)
    end
    @page.within('section[aria-label="Model setup"]') do
      assert @page.has_text?("To do: add an available text model with tool support in Nexus.", wait: WAIT)
    end
    assert_equal "101", telegram_status.dig("configuration", "owner_id")
    assert_equal 2, telegram_status.fetch("offset")
    screenshot("telegram-paired-desktop")

    @page.find("summary", text: "Telegram options and access", exact_text: true).click
    @page.select "Allowed people", from: "Access list"
    @page.fill_in "Telegram ID", with: "202"
    @page.click_button "Add to list"
    assert @page.has_css?('button[aria-label="Remove 202 from allowed people"]')
    assert_equal ["202"], telegram_status.dig("access", "allowed_users")
    @page.find('button[aria-label="Remove 202 from allowed people"]').click
    assert @page.has_no_css?('button[aria-label="Remove 202 from allowed people"]')
    assert_empty telegram_status.dig("access", "allowed_users")

    model_window = @page.window_opened_by { @page.click_link "Open Nexus model settings" }
    @page.within_window(model_window) do
      assert @page.has_css?("h1", text: "Model providers")
      @page.find_link(href: "/admin/model_providers/e2e-key").click
      @page.fill_in "API key", with: E2E::MockLLM::App::API_KEY
      @page.click_button "Save", exact: true
      assert @page.has_button?("Update", wait: WAIT)
    end
    model_window.close
    @page.click_button "Refresh status"
    assert @page.has_text?("rho is ready to use", wait: WAIT)
    assert_equal MODEL, @page.find_field("Default model").value
    assert_equal MODEL, @daemon.control(:get, "/settings").dig("settings", "default_model")

    @page.find("summary", text: "More settings", exact_text: true).click
    @page.fill_in "Default working directory", with: @changed_project
    @page.click_button "Save tools and working location"
    assert @page.has_text?("Settings saved and active.", wait: WAIT)
    assert_equal @changed_project, @daemon.control(:get, "/settings").dig("settings", "tools_root")
    @page.find('details[data-plugin-id="rho.coding"] > summary').click
    @page.within('details[data-plugin-id="rho.coding"]') do
      @page.fill_in "bash_timeout_seconds", with: "17"
      @page.click_button "Save configuration"
      assert @page.has_text?("Saved and applied.", wait: WAIT)
    end
    coding = @daemon.control(:get, "/extensions").fetch("plugins").find { |plugin| plugin.fetch("id") == "rho.coding" }
    assert_equal 17, coding.dig("configuration", "value", "bash_timeout_seconds")
    refute @daemon.control(:get, "/settings").fetch("settings").key?("bash_timeout_seconds")
    assert_equal @daemon.pid, JSON.parse(File.read(File.join(@home, "tmp", "announcement.json"))).fetch("pid")
    refute_includes JSON.generate(@daemon.control(:get, "/settings")), E2E::TelegramHttpServer::TOKEN
    resize(390, 844)
    @page.find("dialog.settings-dialog").scroll_to(@page.find("h4", text: "Tools and working location", exact_text: true), align: :top)
    screenshot("settings-tools-narrow")
    @page.find("dialog.settings-dialog").scroll_to(@page.find('details[data-plugin-id="rho.coding"]'), align: :top)
    screenshot("settings-coding-plugin-narrow")
    @page.find("summary", text: "More settings", exact_text: true).click
    @page.find("dialog.settings-dialog").scroll_to(:top)
    screenshot("settings-ready-narrow")
    @page.click_button "Start using rho"
    assert @page.has_no_css?("dialog[open]")
    @page.click_button "Conversations", exact: true unless @page.has_button?("New conversation", wait: 0)
    @page.click_button "New conversation"
    @page.find("summary", text: "Working location", exact_text: true).click
    assert_equal @daemon.control(:get, "/settings/status").dig("defaults", "runner_executor_public_id"), @page.find_field("Runner").value
    assert @page.has_field?("Working directory", with: ""), "a blank override uses the saved working directory"
    @page.select "Allow effects", from: "Approval mode"
    command = "printf settings-active > settings-live.txt"
    @page.fill_in "Message", with: "!mock tool_call=bash tool_args=#{CGI.escape(JSON.generate("command" => command))} reply=#{CGI.escape("Settings are active.")} -- do it"
    @page.click_button "Send", exact: true
    assert @page.has_text?("Mock: Settings are active.", wait: WAIT)
    assert_equal "settings-active", File.read(File.join(@changed_project, "settings-live.txt"))
    refute_path_exists File.join(@project, "settings-live.txt")
    screenshot("conversation-after-settings-narrow")

    @telegram.message(id: 2, user: 101, text: "!mock reply=#{CGI.escape("Telegram settings are active.")} -- say it")
    @daemon.await("the owner message did not use the configured model") do
      @telegram.messages.any? { |message| message.fetch("text").include?("Mock: Telegram settings are active.") }
    end
    assert_equal 3, telegram_status.fetch("offset")
    errors = @browser.console_logs.select { |entry| entry.fetch("level") == "SEVERE" }
    assert_empty errors, E2E::SecretHygiene.redact(JSON.pretty_generate(errors))
  end

  private

    def provider(id) = @operator.model_providers.provider(id)

    def reset_keyed_provider
      lane = provider("e2e-key")
      lane.remove_api_key if lane.fetch.configured?
      lane.disable(expected_lock_version: lane.fetch.lock_version) if lane.fetch.enabled?
    end

    def telegram_status = @daemon.control(:get, "/telegram")

    def visit_console
      output, status = @daemon.cli("console")
      assert_predicate status, :success?, E2E::SecretHygiene.redact(output)
      url = output[/^console:\s+(\S+)/, 1]
      refute_nil url
      @browser = E2E::BrowserActor.new(url)
      @page = @browser.page
      resize(1400, 1000)
      @browser.visit(url)
      @page.click_button "Connect to Nexus"
      @page.fill_in "Email", with: @people.owner_email
      @page.fill_in "Password", with: @people.owner_password
      E2E::SessionSignInBudget.consume
      @page.click_button "Sign in"
      assert @page.has_css?("h1", text: "Sign in to your application", wait: WAIT)
      @page.click_button "Continue"
      assert @page.has_field?("Message", wait: WAIT)
      assert_nil URI(@page.current_url).query, "OAuth code is removed after login"
    end

    def resize(width, height)
      @page.current_window.resize_to(width, height)
      @page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: width, height: height, deviceScaleFactor: 1, mobile: false)
    end

    def screenshot(name)
      assert @page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "the page fits the viewport"
      E2E::SecretHygiene.save_screenshot(@browser, File.join(@artifacts, "#{name}.png"))
    end
end
