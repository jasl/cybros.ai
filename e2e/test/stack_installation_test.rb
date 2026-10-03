require "test_helper"
require "net/http"
require "securerandom"
require "tempfile"
require "support/process_runner"
require "support/secret_hygiene"
require "support/mock_llm/app"

# Explicitly targets a fresh, disposable stack installed by install/stack.
# It never boots Nexus, creates database rows directly, calls an external
# provider, or tears down the caller's stack. Run with both explicit opt-ins.
class StackInstallationTest < Minitest::Test
  WAIT = 120
  PROVIDER = "stack-e2e".freeze
  MODEL = "#{PROVIDER}/mock-chat".freeze

  def setup
    skip "stack_installation requires E2E_STACK_DIR and E2E_BASE_URL" if
      ENV.fetch("E2E_STACK_DIR", "").empty? || ENV.fetch("E2E_BASE_URL", "").empty?

    # Compose includes absolute bind paths in its service configuration. Keep
    # symlink aliases from recreating services during the repeated-start check.
    @stack = File.realpath(ENV.fetch("E2E_STACK_DIR"))
    @base_url = ENV.fetch("E2E_BASE_URL")
    @command = File.join(@stack, "cybros")
    assert File.executable?(@command), "E2E_STACK_DIR must contain the installed cybros command"
    @rho_url = setting("CYBROS_RHO_URL")
    @setup_secret = secret("NEXUS_SETUP_SECRET")
    @generated_passphrase = secret("RHO_ACCESS_PASSPHRASE")
    @passphrase = E2E::SecretHygiene.register(SecureRandom.hex(24))
    @password = E2E::SecretHygiene.register(SecureRandom.hex(24))
    @artifacts = File.expand_path("../artifacts/stack_installation/#{Process.pid}", __dir__)
    @output = +""
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
      File.write(File.join(@artifacts, "browser-console.json"),
        E2E::SecretHygiene.redact(JSON.pretty_generate(@actor.console_logs)))
      E2E::SecretHygiene.save_screenshot(@actor, File.join(@artifacts, "failure.png")) unless passed?
    end
  rescue StandardError => error
    warn "Could not capture stack installation diagnostics: #{error.class}: #{E2E::SecretHygiene.redact(error.message)}"
  ensure
    begin
      unpause_setup
    ensure
      @actor&.close
      stop_mock_provider
    end
  end

  def test_first_account_pairs_full_rho_and_unlocks_the_shipped_webui
    found_installation
    start_foreign_authorization
    unpause_setup
    @identity = assert_connected_status
    assert_setup_exit(0)
    assert_two_executors
    assert_foreign_pending
    assert_password_survives_restart
    configure_model
    assert_model_discovery
    use_webui
    clear_model
    assert_repeated_start_preserves_pairing
    assert_revoke_requires_manual_reconnection
  end

  private

    def found_installation
      status = command_output("rho", "status")
      @rho_instance = status[/^instance:\s+(\S+)$/, 1]
      refute_nil @rho_instance, "the bundled rho must have prepared its instance"
      assert_anonymous_access_refused
      instructions = command_output("instructions")
      url = instructions[%r{https?://\S+#code=\S+}]
      refute_nil url, "cybros instructions must print a single-use rho console link"
      E2E::SecretHygiene.register(url)
      uri = URI(url)
      E2E::SecretHygiene.register(URI.decode_www_form(uri.fragment).to_h.fetch("code"))
      assert_nil uri.query, "the console code must not be sent in a URL query"
      refute instructions.include?(@setup_secret), "the terminal must not reveal the Nexus setup secret"
      refute instructions.include?(@generated_passphrase), "the terminal must not reveal the generated rho passphrase"
      E2E::SecretHygiene.during_reveal do
        @actor.visit(url)
        assert @page.has_text?("Set your rho password", wait: WAIT)
        assert @page.has_field?("rho password")
        assert @page.has_field?("Confirm rho password")
        assert @page.evaluate_script("window.location.hash").empty?,
          "rho spends and removes its console code"
        refute @page.has_link?("Open Nexus setup", wait: 0), "choose the rho password before opening Nexus setup"
      end
      screenshot("rho-password-desktop")
      resize(390, 844)
      screenshot("rho-password-narrow")
      E2E::SecretHygiene.during_reveal do
        @page.fill_in "rho password", with: @passphrase
        @page.fill_in "Confirm rho password", with: "#{@passphrase}-mismatch"
        @page.click_button "Save password and continue"
        assert @page.has_text?("The passwords do not match.")
        refute @page.has_link?("Open Nexus setup", wait: 0)
        @page.fill_in "Confirm rho password", with: @passphrase
        @page.click_button "Save password and continue"
        assert @page.has_link?("Open Nexus setup", wait: WAIT)
      end
      screenshot("rho-account-setup-narrow")
      resize(1400, 1000)
      screenshot("rho-account-setup-desktop")
      setup_url = @page.find_link("Open Nexus setup")[:href]
      E2E::SecretHygiene.register(setup_url)
      setup_uri = URI(setup_url)
      assert URI.decode_www_form(setup_uri.fragment).to_h["setup_secret"] == @setup_secret,
        "rho's authenticated link must carry this installation's setup secret"
      assert_nil setup_uri.query, "the setup secret must not be sent in a URL query"
      @nexus_window = @page.window_opened_by { @page.click_link "Open Nexus setup" }
      @page.within_window(@nexus_window) { create_first_account }
    end

    def create_first_account
      E2E::SecretHygiene.during_reveal do
        assert @page.has_field?("Installation name"), "this journey requires a fresh, uninitialized stack"
        assert @page.has_field?("Setup secret", with: @setup_secret, wait: WAIT),
          "opening the installation link must fill the setup secret"
        assert @page.evaluate_script("window.location.hash").empty?,
          "the setup page must remove the secret fragment from browser history"
        # Hold the helper that is waiting for the first Account until the
        # browser has created it and the foreign matching grant exists.
        @setup_paused = true
        command_output("compose", "--profile", "setup", "pause", "setup")
        @page.fill_in "Installation name", with: "Stack installation E2E"
        @page.fill_in "Your name", with: "Stack E2E Owner"
        @page.fill_in "Email", with: "owner@stack-installation.invalid"
        @page.fill_in "Password", with: @password
        @page.fill_in "Repeat password", with: @password
        @page.click_button "Create installation"
        assert @page.has_selector?("h1", text: "Dashboard", wait: WAIT)
      end
    end

    # A network visitor who knows the public rho URL has no console authority.
    # Neither the private Nexus bootstrap link nor first-password mutation
    # may cross that boundary without the single-use console handoff.
    def assert_anonymous_access_refused
      response = @http.get("/installation")
      assert_equal "401", response.code, "installation authority requires the rho console session"
      public_page = @http.get("/")
      assert_equal "200", public_page.code
      [response.body.to_s, public_page.body.to_s].each do |body|
        refute body.include?(@setup_secret), "anonymous responses must not reveal the Nexus setup secret"
        refute body.include?(@passphrase), "anonymous responses must not reveal the chosen rho password"
      end
      write = @http.patch("/settings", JSON.generate(access_passphrase: @passphrase), "content-type" => "application/json")
      assert_equal "401", write.code, "an anonymous visitor cannot claim rho by choosing its first password"
    end

    def unpause_setup
      return unless @setup_paused

      command_output("compose", "--profile", "setup", "unpause", "setup")
      @setup_paused = false
    end

    def start_foreign_authorization
      # Public callers can copy rho's identifiers. Only the exact grant
      # returned by the bundled daemon's authenticated control surface may
      # receive the installer's approval, even when another grant matches.
      @foreign_client = CybrosAgent::DeviceFlow::Client.new(base_url: @base_url, request_timeout: WAIT)
      E2E::DeviceAuthorizationBudget.consume
      @foreign_authorization = @foreign_client.request_authorization(
        agent_identifier: "rho.#{@rho_instance}", agent_display_name: "Unapproved device",
        executor_display_name: "Unapproved device",
        runner: { identifier: "rho.#{@rho_instance}", display_name: "Unapproved runner" }
      )
      E2E::SecretHygiene.register(@foreign_authorization.user_code)
      E2E::SecretHygiene.register(@foreign_authorization.device_code)
    end

    def assert_foreign_pending
      if @foreign_polled_at
        remaining = @foreign_polled_at + @foreign_authorization.interval - monotonic
        sleep remaining if remaining.positive?
      end
      result = @foreign_client.poll(@foreign_authorization)
      @foreign_polled_at = monotonic
      assert_instance_of CybrosAgent::DeviceFlow::Pending, result,
        "automatic setup must leave another device's matching request unapproved"
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
      @page.within_window(@nexus_window) do
        @actor.visit("/agents/#{@identity.fetch("profile")}")
        assert @page.has_css?("[data-address-id='#{@identity.fetch("executor")}']", count: 1)
      end
    end

    def assert_repeated_start_preserves_pairing
      command_output("up")
      assert_setup_exit(0)
      assert_equal @identity, assert_connected_status, "up must preserve the paired profile and both executor IDs"
      assert_equal @executors, executor_snapshot, "up must preserve both credential epochs, not re-pair the same IDs"
      assert_foreign_pending
      assert_equal :canceled, @foreign_client.cancel_authorization(@foreign_authorization)
    end

    def assert_revoke_requires_manual_reconnection
      @page.within_window(@nexus_window) do
        @actor.visit("/agents/#{@identity.fetch("profile")}")
        @page.find("button[aria-label^='Revoke credentials'], input[aria-label^='Revoke credentials']").click
        @page.find("#turbo-confirm button[value='confirm']").click
        assert @page.has_text?("Not registered"), "the owner revoked the Agent registration"
      end
      revoked = executor_snapshot
      agent = revoked.find { |row| row.fetch("public_id") == @identity.fetch("executor") }
      assert_equal "revoked", agent.fetch("status")
      assert_revoked_status

      command_output("up")
      assert_setup_exit(1)
      assert_match(/manual reconnect/, command_output("compose", "logs", "--no-color", "setup"))
      assert_equal revoked, executor_snapshot, "automatic setup must not undo an explicit revocation"
      assert_revoked_status
    end

    def assert_revoked_status
      # rho observes authority on its maintenance cadence. Wait for that
      # observation before rerunning setup, whose first read is /status.
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

    def assert_setup_exit(code)
      deadline = monotonic + WAIT
      loop do
        state = command_output("compose", "--profile", "setup", "ps", "--all",
          "--format", "{{.State}} {{.ExitCode}}", "setup").strip
        if state.start_with?("exited ")
          assert_equal "exited #{code}", state, command_output("compose", "logs", "--no-color", "setup")
          return
        end
        assert_operator monotonic, :<, deadline, "the installation helper did not exit: #{state}"
        sleep 0.2
      end
    end

    # Read-only internal observability. The browser/device flow above owns
    # every mutation; this snapshot detects silent re-pairing at the same IDs.
    def executor_snapshot
      script = <<~RUBY
        columns = %w[public_id executor_kind status credential_epoch assignment_scope]
        rows = TaskExecutor.order(:public_id).pluck(*columns)
        puts "STACK_EXECUTORS=" + JSON.generate(rows.map { |values| columns.zip(values).to_h })
      RUBY
      output = command_output("compose", "exec", "-T", "nexus", "bin/rails", "runner", script)
      line = output.lines.find { |entry| entry.start_with?("STACK_EXECUTORS=") }
      refute_nil line, "Nexus did not emit its executor snapshot"
      JSON.parse(line.delete_prefix("STACK_EXECUTORS="))
    end

    def assert_password_survives_restart
      assert @page.has_css?("dialog.settings-dialog[open]", wait: WAIT)
      assert @page.has_text?("rho is connected to Nexus.")
      command_output("compose", "restart", "rho")
      command_output("compose", "up", "--wait", "--no-deps", "rho")
      assert_equal @identity, assert_connected_status, "a rho restart retains all paired identities"
      @page.refresh
      assert @page.has_field?("Access passphrase", wait: WAIT)
      refute @page.has_link?("Open Nexus setup", wait: 0)
      assert_anonymous_access_refused
      E2E::SecretHygiene.during_reveal do
        @page.fill_in "Access passphrase", with: @passphrase
        @page.click_button "Unlock"
        assert @page.has_field?("Message", wait: WAIT)
        assert @page.has_no_field?("Access passphrase")
      end
      assert @page.has_css?("dialog.settings-dialog[open]", wait: WAIT)
      assert @page.has_text?("rho is connected to Nexus.")
      refute @page.has_text?("Set your rho password", wait: 0)
      # Check the superseded bootstrap password after the successful login:
      # its deliberate failure arms rho's ordinary unlock backoff.
      refused = @http.post("/unlock", JSON.generate(passphrase: @generated_passphrase), "content-type" => "application/json")
      assert_equal "401", refused.code, "the generated bootstrap passphrase must no longer unlock rho"
      assert_equal "invalid_passphrase", JSON.parse(refused.body).dig("error", "code")
    end

    def use_webui
      @page.click_button "Refresh status"
      assert @page.has_text?("Default model: #{MODEL}.", wait: WAIT)
      @page.click_button "Close", exact: true
      resize(1400, 1000)
      assert @page.has_button?("New conversation")
      @page.click_button "New conversation"
      assert @page.has_css?("#model option:checked[value='#{MODEL}']:not([disabled])", visible: :all, wait: WAIT)
      @page.fill_in "Message", with: "!mock reply=Installation+is+ready. -- Say the installation is ready."
      @page.click_button "Send"
      assert @page.has_text?("Mock: Installation is ready.", wait: WAIT)
      screenshot("rho-first-conversation-desktop")
      resize(390, 844)
      screenshot("rho-first-conversation-narrow")
      @page.refresh
      assert @page.has_field?("Message", wait: WAIT), "the browser session survives a page reload"
      assert @page.has_text?("Mock: Installation is ready.", wait: WAIT)
    end

    # The fake provider runs on the disposable stack's own Docker network.
    # It needs no host gateway, public port, real credential or Nexus hook.
    def start_mock_provider
      name = "stack-e2e-provider-#{SecureRandom.hex(8)}"
      source = File.expand_path("../support/mock_llm", __dir__)
      script = <<~RUBY
        server = Puma::Server.new(E2E::MockLLM::App.new)
        server.add_tcp_listener("0.0.0.0", 8080)
        server.run.join
      RUBY
      command_output("compose", "run", "--rm", "--detach", "--no-deps", "--name", name,
        "--volume", "#{source}:/mock:ro", "--entrypoint", "ruby", "nexus",
        "-rbundler/setup", "-rpuma", "-r/mock/app", "-e", script)
      @mock_container = name
    end

    def stop_mock_provider
      return unless @mock_container

      run_command("docker", "rm", "--force", @mock_container)
      @mock_container = nil
    end

    def resize(width, height)
      @page.current_window.resize_to(width, height)
      @page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: width, height: height, deviceScaleFactor: 1, mobile: false)
      assert_equal width, @page.evaluate_script("window.innerWidth")
    end

    def screenshot(name) = E2E::SecretHygiene.save_screenshot(@actor, File.join(@artifacts, "#{name}.png"))

    def cmctl(*arguments, stdin: nil)
      JSON.parse(command_output("cmctl", *arguments, stdin: stdin))
    end

    def command_output(*arguments, stdin: nil)
      run_command(@command, *arguments, stdin: stdin)
    end

    def run_command(executable, *arguments, stdin: nil)
      Tempfile.create("cybros-stack-e2e") do |file|
        status = E2E::ProcessRunner.run(executable, *arguments, chdir: @stack,
          stdin: stdin, out: file, err: file, timeout: WAIT)
        file.rewind
        output = file.read
        output.scan(%r{https?://\S+#code=\S+}).each do |url|
          E2E::SecretHygiene.register(url)
          E2E::SecretHygiene.register(URI.decode_www_form(URI(url).fragment).to_h.fetch("code"))
        end
        @output << "$ #{File.basename(executable)} #{arguments.first}\n#{output}\n"
        assert_predicate status, :success?, E2E::SecretHygiene.redact(output)
        output
      end
    end

    def secret(key)
      E2E::SecretHygiene.register(dotenv_value("secrets.env", key))
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
