require "test_helper"
require "digest"
require "net/http"
require "securerandom"
require "tempfile"
require "support/process_runner"
require "support/secret_hygiene"
require "support/stack_installation_upgrade"
require "support/mock_llm/app"

# Explicitly targets a fresh, disposable stack installed by install/stack.
# It never boots Nexus, creates database rows directly, calls an external
# provider, or tears down the caller's stack by default. Run with both explicit opt-ins.
# E2E_STACK_UPGRADE_RELEASE exercises separate Nexus and rho browser upgrades to that release.
# E2E_STACK_UPGRADE_BACKUP=false exercises the Nexus upgrade with its backup unchecked.
# E2E_STACK_RESTORE_DIR additionally restores that disposable installation to an
# empty directory, replacing its stopped containers while retaining source data.
class StackInstallationTest < Minitest::Test
  include E2E::StackInstallationUpgrade
  WAIT = 120
  UPGRADE_WAIT = 600
  PROVIDER = "stack-e2e".freeze
  MODEL = "#{PROVIDER}/mock-chat".freeze

  def setup
    skip "stack_installation requires E2E_STACK_DIR and E2E_BASE_URL" if
      ENV.fetch("E2E_STACK_DIR", "").empty? || ENV.fetch("E2E_BASE_URL", "").empty?

    # Compose includes absolute bind paths in its service configuration. Keep
    # symlink aliases from recreating services during the repeated-start check.
    @stack = File.realpath(ENV.fetch("E2E_STACK_DIR"))
    if !ENV.fetch("E2E_STACK_RESTORE_DIR", "").empty?
      refute_empty ENV.fetch("E2E_STACK_UPGRADE_RELEASE", ""), "the restore drill accompanies the upgrade preservation journey"
    end
    @base_url = ENV.fetch("E2E_BASE_URL")
    @command = File.join(@stack, "cybros")
    assert File.executable?(@command), "E2E_STACK_DIR must contain the installed cybros command"
    @rho_url = setting("CYBROS_RHO_URL")
    @password = E2E::SecretHygiene.register(SecureRandom.hex(24))
    @artifacts = File.expand_path("../artifacts/stack_installation/#{Process.pid}", __dir__)
    @output = +""
    @console_logs = []
    @actor = E2E::BrowserActor.new(@base_url)
    @page = @actor.page
    uri = URI(@rho_url)
    @http = Net::HTTP.new(uri.host, uri.port)
    @http.use_ssl = uri.scheme == "https"
    @http.open_timeout = 5
    @http.read_timeout = 10
    @http.max_retries = 0
    start_mock_provider
  end

  def teardown
    if @actor
      FileUtils.mkdir_p(@artifacts)
      File.write(File.join(@artifacts, "commands.log"), E2E::SecretHygiene.redact(@output))
      @console_logs.concat(@actor.console_logs)
      File.write(File.join(@artifacts, "browser-console.json"),
        E2E::SecretHygiene.redact(JSON.pretty_generate(@console_logs)))
      # This journey intentionally stops HTTP services during restart, upgrade
      # and restore. Those network errors must not hide JavaScript exceptions.
      errors = @console_logs.select do |entry|
        entry.fetch("level") == "SEVERE" && !entry["expected_workspace_initialization"] &&
          !entry.fetch("message").match?(/Failed to load resource: (net::ERR_CONNECTION_(REFUSED|RESET|CLOSED)|net::ERR_EMPTY_RESPONSE|the server responded with a status of 502 \(Bad Gateway\))\z/)
      end
      E2E::SecretHygiene.save_screenshot(@actor, File.join(@artifacts, "failure.png")) unless passed? && errors.empty?
      assert_empty errors, E2E::SecretHygiene.redact(JSON.pretty_generate(errors))
    end
  rescue StandardError => error
    warn "Could not capture stack installation diagnostics: #{error.class}: #{E2E::SecretHygiene.redact(error.message)}"
  ensure
    @actor&.close
    stop_mock_provider
  end

  def test_first_account_resumes_oauth_and_code_and_device_logins_reuse_the_rho_binding
    found_installation
    @identity = assert_connected_status
    assert_initial_conversation_list
    assert_two_executors
    assert_code_login_reuses_binding
    assert_device_login_reuses_binding
    assert_browser_session_survives_restart
    configure_model
    assert_model_discovery
    use_webui
    assert_upgrade_preserves_installation
    clear_model
    assert_repeated_start_preserves_pairing
    assert_revoke_requires_manual_reconnection
  end

  private

    def assert_initial_conversation_list
      # Human login can finish just before the daemon creates its first
      # workspace. Keep that initial list refusal distinct from later errors,
      # and require the same read to succeed once workspace adoption is ready.
      initial_logs = @actor.console_logs
      @console_logs.concat(initial_logs)
      assert_empty rho_api("/conversations?limit=40&archived=0").fetch("conversations")
      expected = "#{@rho_url}/conversations?limit=40&archived=0 - Failed to load resource: the server responded with a status of 409 (Conflict)"
      initial_logs.each do |entry|
        entry["expected_workspace_initialization"] = true if entry.fetch("message") == expected
      end
    end

    def found_installation
      assert_anonymous_access_refused
      instructions = command_output("instructions")
      assert_includes instructions, @rho_url
      @actor.visit(@rho_url)
      assert @page.has_button?("Connect to Nexus", wait: WAIT)
      assert @page.has_button?("Use a device code")
      assert @page.has_no_field?("Password")
      screenshot("rho-login-desktop")
      resize(390, 844)
      screenshot("rho-login-narrow")
      @page.click_button "Connect to Nexus"
      create_first_account
      assert @page.has_selector?("h1", text: "Sign in to your application", wait: WAIT)
      assert @page.has_no_field?("Password"), "first boot already authenticated the owner"
      @page.click_button "Continue"
      assert @page.has_field?("Message", wait: WAIT)
      assert_equal URI(@rho_url).host, URI(@page.current_url).host
      assert_nil URI(@page.current_url).query, "the callback code is cleared"
      assert_model_setup_pending
      screenshot("rho-setup-after-first-boot-narrow")
      resize(1400, 1000)
    end

    def create_first_account
      E2E::SecretHygiene.during_reveal do
        assert @page.has_field?("Installation name"), "this journey requires a fresh, uninitialized stack"
        assert @page.has_no_field?("Setup secret"), "a default installation creates its first owner without an extra secret"
        @page.fill_in "Installation name", with: "Stack installation E2E"
        @page.fill_in "Your name", with: "Stack E2E Owner"
        @page.fill_in "Email", with: "owner@stack-installation.invalid"
        @page.fill_in "Password", with: @password
        @page.fill_in "Repeat password", with: @password
        @page.click_button "Create installation"
      end
    end

    # Public login starts carry only a transaction. They cannot reveal the
    # owner's password or mutate rho's authenticated settings.
    def assert_anonymous_access_refused
      ["/", "/auth/status"].each do |path|
        response = @http.get(path)
        assert_equal "200", response.code
        refute_includes response.body.to_s, @password
      end
      assert_equal "401", @http.get("/settings").code
      write = @http.patch("/settings", JSON.generate(default_model: "unapproved/model"), "content-type" => "application/json")
      assert_equal "401", write.code
    end

    # Sign out lives on the General settings page.
    def sign_out
      open_settings
      @page.click_button "Sign out"
      assert @page.has_button?("Connect to Nexus", wait: WAIT)
      assert @page.has_no_field?("Message")
    end

    # Below the narrow breakpoint the sidebar is a drawer behind one button.
    def open_settings
      return if @page.has_css?(".settings-page", wait: 0)

      @page.click_button "Open sidebar" unless @page.has_link?("Settings", exact: true, wait: 0)
      @page.click_link "Settings", exact: true
      assert @page.has_css?(".settings-page", wait: WAIT)
    end

    # rho's default model is the default agent's setting, under Agents.
    def open_rho_settings
      @page.click_button "Open sidebar" unless @page.has_link?("Agents", exact: true, wait: 0)
      @page.click_link "Agents", exact: true
      @page.within('article[data-bot="own"]') { @page.click_button "Settings", exact: true }
      assert @page.has_css?(".bots-page__rho", wait: WAIT)
    end

    # Back to the conversation panel: the sidebar's new conversation.
    def close_settings
      @page.click_button "Open sidebar" unless @page.has_css?(".sidebar__new", wait: 0)
      @page.find(".sidebar__new").click
      assert @page.has_field?("Message", wait: WAIT)
      return unless @page.has_button?("Close sidebar", wait: 0)

      @page.click_button "Close sidebar"
      assert @page.has_no_button?("Close sidebar", wait: WAIT)
    end

    # Without a model the new-conversation page points at setup instead of
    # navigating away by itself.
    def assert_model_setup_pending
      assert @page.has_text?("To do: configure a model in Nexus", wait: WAIT), "the page names the missing model setup"
      @page.click_button "Agent settings"
      assert @page.has_css?(".bots-page__rho", wait: WAIT), "the notice opens rho's own settings"
      assert @page.has_select?("Model"), "rho's own settings offer the default model"
      close_settings
    end

    def assert_default_model_selected
      row = rho_api("/models?workload=text_generation").fetch("models").find { |model| model.fetch("ref") == MODEL }
      label = row&.fetch("display_name", nil) || MODEL
      assert @page.has_button?("Model: #{label}", wait: WAIT), "a new conversation starts on the default model"
    end

    def send_message(text)
      @page.fill_in "Message", with: text
      assert @page.has_field?("Message", with: text)
      @page.find("button.send:not([disabled])", wait: WAIT).click
    end

    def code_login
      # Each OAuth navigation replaces the document. Wait for that replacement
      # before Chrome inspects the destination's visible elements.
      previous_body = @page.find("body", visible: :all).native
      @page.click_button "Connect to Nexus"
      assert @page.has_css?("body", visible: :all, wait: WAIT) { |body| body.native != previous_body }
      assert @page.has_selector?("h1", text: "Sign in to your application", wait: WAIT)
      previous_body = @page.find("body", visible: :all).native
      @page.click_button "Continue"
      assert @page.has_css?("body", visible: :all, wait: WAIT) { |body| body.native != previous_body }
      assert @page.has_css?(".settings-page", wait: WAIT), "Code login returns to the Settings page it started from"
      assert @page.has_button?("Sign out")
      assert_nil URI(@page.current_url).query
      close_settings
    end

    def assert_code_login_reuses_binding
      sign_out
      code_login
      assert_equal @identity, assert_connected_status
      assert_equal @executors, executor_snapshot, "browser login must not rotate the running Agent or Runner"
    end

    def assert_device_login_reuses_binding
      sign_out
      E2E::DeviceAuthorizationBudget.consume
      @page.click_button "Use a device code"
      assert @page.has_link?("Open Nexus to approve", wait: WAIT)
      device_window = @page.window_opened_by { @page.click_link "Open Nexus to approve" }
      @page.within_window(device_window) do
        @page.click_button "Continue"
        @page.click_button "Connect", exact: true
        assert @page.has_text?(/Connection ready|This connection is complete/)
      end
      device_window.close
      assert @page.has_css?(".settings-page", wait: WAIT), "Device login retains the Settings page it started from"
      assert @page.has_button?("Sign out")
      close_settings
      assert_equal @identity, assert_connected_status
      assert_equal @executors, executor_snapshot, "Device login shares the existing binding without re-pairing"
    end

    def configure_model
      login = cmctl("login", "--url", "http://nexus", "--email", "owner@stack-installation.invalid",
        "--password-stdin", stdin: "#{@password}\n")
      assert login.fetch("connected")
      assert_equal "human", cmctl("status").dig("member", "kind")
      assert_equal "USD", cmctl("account", "cost-unit", "USD").dig("account", "cost_unit")
      added = cmctl("provider", "add", PROVIDER, "--base-url", "http://#{@mock_container}:8080/v1",
        "--api-format", "openai_responses", "--credentials", "api_key", "--display-name", "Installation test provider")
      refute added.fetch("model_provider").fetch("configured")
      key = E2E::SecretHygiene.register(E2E::MockLLM::App::API_KEY)
      assert cmctl("provider", "key", "set", PROVIDER, "--stdin", stdin: "#{key}\n")
        .fetch("model_provider").fetch("configured")
      directory = cmctl("provider", "discover", PROVIDER).fetch("models")
      assert_includes directory.map { |row| row.fetch("id") }, "mock-keyed-text"
      cmctl("model", "add", MODEL, "--model-id", "mock-keyed-text",
        "--input-tokens", "32768", "--output-tokens", "8192", "--tools")
      assert cmctl("provider", "enable", PROVIDER).fetch("model_provider").fetch("enabled")
      assert_includes cmctl("models", "--available").fetch("models").map { |row| row.fetch("ref") }, MODEL
    end

    def assert_model_discovery
      models = JSON.parse(command_output("rho", "models", "--json")).fetch("models")
      assert_includes models.map { |model| model.fetch("ref") }, MODEL
    end

    def clear_model
      refute cmctl("provider", "key", "clear", PROVIDER).fetch("model_provider").fetch("configured")
      refute cmctl("provider", "disable", PROVIDER).fetch("model_provider").fetch("enabled")
      assert cmctl("logout").fetch("logged_out")
    end

    def assert_connected_status
      deadline = monotonic + WAIT
      loop do
        output = command_output("rho", "status")
        if output.match?(/^\s+runner_transport: live$/) && output.match?(/^runner:\s+\S+ serving \d+ tools/) &&
            output.match?(/^workspace:\s+dedicated /)
          assert_match(/^mode:\s+full$/, output)
          assert_match(/^state:\s+signed in$/, output)
          assert_match(/^\s+member: live$/, output)
          assert_match(/^\s+executor_transport: live$/, output)
          FileUtils.mkdir_p(@artifacts)
          File.write(File.join(@artifacts, "rho-status.log"), E2E::SecretHygiene.redact(output))
          return %w[profile executor runner].to_h do |name|
            id = output[/^#{name}:\s+(\S+)/, 1]
            refute_nil id, "rho status must identify its #{name}"
            assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/, id)
            [name, id]
          end
        end
        assert_operator monotonic, :<, deadline, E2E::SecretHygiene.redact(output)
        sleep 0.2
      end
    end

    def assert_two_executors
      @executors = executor_snapshot
      assert_equal 2, @executors.length, "full rho pairs one Agent executor and one private Runner"
      assert_equal %w[agent_application runner], @executors.map { |row| row.fetch("executor_kind") }.sort
      assert_equal [@identity.fetch("executor"), @identity.fetch("runner")].sort,
        @executors.map { |row| row.fetch("public_id") }.sort
      assert @executors.all? { |row| row.fetch("status") == "active" }
      assert_equal "user_private", @executors.find { |row| row.fetch("executor_kind") == "runner" }.fetch("assignment_scope")
    end

    def assert_repeated_start_preserves_pairing
      rho_page = @page.current_url
      selected = URI(rho_page).path.match(%r{\A/workspaces/([^/]+)/conversations/([^/]+)\z})
      refute_nil selected, "repeated start retains the current conversation"
      workspace, conversation = selected.captures
      history = turns(conversation, workspace: workspace)
      # This CLI pairing check resumes browser reads after stored credentials
      # are adopted; the component-upgrade checks keep their live tab throughout.
      @page.visit("about:blank")
      command_output("up")
      assert_equal @identity, assert_connected_status, "up preserves the profile and both executor IDs"
      assert_equal @executors, executor_snapshot, "up preserves credential epochs without an approval helper"
      @page.visit(rho_page)
      assert @page.has_field?("Message", wait: WAIT), "the existing Human session resumes its conversation after up"
      assert @page.has_no_button?("Connect to Nexus")
      assert_equal history, turns(conversation, workspace: workspace)
    end

    def assert_revoke_requires_manual_reconnection
      nexus_window = @page.open_new_window
      @page.within_window(nexus_window) do
        @actor.visit("/agents/#{@identity.fetch("profile")}")
        @page.find("button[aria-label^='Revoke credentials'], input[aria-label^='Revoke credentials']").click
        @page.find("#turbo-confirm button[value='confirm']").click
        assert @page.has_text?("No application connected"), "the owner revoked the Agent registration"
        assert @page.has_no_css?("[data-address-id]"), "the revoked application address is no longer shown"
      end
      nexus_window.close
      revoked = executor_snapshot
      agent = revoked.find { |row| row.fetch("public_id") == @identity.fetch("executor") }
      assert_equal "revoked", agent.fetch("status")
      assert_revoked_status
      command_output("up")
      assert_equal revoked, executor_snapshot, "starting services does not undo explicit revocation"
      assert_revoked_status
    end

    def assert_revoked_status
      # rho observes authority on its maintenance cadence. Wait for that
      # observation before restarting services and checking retained authority.
      deadline = monotonic + WAIT
      loop do
        output = command_output("rho", "status")
        return if output.match?(/^\s+member: unauthorized$/) &&
          output.match?(/^\s+executor_transport: unauthorized$/) &&
          output.match?(/^\s+runner_transport: live$/)

        assert_operator monotonic, :<, deadline, E2E::SecretHygiene.redact(output)
        sleep 0.2
      end
    end

    # Read-only internal observability. The browser/device flow above owns
    # every mutation; this snapshot detects silent re-pairing at the same IDs.
    def executor_snapshot
      script = <<~RUBY
        columns = %w[public_id executor_kind status credential_epoch assignment_scope]
        rows = Executor.order(:public_id).pluck(*columns)
        puts "STACK_EXECUTORS=" + JSON.generate(rows.map { |values| columns.zip(values).to_h })
      RUBY
      output = command_output("compose", "exec", "-T", "nexus", "bin/rails", "runner", script)
      line = output.lines.find { |entry| entry.start_with?("STACK_EXECUTORS=") }
      refute_nil line, "Nexus did not emit its executor snapshot"
      JSON.parse(line.delete_prefix("STACK_EXECUTORS="))
    end

    def assert_browser_session_survives_restart
      command_output("compose", "restart", "rho")
      command_output("compose", "up", "--wait", "--no-deps", "rho")
      assert_equal @identity, assert_connected_status, "a rho restart retains all connected identities"
      @page.refresh
      assert @page.has_field?("Message", wait: WAIT), "the tab retains its valid Human session across a daemon restart"
      assert @page.has_no_button?("Connect to Nexus")
      assert_anonymous_access_refused
      assert_equal @executors, executor_snapshot, "restarting preserves the runtime credential epochs"
      sign_out
      code_login
      assert_model_setup_pending
    end

    def use_webui
      open_rho_settings
      @page.click_button "Refresh", exact: true
      assert @page.has_select?("Model", selected: MODEL, wait: WAIT), "the sole eligible model is adopted automatically"
      close_settings
      resize(1400, 1000)
      assert @page.has_button?("New conversation")
      @page.click_button "New conversation"
      assert_default_model_selected
      send_message("!mock reply=Installation+is+ready. -- Say the installation is ready.")
      assert @page.has_text?("Mock: Installation is ready.", wait: WAIT)
      screenshot("rho-first-conversation-desktop")
      resize(390, 844)
      screenshot("rho-first-conversation-narrow")
      @page.refresh
      assert @page.has_field?("Message", wait: WAIT), "the browser session survives a page reload"
      assert @page.has_text?("Mock: Installation is ready.", wait: WAIT)
    end

    def turns(public_id, workspace: nil)
      query = { public_id: public_id }
      query[:workspace_public_id] = workspace if workspace
      rho_api("/conversations/turns?#{URI.encode_www_form(query)}").fetch("turns")
    end

    def completed_turns(public_id, workspace: nil)
      deadline = monotonic + WAIT
      loop do
        turns = turns(public_id, workspace: workspace)
        return turns if turns.any? && turns.all? { |turn| turn.fetch("status") == "completed" }

        assert_operator monotonic, :<, deadline, "the conversation did not finish before the upgrade snapshot"
        sleep 0.2
      end
    end

    def rho_api(path)
      @page.driver.browser.manage.timeouts.script_timeout = WAIT
      response = @page.evaluate_async_script(<<~JAVASCRIPT, path)
        const path = arguments[0], done = arguments[arguments.length - 1];
        import('/kernel/api.js').then(api => api.call(path)).then(
          data => done({ data }), error => done({ error: error.message }));
      JAVASCRIPT
      refute response.key?("error"), response["error"]
      response.fetch("data")
    end

    def rho_artifact_bytes(attachment)
      response = @page.evaluate_async_script(<<~JAVASCRIPT, attachment)
        const attachment = arguments[0], done = arguments[arguments.length - 1];
        import('/kernel/api.js').then(api => api.artifactBytes(attachment, null))
          .then(blob => blob.arrayBuffer()).then(
            bytes => done({ data: Array.from(new Uint8Array(bytes)) }),
            error => done({ error: error.message }));
      JAVASCRIPT
      refute response.key?("error"), response["error"]
      response.fetch("data")
    end

    # The fake provider runs on the disposable stack's own Docker network.
    # It needs no host gateway, public port, real credential or Nexus hook.
    def start_mock_provider
      name = "stack-e2e-provider-#{SecureRandom.hex(8)}"
      source = File.expand_path("../support/mock_llm", __dir__)
      @provider_directory = File.join(@stack, "provider-fixture")
      FileUtils.mkdir_p(@provider_directory, mode: 0o777)
      File.chmod(0o777, @provider_directory)
      script = <<~RUBY
        app = E2E::MockLLM::StackUpgrade.new(E2E::MockLLM::App.new, directory: "/fixture")
        server = Puma::Server.new(app)
        server.add_tcp_listener("0.0.0.0", 8080)
        server.run.join
      RUBY
      command_output("compose", "run", "--rm", "--detach", "--no-deps", "--name", name,
        "--volume", "#{source}:/mock:ro", "--volume", "#{@provider_directory}:/fixture", "--entrypoint", "ruby", "nexus",
        "-rbundler/setup", "-rpuma", "-r/mock/stack_upgrade", "-e", script)
      @mock_container = name
    end

    def stop_mock_provider
      return unless @mock_container

      run_command("docker", "rm", "--force", @mock_container)
      @mock_container = nil
    end

    def resize(width, height)
      @actor.resize(width, height)
      assert_equal width, @page.evaluate_script("window.innerWidth")
      return unless @page.has_css?(".frame", wait: 0)

      if width < 768
        assert @page.has_button?("Open sidebar", wait: WAIT), "a narrow page keeps the sidebar behind one button"
      else
        assert @page.has_link?("Settings", exact: true, wait: WAIT), "a wide page shows the sidebar"
      end
    end

    def screenshot(name) = E2E::SecretHygiene.save_screenshot(@actor, File.join(@artifacts, "#{name}.png"))

    def cmctl(*arguments, stdin: nil)
      JSON.parse(command_output("cmctl", *arguments, stdin: stdin))
    end

    def command_output(*arguments, stdin: nil, timeout: WAIT)
      run_command(@command, *arguments, stdin: stdin, timeout: timeout)
    end

    def run_command(executable, *arguments, stdin: nil, timeout: WAIT)
      Tempfile.create("cybros-stack-e2e") do |file|
        Tempfile.create("cybros-stack-e2e-stderr") do |errors|
          status = E2E::ProcessRunner.run(executable, *arguments, chdir: @stack,
            stdin: stdin, out: file, err: errors, timeout: timeout)
          file.rewind
          errors.rewind
          output = file.read
          diagnostics = errors.read
          (output + diagnostics).scan(%r{https?://\S+/setup#setup_secret=\S+}).each do |url|
            E2E::SecretHygiene.register(url)
          end
          @output << "$ #{File.basename(executable)} #{arguments.first}\n#{output}\n#{diagnostics}\n"
          assert_predicate status, :success?, E2E::SecretHygiene.redact(output + diagnostics)
          output
        end
      end
    end

    def setting(key) = dotenv_value(".env", key)

    # The installer writes single-quoted dotenv literals. Read that format,
    # never source a configuration file as executable shell code.
    def dotenv_value(filename, key)
      File.foreach(File.join(@stack, filename)) do |line|
        match = line.match(/\A#{Regexp.escape(key)}='([^'\n]+)'\s*\z/)
        return match[1] if match
      end
      flunk "#{filename} has no generated #{key} setting"
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
