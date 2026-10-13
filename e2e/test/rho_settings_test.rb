require "test_helper"
require "cgi/escape"
require "fileutils"
require "tmpdir"
require "uri"
require "support/actor_provisioning"
require "support/mock_llm/app"
require "support/rho_daemon"
require "support/rho_bot_definitions"
require "support/secret_hygiene"
require "support/telegram_http_server"

class RhoSettingsTest < Minitest::Test
  include E2E::RhoBotDefinitions

  MODEL = "e2e-key/mock-keyed-text".freeze
  WAIT = E2E::RhoDaemon::WATCH_TIMEOUT

  def setup
    @base_url = E2E.base_url
    @console_logs = []
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
      # These journeys sign in with Nexus; on loopback the gate would otherwise open by itself.
      file.write(JSON.generate("settings_version" => 1, "plugins" => {}, "webui_access" => "nexus"))
    end
    @artifacts = File.expand_path("../artifacts/rho_settings/#{name}-#{Process.pid}", __dir__)
    @telegram = E2E::TelegramHttpServer.new.start
    E2E::SecretHygiene.register(E2E::TelegramHttpServer::TOKEN)
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home, tools_root: @project,
      browser_url: E2E.handle.fetch("rho_browser_url"),
      env: { "RHO_MODE" => "full", "RHO_DEFAULT_MODEL" => nil,
        "E2E_TELEGRAM_URL" => @telegram.url,
        "RUBYOPT" => "-r#{File.expand_path("../support/telegram_http_prelude.rb", __dir__)}" })
    @daemon.start
    E2E.hosts.start
  end

  def teardown
    if @browser
      FileUtils.mkdir_p(@artifacts)
      File.write(File.join(@artifacts, "browser-console.json"), E2E::SecretHygiene.redact(JSON.pretty_generate(console_logs)))
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
      lane = provider("dev")
      current = lane.fetch
      if current.enabled? != @dev_was_enabled
        lane.public_send(@dev_was_enabled ? :enable : :disable, expected_lock_version: current.lock_version)
      end
      @operator.session.revoke
    end
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # The Telegram page is the plugin's own browser module, served by the daemon
  # from the telegram gem while the plugin runs: the shell knows nothing of it.
  def test_browser_connects_pairs_telegram_discovers_a_model_and_applies_settings_live
    visit_console
    assert @page.has_text?("To do: configure a model in Nexus", wait: WAIT), "the hero names the next setup step"
    open_settings
    @page.within(".settings-page") do
      assert @page.has_text?("Signed in to Nexus as", wait: WAIT)
      assert @page.has_text?("owner")
      @page.click_button "System upgrade"
      assert @page.has_text?("This rho runs from a source checkout.", wait: WAIT)
      assert @page.has_text?("This Nexus has no installation updater configured.", wait: WAIT)
      assert @page.has_no_button?("Upgrade rho")
      assert @page.has_no_button?("Upgrade Nexus")
    end
    screenshot("system-upgrade-desktop")
    resize(390, 844)
    screenshot("system-upgrade-narrow")
    resize(1400, 1000)
    close_settings
    @daemon.await_announced(address: "runner")
    web_tools = @daemon.control(:get, "/extensions").fetch("plugins").find { |plugin| plugin.fetch("id") == "rho.web_tools" }
    assert web_tools.fetch("enabled"), "Web tools are enabled without a saved override"
    assert web_tools.fetch("active"), "the default Web tools plugin starts successfully"
    refute_empty web_tools.fetch("description")

    open_plugins
    @page.within('article[data-plugin-id="rho.ingress_telegram"]') do
      assert @page.has_unchecked_field?("Telegram enabled", visible: :all, wait: WAIT)
      assert @page.has_no_css?(".tag"), "a plugin that is simply off carries no label"
    end
    channels = @page.find(".plugins__group", text: "Channels")
    assert channels.has_css?('article[data-plugin-id="rho.ingress_telegram"]'), "plugins are grouped by category"
    screenshot("plugins-desktop")
    resize(390, 844)
    screenshot("plugins-narrow")
    resize(1400, 1000)
    @page.within('article[data-plugin-id="rho.ingress_telegram"]') { @page.check "Telegram enabled", allow_label_click: true }
    assert @page.has_checked_field?("Telegram enabled", visible: :all, disabled: false, wait: WAIT)
    # Switching a plugin on leaves its card where it was: still under Channels.
    assert @page.find(".plugins__group", text: "Channels").has_css?('article[data-plugin-id="rho.ingress_telegram"]')
    @page.within('article[data-plugin-id="rho.ingress_telegram"]') do
      assert @page.has_text?("Setup needed", wait: WAIT), "a running plugin that still needs its setup says so"
      @page.click_button "Telegram settings"
    end
    assert @page.has_text?("Telegram connections", wait: WAIT), "the plugin owns shared credentials"
    @page.click_button "New connection"
    @page.fill_in "Connection name", with: "Settings connection"
    assert_nil @daemon.control(:get, "/settings").dig("settings", "default_model")
    screenshot("telegram-unconfigured-desktop")
    resize(390, 844)
    screenshot("telegram-unconfigured-narrow")
    resize(1400, 1000)
    @page.fill_in "Bot token", with: E2E::TelegramHttpServer::TOKEN
    @page.click_button "Verify and save"
    assert @page.has_text?("Settings connection connection saved.", wait: WAIT)
    assert @page.has_field?("Bot token", with: "")
    @telegram_connection_id = @daemon.control(:get, "/telegram/connections").fetch("connections").fetch(0).fetch("public_id")
    @daemon.await("Telegram polling never started") { @telegram.calls.any? { |method, _| method == "getUpdates" } }

    @page.click_link "Bots", exact: true
    @page.click_button "New bot"
    @page.fill_in "Name", with: "settings-telegram", exact: true
    @page.fill_in "Display name", with: "Settings Telegram"
    @page.fill_in "Description", with: "Answers the configured settings test target."
    @page.select "External requests", from: "Purpose"
    @page.click_button "Create bot"
    assert @page.has_text?("Settings Telegram was created.", wait: WAIT)
    @telegram_bot_id = browser_bot_definition("settings-telegram").fetch("public_id")
    home = @daemon.control(:get, "/workspaces").fetch("workspaces").first.fetch("public_id")
    @page.find_field("Home Workspace").find(%(option[value="#{home}"]), visible: :all, wait: WAIT).select_option
    @page.click_button "Save Home Workspace"
    assert @page.has_text?("Settings Telegram's Home Workspace was saved.", wait: WAIT)
    @page.within(".card", text: "Telegram target") do
      @page.find_field("Shared connection").find(%(option[value="#{@telegram_connection_id}"]), visible: :all, wait: WAIT).select_option
      @page.fill_in "Chat ID", with: "101"
      @page.fill_in "Bot owner user ID", with: "101"
      @page.check "Enable this Telegram target", allow_label_click: true
      @page.click_button "Save Telegram target"
    end
    assert @page.has_text?("Telegram settings saved.", wait: WAIT)
    assert_equal "101", telegram_status.dig("configuration", "owner_id")
    assert_equal({ "chat_id" => "101", "topic_id" => nil }, telegram_status.dig("configuration", "target"))
    @telegram.message(id: 1, user: 101, text: "/start")
    @daemon.await("the fixed Telegram target did not accept /start") { telegram_connection.fetch("offset") == 2 }
    screenshot("telegram-paired-desktop")
    resize(390, 844)
    screenshot("telegram-paired-narrow")
    resize(1400, 1000)

    # The Messages card, its own Save.
    @page.within(".card", text: "Messages") do
      assert @page.has_field?("Message grouping delay (seconds)", with: "2")
      @page.fill_in "Message grouping delay (seconds)", with: "3"
      @page.click_button "Save", exact: true
    end
    assert @page.has_text?("Telegram message settings saved.", wait: WAIT)
    assert_equal 3, telegram_status.dig("configuration", "input_debounce_seconds")
    @page.select "Allowed people", from: "Access list"
    @page.fill_in "Telegram ID", with: "202"
    @page.click_button "Add to list"
    assert @page.has_css?('button[aria-label="Remove 202 from Allowed people"]', wait: WAIT)
    assert_equal ["202"], telegram_status.dig("access", "allowed_users")
    @page.find('button[aria-label="Remove 202 from Allowed people"]').click
    assert @page.has_no_css?('button[aria-label="Remove 202 from Allowed people"]', wait: WAIT)
    assert_empty telegram_status.dig("access", "allowed_users")

    # THE NEXUS PAGE: the account's providers from rho, through the Human
    # proxy — the key saved from the provider's own field enables it, the
    # mark that asked for a key goes, and the model carries no mark: it is
    # available, which the page does not announce.
    open_nexus
    @page.within('[data-provider="e2e-key"]') do
      assert @page.has_text?("API key needed", wait: WAIT)
      @page.fill_in "api_key", with: E2E::MockLLM::App::API_KEY
      @page.within(".nexus-page__key") { @page.click_button "Save", exact: true }
      assert @page.has_no_text?("API key needed", wait: WAIT)
      assert @page.has_text?("A key is saved. Paste a new one to replace it.", wait: WAIT)
      assert @page.has_checked_field?("e2e-key enabled", visible: :all)
    end
    assert @page.has_text?("The API key for", wait: WAIT), "the toast names the save"
    @page.within(%([data-model="#{MODEL}"])) do
      assert @page.has_checked_field?("Visible: #{MODEL}", visible: :all, wait: WAIT)
      assert @page.has_no_css?(".tag--warning")
    end
    assert @page.has_link?("Open Nexus model settings", href: %r{/admin/model_providers\z})

    open_settings
    @page.click_button "Defaults"
    @page.click_button "Refresh", exact: true
    assert @page.has_select?("Default model", wait: WAIT) { |control| control.value == MODEL }, "the sole eligible model is adopted automatically"
    assert_equal MODEL, @daemon.control(:get, "/settings").dig("settings", "default_model")

    open_settings
    @page.click_button "Defaults"
    @page.fill_in "Default working directory", with: @changed_project
    @page.within(".card", text: "Tools and working location") { @page.click_button "Save", exact: true }
    assert @page.has_text?("Settings saved and active.", wait: WAIT)
    assert_equal @changed_project, @daemon.control(:get, "/settings").dig("settings", "tools_root")
    assert_choices_reflect_the_kernel
    resize(390, 844)
    screenshot("settings-tools-narrow")
    resize(1400, 1000)
    close_settings

    open_plugins
    @page.within('article[data-plugin-id="rho.web_tools"]') do
      assert @page.has_text?(web_tools.fetch("description"))
      assert @page.has_no_css?(".tag"), "a running plugin needs no label"
      assert @page.has_text?("v#{web_tools.fetch("version")}")
    end
    @page.within('article[data-plugin-id="rho.webui"]') do
      # The page never offers to switch off the plugin that serves it; the terminal keeps that.
      assert @page.has_checked_field?("Web interface enabled", visible: :all, disabled: true)
      assert_includes @page.find(".switch")["data-tip"], "rho extensions disable rho.webui"
    end
    @page.within('article[data-plugin-id="rho.ops"]') do
      # Nor what that plugin requires: the conversation routes the page is made of.
      assert @page.has_checked_field?("Ops enabled", visible: :all, disabled: true)
      assert_includes @page.find(".switch")["data-tip"], "Web interface needs this plugin"
    end
    @page.within('article[data-plugin-id="rho.coding"]') { @page.click_button "Coding settings" }
    assert @page.has_text?("Requested: enabled", wait: WAIT)
    @page.fill_in "bash_timeout_seconds", with: "17"
    @page.within(".plugin-form") { @page.click_button "Save", exact: true }
    assert @page.has_text?("Saved and applied.", wait: WAIT)
    coding = @daemon.control(:get, "/extensions").fetch("plugins").find { |plugin| plugin.fetch("id") == "rho.coding" }
    assert_equal 17, coding.dig("configuration", "value", "bash_timeout_seconds")
    refute @daemon.control(:get, "/settings").fetch("settings").key?("bash_timeout_seconds")
    assert_equal @daemon.pid, JSON.parse(File.read(File.join(@home, "tmp", "announcement.json"))).fetch("pid")
    refute_includes JSON.generate(@daemon.control(:get, "/settings")), E2E::TelegramHttpServer::TOKEN
    resize(390, 844)
    screenshot("settings-coding-plugin-narrow")
    resize(1400, 1000)

    @page.click_button "New conversation"
    assert @page.has_no_text?("To do: configure a model in Nexus", wait: WAIT), "a ready daemon shows no setup notice"
    runners = @daemon.control(:get, "/runners").fetch("runners")
    default_runner = runners.find { |row| row.fetch("public_id") == @daemon.control(:get, "/settings/status").dig("defaults", "runner_executor_public_id") }
    @page.within('[role="group"][aria-label="Runner"]') do
      assert @page.has_button?("Runner: #{default_runner.fetch("display_name")}", wait: WAIT), "the saved default runner is preselected"
    end
    @page.click_button "Permissions: Ask before changes"
    @page.find('[role="menuitemradio"]', text: "Bypass permissions").click
    command = "printf settings-active > settings-live.txt"
    @page.fill_in "Message", with: "!mock tool_call=bash tool_args=#{CGI.escape(JSON.generate("command" => command))} reply=#{CGI.escape("Settings are active.")} -- do it"
    @page.click_button "Send", exact: true
    assert @page.has_text?("Mock: Settings are active.", wait: WAIT)
    assert_equal "settings-active", File.read(File.join(@changed_project, "settings-live.txt"))
    refute_path_exists File.join(@project, "settings-live.txt")
    resize(390, 844)
    screenshot("conversation-after-settings-narrow")

    @telegram.message(id: 2, user: 101, text: "!mock reply=uncorrected-request -- Start a long report")
    @telegram.message(id: 3, user: 101, text: "!mock reply=#{CGI.escape("Telegram settings are active.")} -- Actually, keep it brief")
    @daemon.await("the owner message did not use the configured model") do
      @telegram.messages.any? { |message| message.fetch("text").include?("Mock: Telegram settings are active.") }
    end
    assert_equal 4, telegram_connection.fetch("offset")
    refute @telegram.messages.any? { |message| message.fetch("text").include?("Mock: uncorrected-request") }
    assert_equal 1, @telegram.messages.count { |message| message.fetch("text").include?("Mock: Telegram settings are active.") }
    errors = console_logs.select { |entry| entry.fetch("level") == "SEVERE" }
    assert_empty errors, E2E::SecretHygiene.redact(JSON.pretty_generate(errors))
  end

  def test_preset_edits_change_future_turns_and_preserve_accepted_instructions
    visit_console
    @daemon.await_announced(address: "runner")
    lane = provider("dev")
    lane.enable(expected_lock_version: lane.fetch.lock_version)
    open_main_preset
    @page.find_field("Initial model").find('option[value="dev/mock-text"]', visible: :all, wait: WAIT).select_option
    captured_prompt = "  Preserve this indentation.\n第二行：保留原文。\n"
    @page.fill_in "System prompt", with: captured_prompt
    save_main_preset
    assert_equal "dev/mock-text", main_preset.dig("configuration", "model")
    assert_equal captured_prompt, main_preset.dig("configuration", "system_prompt")
    @page.find(".page").scroll_to(@page.find(".preset-editor"), align: :top)
    screenshot("main-preset-desktop")
    resize(390, 844)
    @page.find(".page").scroll_to(@page.find(".preset-editor"), align: :top)
    screenshot("main-preset-narrow")
    resize(1400, 1000)

    question = CGI.escape(JSON.generate("prompt" => "Continue with the captured prompt?"))
    opened = @daemon.control(:post, "/conversations", body: {
      "prompt" => "!mock tool_call=ask tool_args=#{question} -- ask before continuing",
      "working_directory" => @project, "approval_mode" => "bypass",
    })
    conversation = opened.fetch("conversation").fetch("public_id")
    run = materialized_input(conversation, opened).fetch("run_public_id")
    pending = @daemon.await("the first turn never asked") do
      @daemon.control(:get, "/asks").fetch("asks").find { |row| row.fetch("run_public_id") == run && row.fetch("kind") == "ask" }
    end
    first_request = request_system_text(run, "r1")
    assert_includes first_request, captured_prompt

    updated = "  New instructions for the next turn.\n原样保留。\n"
    @page.fill_in "System prompt", with: updated
    save_main_preset
    assert_equal updated, main_preset.dig("configuration", "system_prompt")
    answered = @daemon.control(:post, "/answer", body: { "public_id" => run,
      "task_key" => pending.fetch("task_key"), "content" => "Continue." })
    assert_equal pending.fetch("task_key"), answered.fetch("answered").fetch("task_key")
    completed = completed_run(run)
    resumed_request = request_system_text(run, completed.fetch("task_key"))
    assert_includes resumed_request, captured_prompt
    refute_includes resumed_request, updated
    assert_equal first_request, request_system_text(run, "r1"), "the sealed request is immutable"

    said = @daemon.control(:post, "/say", body: { "public_id" => conversation,
      "text" => "!mock reply=Next%20turn -- answer", "delivery_mode" => "queue" })
    next_turn = materialized_input(conversation, said).fetch("turn_public_id")
    @daemon.await("the next turn never sealed its request") do
      @daemon.control(:get, "/runs/request?#{URI.encode_www_form(public_id: conversation, turn: next_turn)}").dig("request", "entries")
    end
    next_request = @daemon.control(:get, "/runs/request?#{URI.encode_www_form(public_id: conversation, turn: next_turn)}").fetch("request")
    assert_includes system_text(next_request), updated
    refute_includes system_text(next_request), captured_prompt

    raw = @daemon.control(:post, "/runs", body: { "prompt" => "!mock reply=Raw%20turn -- answer" })
    raw_run = raw.fetch("run").fetch("public_id")
    raw_result = completed_run(raw_run)
    raw_instructions = sealed_request(raw_run, raw_result.fetch("task_key")).fetch("request_options").fetch("instructions")
    assert_includes raw_instructions, updated, "standalone raw runs use the same selected Preset"

    @page.fill_in "System prompt", with: ""
    save_main_preset
    assert_equal "", main_preset.dig("configuration", "system_prompt"), "an explicit empty prompt is saved without restoring old instructions"
    @page.fill_in "System prompt", with: updated
    save_main_preset
    @page.refresh
    open_main_preset
    assert @page.has_field?("System prompt", with: updated, wait: WAIT)
    assert @page.has_select?("Initial model", wait: WAIT) { |control| control.value == "dev/mock-text" }
    assert_empty console_logs.select { |entry| entry.fetch("level") == "SEVERE" }
  end

  def test_browser_explains_missing_plugin_dependencies_and_keeps_settings_usable
    visit_console
    open_plugins
    @page.within('article[data-plugin-id="rho.browser"]') { @page.click_button "Browser" }
    assert @page.has_field?("Playwright driver command", wait: WAIT)
    @page.fill_in "Playwright driver command", with: JSON.generate(File.join(@project, "missing-playwright"))
    @page.within(".plugin-form") { @page.click_button "Save", exact: true }
    assert @page.has_text?("Saved and applied.", wait: WAIT)
    @page.check "Browser enabled", allow_label_click: true
    assert @page.has_text?("Browser tools could not start Playwright and Chromium.", wait: WAIT)
    assert @page.has_text?("playwright install chromium")
    assert @page.has_text?("Requested: enabled")
    assert @page.has_text?("Running: inactive")
    @page.click_button "Retry activation"
    assert @page.has_button?("Retry activation", disabled: false, wait: WAIT)
    assert @page.has_text?("Browser tools could not start Playwright and Chromium.")
    assert @page.has_text?("Running: inactive")
    browser_plugin = @daemon.control(:get, "/extensions").fetch("plugins").find { |plugin| plugin.fetch("id") == "rho.browser" }
    assert browser_plugin.fetch("enabled"), "the requested setting is saved for repair"
    refute browser_plugin.fetch("active"), "a plugin with missing dependencies never publishes its tools"
    assert_empty browser_plugin.dig("capabilities", "tools")
    screenshot("browser-dependency-failure-desktop")
    resize(390, 844)
    screenshot("browser-dependency-failure-narrow")
    resize(1400, 1000)
    @page.uncheck "Browser enabled", allow_label_click: true
    assert @page.has_text?("Requested: disabled", wait: WAIT)
    open_plugins
    @page.within('article[data-plugin-id="rho.ingress_telegram"]') do
      assert @page.has_unchecked_field?("Telegram enabled", visible: :all, disabled: false, wait: WAIT), "core management remains available after a plugin fails"
    end
    errors = console_logs.select { |entry| entry.fetch("level") == "SEVERE" }
    unexpected = errors.reject do |entry|
      entry.fetch("message").include?("/extensions/rho.browser/enable") && entry.fetch("message").include?("503")
    end
    assert_empty unexpected, E2E::SecretHygiene.redact(JSON.pretty_generate(unexpected))
  end

  def test_browser_installs_checks_activates_and_rolls_back_managed_packages
    visit_console
    open_plugins
    assert @page.has_css?("section.packages", text: "Managed packages", wait: WAIT)
    source = package_source("first")
    install_package(source)
    first = selected_package_version
    @page.within('details[data-package-name="settings-package"]') do
      assert @page.has_text?("Saved: None · Running: None · Previous: None")
      @page.click_button "Check version"
      assert @page.has_text?("No test files were found", wait: WAIT)
      @page.within(:fieldset, "Activation configuration") do
        @page.fill_in "Configuration overrides", with: JSON.generate("label" => "Ada")
      end
      @page.click_button "Activate version"
      assert @page.has_text?("Selection saved and applied.", wait: WAIT)
      assert @page.has_field?("Configuration overrides", with: "")
    end
    assert_equal "first:Ada", @daemon.control(:get, "/settings-package").fetch("value")
    assert_package_versions(saved: first, running: first)
    screenshot("managed-package-active-desktop")

    install_package(package_source("second"))
    second = selected_package_version
    refute_equal first, second
    @page.within('details[data-package-name="settings-package"]') do
      @page.click_button "Activate version"
      assert @page.has_text?("Selection saved and applied.", wait: WAIT)
    end
    assert_equal "second:Ada", @daemon.control(:get, "/settings-package").fetch("value"), "activation without overrides preserves saved configuration"
    assert_package_versions(saved: second, running: second, previous: first)
    resize(390, 844)
    screenshot("managed-package-replaced-narrow")
    @page.within('details[data-package-name="settings-package"]') do
      @page.click_button "Roll back"
      assert @page.has_text?("Selection saved and applied.", wait: WAIT)
    end
    assert_package_versions(saved: first, running: first, previous: second)
    assert_equal "first:Ada", @daemon.control(:get, "/settings-package").fetch("value")

    @page.within('details[data-package-name="settings-package"]') do
      @page.click_button "Disable package"
      assert @page.has_text?("(disabled) · Running: None", wait: WAIT)
    end
    refute @daemon.control(:get, "/extensions/packages").fetch("packages").any? { |row| row.fetch("active") }
    errors = console_logs.select { |entry| entry.fetch("level") == "SEVERE" }
    assert_empty errors, E2E::SecretHygiene.redact(JSON.pretty_generate(errors))
  end

  private

    # Selenium drains each read; retain asserted entries for the teardown artifact.
    def console_logs
      @console_logs.concat(@browser.console_logs)
    end

    def package_source(value)
      path = File.join(@project, "package-#{value}")
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "rho-extension.json"), JSON.generate(
        name: "settings-package", id: "settings-package", description: "Browser package fixture", state_schema: "v1",
        configuration_schema: { type: "object", properties: { label: { type: "string" } } }))
      File.write(File.join(path, "extension.rb"), <<~RUBY)
        module SettingsPackage
          NAME = "settings-package"
          def self.register(api)
            label = api.configuration["label"].to_s
            api.register_route("GET", "/settings-package") { |_request, _ctx| [200, { "value" => "#{value}:" + label }] }
          end
        end
      RUBY
      path
    end

    def install_package(path)
      @page.within("section.packages") do
        @page.fill_in "Source directory", with: path
        @page.click_button "Install candidate"
        assert @page.has_field?("Source directory", with: "", wait: WAIT)
        assert @page.has_text?("Candidate installed.", wait: WAIT)
        assert @page.has_button?("Install candidate", disabled: false, wait: WAIT), "the installed version list has finished refreshing"
      end
    end

    def selected_package_version
      @page.find('details[data-package-name="settings-package"]').find_field("Installed version").value
    end

    def assert_package_versions(saved:, running:, previous: nil)
      summary = "Saved: #{saved[0, 12]} (enabled) · Running: #{running[0, 12]} · Previous: #{previous ? previous[0, 12] : "None"}"
      assert @page.has_text?(summary, wait: WAIT)
      rows = @daemon.control(:get, "/extensions/packages").fetch("packages")
      assert_equal saved, rows.find { |row| row.fetch("selected") }.fetch("version")
      assert_equal running, rows.find { |row| row.fetch("active") }.fetch("version")
    end

    def save_main_preset
      @page.within(".preset-editor") { @page.click_button "Save", exact: true }
      assert @page.has_text?("Preset settings saved.", wait: WAIT)
      @page.within(".preset-editor") { assert @page.has_button?("Save", exact: true, disabled: false, wait: WAIT) }
    end

    def main_preset
      catalog = @daemon.control(:get, "/presets")
      catalog.fetch("presets").find { |preset| preset.fetch("public_id") == catalog.fetch("main_preset_public_id") }
    end

    def materialized_input(conversation, receipt)
      query = URI.encode_www_form(public_id: conversation, input_public_id: receipt.fetch("input").fetch("public_id"))
      @daemon.await("the accepted input never materialized") do
        @daemon.control(:get, "/conversations/input_materialization?#{query}")["materialization"]
      end
    end

    def system_text(request)
      request.fetch("entries").select { |entry| entry["role"] == "system" }
        .flat_map { |entry| entry.fetch("parts").filter_map { |part| part["text"] } }.join("\n")
    end

    def request_system_text(run, task_key) = system_text(sealed_request(run, task_key))

    def sealed_request(run, task_key)
      query = URI.encode_www_form(public_id: run, task_key: task_key)
      @daemon.control(:get, "/runs/request?#{query}").fetch("request")
    end

    def completed_run(run)
      result = @daemon.await("the run did not finish") do
        row = @daemon.control(:get, "/runs/result?#{URI.encode_www_form(public_id: run)}").fetch("result")
        row if %w[completed failed canceled].include?(row.fetch("status"))
      end
      assert_equal "completed", result.fetch("status"), E2E::SecretHygiene.redact(JSON.generate(result))
      result
    end

    def provider(id) = @operator.model_providers.provider(id)

    def reset_keyed_provider
      lane = provider("e2e-key")
      lane.remove_api_key if lane.fetch.configured?
      lane.disable(expected_lock_version: lane.fetch.lock_version) if lane.fetch.enabled?
    end

    def telegram_status = @daemon.control(:get, "/telegram?#{URI.encode_www_form(agent_public_id: @telegram_bot_id)}")

    def telegram_connection
      @daemon.control(:get, "/telegram/connection?#{URI.encode_www_form(connection_public_id: @telegram_connection_id)}").fetch("connection")
    end

    # Settings is a main page, reached by the sidebar's link.
    def open_settings
      @page.click_link "Settings", exact: true
      assert @page.has_css?(".settings-page", wait: WAIT)
      @page.click_button "General", exact: true
    end

    def open_main_preset
      open_settings
      @page.click_button "Agent Presets", exact: true
      assert @page.has_css?(".presets-section", wait: WAIT)
      @page.within(%(article[data-preset="#{main_preset.fetch("public_id")}"])) do
        @page.find(".preset-catalog__name").click
      end
      assert @page.has_field?("System prompt", wait: WAIT)
    end

    # The account's administration page, the Human proxy behind it.
    def open_nexus
      @page.click_link "Nexus", exact: true
      assert @page.has_css?(".nexus-page__provider", wait: WAIT)
    end

    # The Nexus tools are switches over the kernel's live catalog, the fallback
    # model a choice among the eligible models, and the adaptation row a choice
    # among the installed rows; nothing is typed from memory.
    def assert_choices_reflect_the_kernel
      served = @daemon.control(:get, "/kernel_tools").fetch("tools").map { |row| row.fetch("canonical_name") }
      assert_includes served, "nexus.runners.list"
      saved = @daemon.control(:get, "/settings").dig("settings", "kernel_tools")
      assert_includes saved, "nexus.runners.list"
      assert @page.has_css?(".toolset__row[data-tool]", count: served.length, wait: WAIT), "one switch per tool the kernel serves"
      assert @page.has_no_css?(".toolset .tag--warning"), "every saved tool is served"
      assert_equal "List runners", @page.find('.toolset__row[data-tool="nexus.runners.list"] .settings-row__label span:not(.tag)').text
      assert @page.has_checked_field?("List runners", visible: :all)
      assert @page.has_unchecked_field?("Wait for delegated work", visible: :all), "the kernel's optional wait is off by default"
      @page.uncheck "List runners", allow_label_click: true

      assert @page.has_select?("Fallback models", selected: "No fallback")
      @page.select "Custom ordered list", from: "Fallback models"
      fallback = @page.find_field("Choose a fallback model")
      assert_includes fallback.all("option").map(&:value), MODEL
      fallback.find("option[value='#{MODEL}']", visible: :all).select_option
      @page.click_button "Add model"
      @page.within(".card", text: "Agent behavior") do
        @page.click_button "Save", exact: true
        assert @page.has_text?("Settings saved and active.", wait: WAIT)
      end
      assert_equal [MODEL], @daemon.control(:get, "/settings").dig("settings", "fallback_models")
      @page.select "No fallback", from: "Fallback models"
      @page.within(".card", text: "Agent behavior") do
        @page.click_button "Save", exact: true
        assert @page.has_text?("Settings saved and active.", wait: WAIT)
      end
      assert_equal [], @daemon.control(:get, "/settings").dig("settings", "fallback_models")
      rows = @daemon.control(:get, "/adaptations/rows").fetch("rows").map { |row| row.fetch("id") }
      assert_includes rows, "default"
      adaptations = @page.find_field("Model adaptations")
      assert_equal ["", "off", *rows], adaptations.all("option").map(&:value)
      assert_equal "", adaptations.value

      @page.within(".card", text: "Nexus tools") do
        @page.click_button "Save", exact: true
        assert @page.has_text?("Settings saved and active.", wait: WAIT)
      end
      assert_equal saved - ["nexus.runners.list"], @daemon.control(:get, "/settings").dig("settings", "kernel_tools"),
        "the switch removes one name and keeps the rest in their saved order"
    end

    # Back to the conversation panel: the sidebar's new conversation.
    def close_settings
      @page.find(".sidebar__new").click
      assert @page.has_field?("Message", wait: WAIT)
    end

    def open_plugins
      @page.click_link "Plugins", exact: true
      assert @page.has_css?("article[data-plugin-id]", wait: WAIT)
    end

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
      previous_body = @page.find("body", visible: :all).native
      @page.click_button "Sign in"
      # The consent page requires a full reload after the Turbo sign-in form.
      # Wait for its document before Chrome inspects the next page's visibility.
      assert @page.has_css?("body", visible: :all, wait: WAIT) { |body| body.native != previous_body }
      assert @page.has_css?("h1", text: "Sign in to your application", wait: WAIT)
      @page.click_button "Continue"
      assert @page.has_field?("Message", wait: WAIT)
      assert_equal "rho", @page.title
      assert_nil URI(@page.current_url).query, "OAuth code is removed after login"
    end

    def resize(width, height)
      @browser.resize(width, height)
    end

    def screenshot(name)
      assert @page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "the page fits the viewport"
      E2E::SecretHygiene.save_screenshot(@browser, File.join(@artifacts, "#{name}.png"))
    end
end
