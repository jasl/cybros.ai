require "test_helper"
require "digest"
require "net/http"
require "securerandom"
require "tempfile"
require "support/process_runner"
require "support/secret_hygiene"
require "support/mock_llm/app"

# Explicitly targets a fresh, disposable stack installed by install/stack.
# It never boots Nexus, creates database rows directly, calls an external
# provider, or tears down the caller's stack by default. Run with both explicit opt-ins.
# E2E_STACK_UPGRADE_RELEASE also exercises a Nexus-only browser upgrade to that release.
# E2E_STACK_UPGRADE_BACKUP=false exercises the same upgrade with its backup unchecked.
# E2E_STACK_RESTORE_DIR additionally restores that disposable installation to an
# empty directory, replacing its stopped containers while retaining source data.
class StackInstallationTest < Minitest::Test
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
      assert @page.has_css?("dialog.settings-dialog[open]", wait: WAIT), "models are configured after login"
      screenshot("rho-settings-after-first-boot-narrow")
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

    def sign_out
      @page.click_button "Close", exact: true if @page.has_css?("dialog.settings-dialog[open]", wait: 0)
      @page.click_button "Sign out"
      assert @page.has_button?("Connect to Nexus", wait: WAIT)
      assert @page.has_no_field?("Message")
    end

    def code_login
      @page.click_button "Connect to Nexus"
      assert @page.has_selector?("h1", text: "Sign in to your application", wait: WAIT)
      @page.click_button "Continue"
      assert @page.has_field?("Message", wait: WAIT)
      assert_nil URI(@page.current_url).query
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
      assert @page.has_field?("Message", wait: WAIT)
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
      command_output("up")
      assert_equal @identity, assert_connected_status, "up preserves the profile and both executor IDs"
      assert_equal @executors, executor_snapshot, "up preserves credential epochs without an approval helper"
    end

    def assert_revoke_requires_manual_reconnection
      nexus_window = @page.open_new_window
      @page.within_window(nexus_window) do
        @actor.visit("/agents/#{@identity.fetch("profile")}")
        @page.find("button[aria-label^='Revoke credentials'], input[aria-label^='Revoke credentials']").click
        @page.find("#turbo-confirm button[value='confirm']").click
        assert @page.has_text?("Not registered"), "the owner revoked the Agent registration"
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
        rows = TaskExecutor.order(:public_id).pluck(*columns)
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
      assert @page.has_css?("dialog.settings-dialog[open]", wait: WAIT)
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

    def assert_upgrade_preserves_installation
      release = ENV.fetch("E2E_STACK_UPGRADE_RELEASE", "")
      return if release.empty?

      assert_match(/\A[0-9]{10}\z/, release, "E2E_STACK_UPGRADE_RELEASE must be a UTC yyMMddHHmm release tag")
      selected = URI.decode_www_form(URI(@page.current_url).query.to_s).to_h
      conversation = selected.fetch("conversation")
      workspace = selected.fetch("workspace")
      history = completed_conversation_turns(conversation, workspace: workspace)
      refute_empty history
      settings = rho_api("/settings").fetch("settings")
      assert_equal MODEL, settings.fetch("default_model")
      provider = cmctl("provider", "show", PROVIDER)
      assert provider.fetch("model_provider").fetch("configured")
      assert provider.fetch("model_provider").fetch("enabled")
      model = configured_model
      private_files = %w[.env secrets.env].to_h do |name|
        [name, Digest::SHA256.file(File.join(@stack, name)).digest]
      end

      filename = "stack-upgrade-#{SecureRandom.hex(8)}.txt"
      fixture = File.join(@stack, "data", "rho", "work", filename)
      bytes = "Synthetic upgrade attachment\n#{SecureRandom.hex(16)}\n"
      File.binwrite(fixture, bytes)
      File.chmod(0o644, fixture)
      attached = JSON.parse(command_output("rho", "run",
        "!mock reply=Upgrade+attachment+stored. -- Keep this synthetic attachment.",
        "--model", MODEL, "--no-code-mode", "--attach", "/home/runner/#{filename}", "--output-format", "json"))
      assert_equal "success", attached.fetch("subtype")
      attached_conversation = attached.fetch("conversation_id")
      attached_history = completed_conversation_turns(attached_conversation)
      attachment = attached_history.flat_map { |turn| turn.fetch("active_variant").fetch("attachments", []) }
        .find { |entry| entry.fetch("filename") == filename }
      refute_nil attachment, "the public transcript must retain the uploaded attachment"
      assert_equal bytes.bytes, rho_artifact_bytes(attachment)
      # The saved upload must supply these bytes independently of its sender's file.
      File.unlink(fixture)

      upgrade_from_browser(release)
      private_files.each do |name, digest|
        assert digest == Digest::SHA256.file(File.join(@stack, name)).digest,
          "#{name} changed during upgrade"
      end
      restore_installation_if_requested
      assert private_files.fetch("secrets.env") == Digest::SHA256.file(File.join(@stack, "secrets.env")).digest,
        "restoration must retain the original deployment secrets"
      assert_equal @identity, assert_connected_status, "upgrading preserves the profile and both executor IDs"
      assert_equal @executors, executor_snapshot, "upgrading must not re-pair the Agent or Runner"
      @page.refresh
      assert @page.has_field?("Message", wait: WAIT), "the existing rho tab keeps its Human session after upgrade"
      assert @page.has_no_button?("Connect to Nexus")
      assert @page.has_text?("Mock: Installation is ready.", wait: WAIT)
      assert_equal history, conversation_turns(conversation, workspace: workspace)
      assert_equal attached_history, conversation_turns(attached_conversation)
      assert_equal bytes.bytes, rho_artifact_bytes(attachment)
      assert_equal settings, rho_api("/settings").fetch("settings")
      assert_equal provider, cmctl("provider", "show", PROVIDER)
      assert_equal model, configured_model
      assert_model_discovery
      use_upgraded_webui
    ensure
      FileUtils.rm_f(fixture) if fixture
    end

    def restore_installation_if_requested
      destination = ENV.fetch("E2E_STACK_RESTORE_DIR", "")
      return if destination.empty?

      assert_equal File.expand_path(destination), destination, "restore requires an absolute disposable directory"
      assert !File.exist?(destination) || (File.directory?(destination) && Dir.empty?(destination)), "restore must not overwrite an existing installation"
      FileUtils.mkdir_p(destination, mode: 0o700)
      destination = File.realpath(destination)
      refute_equal @stack, destination
      configuration = File.readlines(File.join(@stack, ".env")).reject { |line| line.start_with?("CYBROS_POSTGRES_IMAGE=", "CYBROS_UPDATER_IMAGE=") }
      work = File.join(@stack, "data", "rho", "work")
      contents = "Backup recovery fixture #{SecureRandom.hex(16)}\n"
      File.write(File.join(work, "backup-fixture.txt"), contents)
      File.symlink("backup-fixture.txt", File.join(work, "backup-fixture-link"))
      # A full offline restore restarts rho, whose HTTP listener precedes stored
      # credential adoption. Keep this tab's session, but resume its conversation
      # reads only after that existing readiness check succeeds. The Nexus-only
      # upgrade above keeps the live rho page throughout its separate restart.
      rho_page = @page.current_url
      @page.visit("about:blank")
      command_output("stop")
      backup = JSON.parse(command_output("backup"))
      assert_operator backup.fetch("size_bytes"), :>, 0
      assert JSON.parse(command_output("backups")).fetch("installations").any? { |row| row.fetch("id") == backup.fetch("id") }
      File.write(File.join(work, "backup-fixture.txt"), "Changed after the snapshot\n")
      restored = JSON.parse(command_output("restore", backup.fetch("id"), destination))
      assert_equal backup.fetch("id"), restored.fetch("id")
      assert_equal destination, restored.fetch("directory")
      refute restored.fetch("started"), "restoration leaves services stopped for inspection"
      restored_configuration = File.readlines(File.join(destination, ".env")).reject { |line| line.start_with?("CYBROS_POSTGRES_IMAGE=", "CYBROS_UPDATER_IMAGE=") }
      assert configuration == restored_configuration, "restoration preserves deployment configuration apart from frozen image references"
      assert_equal contents, File.read(File.join(destination, "data", "rho", "work", "backup-fixture.txt"))
      assert_equal "backup-fixture.txt", File.readlink(File.join(destination, "data", "rho", "work", "backup-fixture-link"))
      # The copied configuration retains its Compose project and ports. Remove
      # the old stopped containers before that project starts at a new path.
      command_output("compose", "down")
      command_output("manager", "down")
      @stack = File.realpath(destination)
      @command = File.join(@stack, "cybros")
      command_output("up")
      assert_equal @identity, assert_connected_status
      @page.visit(rho_page)
    end

    def conversation_turns(public_id, workspace: nil)
      query = { public_id: public_id }
      query[:workspace_public_id] = workspace if workspace
      rho_api("/conversations/turns?#{URI.encode_www_form(query)}").fetch("turns")
    end

    def completed_conversation_turns(public_id, workspace: nil)
      deadline = monotonic + WAIT
      loop do
        turns = conversation_turns(public_id, workspace: workspace)
        return turns if turns.any? && turns.all? { |turn| turn.fetch("status") == "completed" }

        assert_operator monotonic, :<, deadline, "the conversation did not finish before the upgrade snapshot"
        sleep 0.2
      end
    end

    def rho_api(path)
      @page.driver.browser.manage.timeouts.script_timeout = WAIT
      response = @page.evaluate_async_script(<<~JAVASCRIPT, path)
        const path = arguments[0], done = arguments[arguments.length - 1];
        import('/api.js').then(api => api.call(path)).then(
          data => done({ data }), error => done({ error: error.message }));
      JAVASCRIPT
      refute response.key?("error"), response["error"]
      response.fetch("data")
    end

    def rho_artifact_bytes(attachment)
      response = @page.evaluate_async_script(<<~JAVASCRIPT, attachment)
        const attachment = arguments[0], done = arguments[arguments.length - 1];
        import('/api.js').then(api => api.artifactBytes(attachment, null))
          .then(blob => blob.arrayBuffer()).then(
            bytes => done({ data: Array.from(new Uint8Array(bytes)) }),
            error => done({ error: error.message }));
      JAVASCRIPT
      refute response.key?("error"), response["error"]
      response.fetch("data")
    end

    def configured_model
      model = cmctl("models", "--available").fetch("models").find { |row| row.fetch("ref") == MODEL }
      refute_nil model, "the configured fake model must remain available"
      model
    end

    def upgrade_from_browser(release)
      before = %w[nexus jobs model_runner rho].to_h { |service| [service, service_snapshot(service)] }
      refute_equal release, before.fetch("nexus").fetch("version"), "start Nexus on an earlier fixture release"
      refute_equal release, before.fetch("rho").fetch("version"), "rho retains its earlier release in the mixed installation"
      nexus_window = @page.open_new_window
      @page.within_window(nexus_window) do
        @actor.visit("/admin/deployment")
        assert @page.has_selector?("h1", text: "System upgrade", wait: WAIT)
        assert @page.has_checked_field?("Back up the database before upgrading")
        @page.uncheck "Back up the database before upgrading" unless upgrade_backup?
        @page.click_button "Check for updates"
        assert @page.has_field?("candidate[release]", type: :hidden, with: release, visible: :all, wait: WAIT)
        assert @page.has_field?("Back up the database before upgrading", checked: upgrade_backup?),
          "the checked preflight must retain the chosen backup behavior"
        @page.within("section[aria-labelledby='available-release-heading']") do
          assert @page.has_selector?("p", text: release, exact_text: true)
        end
        @page.within("section[aria-labelledby='upgrade-checks-heading']") do
          assert @page.has_text?("Ready to upgrade", wait: WAIT)
          assert @page.has_css?("li[data-preflight-check]")
        end
        resize(1400, 1000)
        screenshot("nexus-upgrade-ready-desktop")
        resize(390, 844)
        screenshot("nexus-upgrade-ready-narrow")
        @page.click_button "Start upgrade"
        assert @page.has_current_path?(%r{/admin/deployment/upgrades/[0-9a-f-]+\z}, wait: WAIT)
        operation_id = URI(@page.current_url).path.split("/").last
        receipt = await_upgrade(operation_id, release)
        image = receipt.fetch("target").fetch("images").fetch(0)
        image_id = JSON.parse(run_command("docker", "image", "inspect", "--format", "{{json .Id}}", image.fetch("reference")))
        %w[nexus jobs model_runner].each do |service|
          after = service_snapshot(service)
          refute_equal before.fetch(service).fetch("id"), after.fetch("id"), "the Nexus upgrade must replace #{service}"
          refute_equal before.fetch(service).fetch("image"), after.fetch("image"), "#{service} must use the new Nexus image"
          assert_equal image_id, after.fetch("image"), "#{service} must run the selected Nexus image"
          assert_equal release, after.fetch("version")
        end
        assert_equal before.fetch("rho"), service_snapshot("rho"), "a Nexus upgrade must retain rho's container, image and start time"
        installed = JSON.parse(command_output("manager", "exec", "-T", "updater", "ruby", "/app/updater.rb", "status")).fetch("installed")
        assert_nil installed.fetch("release"), "independent component versions must not be reported as one installation release"
        assert_equal %w[nexus rho], installed.fetch("images").map { |entry| entry.fetch("name") }.sort
        versions = installed.fetch("images").to_h { |entry| [entry.fetch("name"), entry.fetch("version")] }
        assert_equal({ "nexus" => release, "rho" => before.fetch("rho").fetch("version") }, versions)
        assert @page.has_link?("Reload Nexus", wait: WAIT), "the page must reconnect to the saved successful upgrade"
        assert @page.has_text?("Upgrade complete")
        @page.within("section[aria-labelledby='database-backup-heading']") do
          assert @page.has_text?(upgrade_backup? ? "Available on the installation host" : "Skipped for this upgrade", wait: WAIT)
        end
        @page.execute_script("arguments[0].scrollIntoView({ block: 'center', behavior: 'instant' })",
          @page.find("section[aria-labelledby='database-backup-heading']"))
        screenshot("nexus-upgrade-complete-narrow")
        resize(1400, 1000)
        @page.execute_script("arguments[0].scrollIntoView({ block: 'center', behavior: 'instant' })",
          @page.find("section[aria-labelledby='database-backup-heading']"))
        screenshot("nexus-upgrade-complete-desktop")
        @page.click_link "Reload Nexus"
        assert @page.has_selector?("h1", text: "System upgrade", wait: WAIT)
        @page.within("section[aria-labelledby='installed-release-heading']") do
          assert @page.has_selector?("p", text: release, exact_text: true)
        end
      end
    ensure
      nexus_window&.close
    end

    def service_snapshot(service)
      id = command_output("compose", "ps", "--quiet", service).strip
      refute_empty id, "#{service} must be running"
      format = "{\"id\":{{json .Id}},\"image\":{{json .Image}},\"started_at\":{{json .State.StartedAt}},\"version\":{{json (index .Config.Labels \"org.opencontainers.image.version\")}}}"
      JSON.parse(run_command("docker", "inspect", "--format", format, id))
    end

    def await_upgrade(operation_id, release)
      deadline = monotonic + UPGRADE_WAIT
      loop do
        receipt = JSON.parse(command_output("upgrade-status", operation_id))
        assert_equal operation_id, receipt.fetch("id")
        assert_equal release, receipt.fetch("target").fetch("release")
        assert_equal upgrade_backup?, receipt.fetch("backup")
        assert_equal ["nexus"], receipt.fetch("target").fetch("images").map { |image| image.fetch("name") }
        case receipt.fetch("status")
        when "succeeded"
          assert_equal "completed", receipt.fetch("phase")
          backup = receipt.fetch("database_backup")
          if upgrade_backup?
            assert backup.fetch("available"), "the pre-migration database backup must remain available"
            assert_operator backup.fetch("size_bytes"), :>, 0
            refute_empty backup.fetch("created_at")
          else
            assert_nil backup, "an unchecked backup must not create a database export"
            backups = Dir.glob(File.join(@stack, "backups", "databases", "*.sql"))
            assert_empty backups, "the fresh disposable installation must have no SQL backup"
          end
          return receipt
        when "running"
          assert_operator monotonic, :<, deadline, "upgrade did not finish within #{UPGRADE_WAIT} seconds"
          sleep 1
        else
          flunk "upgrade #{receipt.fetch("status")} during #{receipt.fetch("phase")}: #{receipt["error"]}"
        end
      end
    end

    def upgrade_backup? = ENV.fetch("E2E_STACK_UPGRADE_BACKUP", "true") != "false"

    def use_upgraded_webui
      resize(1400, 1000)
      @page.click_button "New conversation"
      assert @page.has_css?("#model option:checked[value='#{MODEL}']:not([disabled])", visible: :all, wait: WAIT)
      @page.fill_in "Message", with: "!mock reply=Upgrade+preserved+configuration. -- Confirm the upgraded installation works."
      @page.click_button "Send"
      assert @page.has_text?("Mock: Upgrade preserved configuration.", wait: WAIT)
      screenshot("rho-after-upgrade-desktop")
      resize(390, 844)
      screenshot("rho-after-upgrade-narrow")
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
      if @page.has_css?(".drawer .drawer-side", visible: :all, wait: 0)
        opacity = width < 1024 ? "0" : "1"
        assert @page.find(".drawer .drawer-side", visible: :all).matches_style?(opacity: opacity)
      end
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
        Tempfile.create("cybros-stack-e2e-stderr") do |errors|
          status = E2E::ProcessRunner.run(executable, *arguments, chdir: @stack,
            stdin: stdin, out: file, err: errors, timeout: WAIT)
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
