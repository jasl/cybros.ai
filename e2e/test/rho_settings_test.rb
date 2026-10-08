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

  def test_browser_connects_pairs_telegram_discovers_a_model_and_applies_settings_live
    visit_console
    assert @page.has_css?("dialog.settings-dialog[open]", wait: WAIT)
    @page.within('section[aria-label="Nexus account"]') do
      assert @page.has_text?("Signed in to Nexus as", wait: WAIT)
      assert @page.has_text?("owner")
    end
    @daemon.await_announced(address: "runner")
    web_tools = @daemon.control(:get, "/extensions").fetch("plugins").find { |plugin| plugin.fetch("id") == "rho.web_tools" }
    assert web_tools.fetch("enabled"), "Web tools are enabled without a saved override"
    assert web_tools.fetch("active"), "the default Web tools plugin starts successfully"
    refute_empty web_tools.fetch("description")
    @page.within('section[aria-label="Telegram setup"]') do
      assert @page.has_button?("Enable Telegram", wait: WAIT)
      assert @page.has_no_field?("Bot token")
    end
    screenshot("telegram-enable-desktop")
    resize(390, 844)
    screenshot("telegram-enable-narrow")
    @page.within('section[aria-label="Telegram setup"]') do
      @page.click_button "Enable Telegram"
      assert @page.has_text?("Connect your Telegram bot", wait: WAIT)
      assert @page.has_field?("Bot token")
      assert @page.has_no_button?("Enable Telegram")
    end
    resize(1400, 1000)
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
    assert @page.has_field?("Message grouping delay (seconds)", with: "2")
    @page.fill_in "Message grouping delay (seconds)", with: "3"
    @page.click_button "Save Telegram options"
    assert @page.has_text?("Telegram options are active.", wait: WAIT)
    assert_equal 3, telegram_status.dig("configuration", "input_debounce_seconds")
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
    @page.find('details[data-plugin-id="rho.web_tools"] > summary').click
    @page.within('details[data-plugin-id="rho.web_tools"]') do
      assert @page.has_text?(web_tools.fetch("description"))
      assert @page.has_text?("Requested: enabled")
    end
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

    @telegram.message(id: 2, user: 101, text: "!mock reply=uncorrected-request -- Start a long report")
    @telegram.message(id: 3, user: 101, text: "!mock reply=#{CGI.escape("Telegram settings are active.")} -- Actually, keep it brief")
    @daemon.await("the owner message did not use the configured model") do
      @telegram.messages.any? { |message| message.fetch("text").include?("Mock: Telegram settings are active.") }
    end
    assert_equal 4, telegram_status.fetch("offset")
    refute @telegram.messages.any? { |message| message.fetch("text").include?("Mock: uncorrected-request") }
    assert_equal 1, @telegram.messages.count { |message| message.fetch("text").include?("Mock: Telegram settings are active.") }
    errors = console_logs.select { |entry| entry.fetch("level") == "SEVERE" }
    assert_empty errors, E2E::SecretHygiene.redact(JSON.pretty_generate(errors))
  end

  def test_working_style_changes_publish_and_only_future_turns_read_the_new_prompt
    visit_console
    @daemon.await_announced(address: "runner")
    lane = provider("dev")
    lane.enable(expected_lock_version: lane.fetch.lock_version)
    @page.click_button "Refresh status"
    @page.select "dev/mock-text", from: "Default model"
    @page.click_button "Save default model"
    assert @page.has_text?("rho is ready to use", wait: WAIT)
    standard = system_prompt
    additional = "  Preserve this indentation.\n第二行：保留原文。\n"
    @page.select "Compact", from: "Work preset"
    @page.fill_in "Additional instructions", with: additional
    save_working_style
    compact = system_prompt
    assert_operator compact.bytesize, :<, standard.bytesize
    assert compact.end_with?("\n\n#{additional}")
    assert_equal additional, @daemon.control(:get, "/settings").dig("settings", "custom_instructions")
    @page.find("dialog.settings-dialog").scroll_to(@page.find('section[aria-label="Working style"]'), align: :top)
    screenshot("working-style-desktop")
    resize(390, 844)
    screenshot("working-style-narrow")
    resize(1400, 1000)

    base = "Use the initial custom base for this turn."
    @page.find("summary", text: "Advanced prompt settings", exact_text: true).click
    @page.check "Replace base prompt"
    @page.fill_in "Base prompt replacement", with: base
    save_working_style
    @page.find("dialog.settings-dialog").scroll_to(@page.find("summary", text: "Advanced prompt settings", exact_text: true), align: :top)
    screenshot("working-style-replacement-desktop")
    resize(390, 844)
    screenshot("working-style-replacement-narrow")
    resize(1400, 1000)
    captured_prompt = "#{base}\n\n#{additional}"
    assert_equal captured_prompt, system_prompt
    question = CGI.escape(JSON.generate("prompt" => "Continue with the captured prompt?"))
    opened = @daemon.control(:post, "/conversations", body: {
      "prompt" => "!mock tool_call=ask tool_args=#{question} -- ask before continuing",
      "model" => "dev/mock-text", "working_directory" => @project, "approval_mode" => "bypass",
    })
    conversation = opened.fetch("conversation").fetch("public_id")
    run = materialized_input(conversation, opened).fetch("run_public_id")
    pending = @daemon.await("the first turn never asked") do
      @daemon.control(:get, "/asks").fetch("asks").find { |row| row.fetch("run_public_id") == run && row.fetch("kind") == "ask" }
    end
    first_request = request_system_text(run, "r1")
    assert_includes first_request, captured_prompt

    updated = "  New instructions for the next turn.\n原样保留。\n"
    @page.fill_in "Additional instructions", with: updated
    save_working_style
    assert_equal "#{base}\n\n#{updated}", system_prompt, "a text-only edit republishes the Agent document"
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
    assert_includes system_text(next_request), "#{base}\n\n#{updated}"
    refute_includes system_text(next_request), additional

    @page.fill_in "Base prompt replacement", with: ""
    save_working_style
    assert_equal updated, system_prompt, "an explicit empty base retains additional instructions"
    assert_equal "", @daemon.control(:get, "/settings").dig("settings", "base_prompt")
    raw = @daemon.control(:post, "/runs", body: { "prompt" => "!mock reply=Raw%20turn -- answer", "model" => "dev/mock-text" })
    raw_run = raw.fetch("run").fetch("public_id")
    raw_result = completed_run(raw_run)
    raw_instructions = sealed_request(raw_run, raw_result.fetch("task_key")).fetch("request_options").fetch("instructions")
    assert raw_instructions.start_with?(updated), "standalone raw runs use the same configured prompt"

    @page.click_button "Restore built-in prompt"
    save_working_style
    assert_nil @daemon.control(:get, "/settings").dig("settings", "base_prompt")
    assert_equal compact.delete_suffix(additional) + updated, system_prompt
    @page.refresh
    @page.click_button "Settings", exact: true
    assert @page.has_select?("Work preset", selected: "Compact", wait: WAIT)
    assert @page.has_field?("Additional instructions", with: updated)
    assert_empty console_logs.select { |entry| entry.fetch("level") == "SEVERE" }
  end

  def test_browser_explains_missing_plugin_dependencies_and_keeps_settings_usable
    visit_console
    assert @page.has_css?("dialog.settings-dialog[open]", wait: WAIT)
    @page.find('details[data-plugin-id="rho.browser"] > summary').click
    @page.within('details[data-plugin-id="rho.browser"]') do
      @page.fill_in "Playwright driver command", with: JSON.generate(File.join(@project, "missing-playwright"))
      @page.click_button "Save configuration"
      assert @page.has_text?("Saved and applied.", wait: WAIT)
      @page.click_button "Enable plugin"
      assert @page.has_text?("Browser tools could not start Playwright and Chromium.", wait: WAIT)
      assert @page.has_text?("playwright install chromium")
      assert @page.has_text?("Requested: enabled")
      assert @page.has_text?("Running: inactive")
      @page.click_button "Retry activation"
      assert @page.has_button?("Retry activation", disabled: false, wait: WAIT)
      assert @page.has_text?("Browser tools could not start Playwright and Chromium.")
      assert @page.has_text?("Running: inactive")
    end
    browser_plugin = @daemon.control(:get, "/extensions").fetch("plugins").find { |plugin| plugin.fetch("id") == "rho.browser" }
    assert browser_plugin.fetch("enabled"), "the requested setting is saved for repair"
    refute browser_plugin.fetch("active"), "a plugin with missing dependencies never publishes its tools"
    assert_empty browser_plugin.dig("capabilities", "tools")
    @page.find("dialog.settings-dialog").scroll_to(@page.find('details[data-plugin-id="rho.browser"]'), align: :top)
    screenshot("browser-dependency-failure-desktop")
    resize(390, 844)
    @page.find("dialog.settings-dialog").scroll_to(@page.find('details[data-plugin-id="rho.browser"]'), align: :top)
    screenshot("browser-dependency-failure-narrow")
    @page.within('details[data-plugin-id="rho.browser"]') do
      @page.click_button "Disable plugin"
      assert @page.has_text?("Requested: disabled", wait: WAIT)
    end
    @page.click_button "Refresh status"
    @page.within('section[aria-label="Telegram setup"]') do
      assert @page.has_button?("Enable Telegram", wait: WAIT), "core management remains available after a plugin fails"
    end
    errors = console_logs.select { |entry| entry.fetch("level") == "SEVERE" }
    unexpected = errors.reject do |entry|
      entry.fetch("message").include?("/extensions/rho.browser/enable") && entry.fetch("message").include?("503")
    end
    assert_empty unexpected, E2E::SecretHygiene.redact(JSON.pretty_generate(unexpected))
  end

  def test_browser_installs_checks_activates_and_rolls_back_managed_packages
    visit_console
    assert @page.has_css?("dialog.settings-dialog[open]", wait: WAIT)
    source = package_source("first")
    install_package(source)
    first = selected_package_version
    @page.within('details[data-package-name="settings-package"]') do
      assert @page.has_text?("Saved: None · Running: None · Previous: None")
      @page.click_button "Check version"
      assert @page.has_text?("No test files were found; no tests ran.", wait: WAIT)
      @page.find("summary", text: "Activation configuration (optional)", exact_text: true).click
      @page.fill_in "Configuration overrides", with: JSON.generate("label" => "Ada")
      @page.click_button "Activate version"
      assert @page.has_text?("Selection saved and applied.", wait: WAIT)
      assert @page.has_field?("Configuration overrides", with: "")
    end
    assert_equal "first:Ada", @daemon.control(:get, "/settings-package").fetch("value")
    assert_package_versions(saved: first, running: first)
    @page.find("dialog.settings-dialog").scroll_to(@page.find('section[aria-label="Managed packages"]'), align: :top)
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
    @page.find("dialog.settings-dialog").scroll_to(@page.find('details[data-package-name="settings-package"]'), align: :top)
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
      @page.within('section[aria-label="Managed packages"]') do
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

    def save_working_style
      @page.click_button "Save working style"
      assert @page.has_text?("Settings saved and active.", wait: WAIT)
      assert @page.has_button?("Save working style", disabled: false, wait: WAIT)
    end

    def system_prompt = @daemon.control(:get, "/prompt/documents?slot=system_prompt").fetch("prompt_document").fetch("content")

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
      assert_equal "rho", @page.title
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
