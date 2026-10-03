require "test_helper"
require "securerandom"
require "tempfile"
require "support/ceremony"
require "support/process_registry"
require "support/secret_hygiene"

# Explicitly targets a fresh, disposable stack installed by install/stack.
# It never boots Nexus, creates database rows directly, calls a model, or
# tears down the caller's stack. Run this file directly with both opt-ins.
class StackInstallationTest < Minitest::Test
  WAIT = 120

  def setup
    skip "stack_installation requires E2E_STACK_DIR and E2E_BASE_URL" if
      ENV.fetch("E2E_STACK_DIR", "").empty? || ENV.fetch("E2E_BASE_URL", "").empty?

    @stack = File.expand_path(ENV.fetch("E2E_STACK_DIR"))
    @base_url = ENV.fetch("E2E_BASE_URL")
    @command = File.join(@stack, "cybros")
    assert File.executable?(@command), "E2E_STACK_DIR must contain the installed cybros command"
    @setup_secret = secret("NEXUS_SETUP_SECRET")
    @passphrase = secret("RHO_ACCESS_PASSPHRASE")
    @password = E2E::SecretHygiene.register(SecureRandom.hex(24))
    @artifacts = File.expand_path("../artifacts/stack_installation/#{Process.pid}", __dir__)
    @output = +""
    @actor = E2E::BrowserActor.new(@base_url)
    @page = @actor.page
  end

  def teardown
    if @actor
      FileUtils.mkdir_p(@artifacts)
      File.write(File.join(@artifacts, "connect.log"), E2E::SecretHygiene.redact(@output))
      File.write(File.join(@artifacts, "browser-console.json"),
        E2E::SecretHygiene.redact(JSON.pretty_generate(@actor.console_logs)))
      E2E::SecretHygiene.save_screenshot(@actor, File.join(@artifacts, "failure.png")) unless passed?
    end
  rescue StandardError => error
    warn "Could not capture stack installation diagnostics: #{error.class}: #{E2E::SecretHygiene.redact(error.message)}"
  ensure
    E2E::ProcessRegistry.terminate(@connect_pid) if @connect_pid
    @reader&.close
    @actor&.close
  end

  def test_first_account_pairs_full_rho_and_unlocks_the_shipped_webui
    found_installation
    configure_model
    connect_rho
    assert_connected_status
    assert_model_discovery
    unlock_webui
  end

  private

    def found_installation
      @actor.visit("/setup")
      assert @page.has_field?("Installation name"), "this journey requires a fresh, uninitialized stack"
      E2E::SecretHygiene.during_reveal do
        @page.fill_in "Installation name", with: "Stack installation E2E"
        @page.fill_in "Your name", with: "Stack E2E Owner"
        @page.fill_in "Email", with: "owner@stack-installation.invalid"
        @page.fill_in "Password", with: @password
        @page.fill_in "Repeat password", with: @password
        @page.fill_in "Setup secret", with: @setup_secret
        @page.click_button "Create installation"
        assert @page.has_selector?("h1", text: "Dashboard", wait: WAIT)
      end
    end

    def connect_rho
      @reader, writer = IO.pipe
      @connect_pid = E2E::ProcessRegistry.spawn(@command, "connect",
        chdir: @stack, in: File::NULL, out: writer, err: writer, pgroup: true)
      writer.close
      deadline = monotonic + WAIT
      until (url = @output[/^Or open directly: (\S+)\r?$/, 1])
        read_connect_output(deadline)
      end
      uri = URI(url)
      code = URI.decode_www_form(uri.query.to_s).to_h.fetch("user_code")
      E2E::SecretHygiene.register(code)
      # Full mode uses one combined approval for its Agent and Runner.
      # The shared browser helper asserts that consequence on the page.
      E2E::SecretHygiene.during_reveal do
        E2E::Ceremony.confirm_agent_page(@actor,
          { "verification_uri_complete" => url, "user_code" => code }, runner_sentence: true)
        @actor.visit("/")
        assert @page.has_text?("Dashboard")
      end
      until (finished = Process.wait2(@connect_pid, Process::WNOHANG))
        assert_operator monotonic, :<, deadline, "cybros connect did not finish after browser approval"
        sleep 0.1
      end
      E2E::ProcessRegistry.unregister(@connect_pid)
      @connect_pid = nil
      @output << @reader.read
      @reader.close
      @reader = nil
      assert_predicate finished.last, :success?, E2E::SecretHygiene.redact(@output)
      assert_match(/^Connected as \S+ — agent \S+, runner \S+ \(private to you\)\./,
        E2E::SecretHygiene.redact(@output))
    ensure
      writer&.close unless writer&.closed?
    end

    def read_connect_output(deadline)
      remaining = deadline - monotonic
      assert_operator remaining, :>, 0, "cybros connect did not print a verification URL"
      assert IO.select([@reader], nil, nil, remaining), "cybros connect did not print a verification URL"
      @output << @reader.readpartial(4096)
    rescue EOFError
      flunk "cybros connect ended before requesting approval: #{E2E::SecretHygiene.redact(@output)}"
    end

    def configure_model
      login = cmctl("login", "--url", "http://nexus", "--email", "owner@stack-installation.invalid",
        "--password-stdin", stdin: "#{@password}\n")
      assert login.fetch("connected")
      assert_equal "human", cmctl("status").dig("member", "kind")
      assert_equal "USD", cmctl("account", "cost-unit", "USD").dig("account", "cost_unit")
      lane = cmctl("providers").fetch("model_providers").find { |row| row.fetch("id") == "openai_api" }
      refute_nil lane, "the shipped catalog includes the OpenAI API lane"
      refute lane.fetch("configured"), "this journey requires a fresh provider configuration"
      key = E2E::SecretHygiene.register("e2e-no-provider-io-#{SecureRandom.hex(16)}")
      assert cmctl("provider", "key", "set", "openai_api", "--stdin", stdin: "#{key}\n")
        .fetch("model_provider").fetch("configured")
      assert cmctl("provider", "enable", "openai_api").fetch("model_provider").fetch("enabled")
      @model_refs = cmctl("models", "--available").fetch("models")
        .select { |model| model.fetch("ref").start_with?("openai_api/") }.map { |model| model.fetch("ref") }
      refute_empty @model_refs, "key installation and enablement make catalog models discoverable without provider IO"
    end

    def assert_model_discovery
      models = JSON.parse(command_output("rho", "models", "--json")).fetch("models")
      assert_empty @model_refs - models.map { |model| model.fetch("ref") }
      # The synthetic credential proves storage and discovery only. Leave
      # this installation unconfigured for inference after the assertion.
      refute cmctl("provider", "key", "clear", "openai_api").fetch("model_provider").fetch("configured")
      refute cmctl("provider", "disable", "openai_api").fetch("model_provider").fetch("enabled")
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
          break
        end
        assert_operator monotonic, :<, deadline, E2E::SecretHygiene.redact(output)
        sleep 0.2
      end
    end

    def unlock_webui
      url = setting("CYBROS_RHO_URL")
      @actor.visit(url)
      assert @page.has_field?("Access passphrase", wait: WAIT)
      E2E::SecretHygiene.during_reveal do
        @page.fill_in "Access passphrase", with: @passphrase
        @page.click_button "Unlock"
        assert @page.has_field?("Message", wait: WAIT)
        assert @page.has_no_field?("Access passphrase")
      end
      assert @page.has_text?("Connected", wait: WAIT)
      assert @page.has_button?("New conversation")
      E2E::SecretHygiene.save_screenshot(@actor, File.join(@artifacts, "rho-unlocked.png"))
      @page.refresh
      assert @page.has_field?("Message", wait: WAIT), "the browser session survives a page reload"
    end

    def cmctl(*arguments, stdin: nil)
      JSON.parse(command_output("cmctl", *arguments, stdin: stdin))
    end

    def command_output(*arguments, stdin: nil)
      Tempfile.create("cybros-stack-e2e") do |file|
        status = E2E::ProcessRunner.run(@command, *arguments, chdir: @stack,
          stdin: stdin, out: file, err: file, timeout: WAIT)
        file.rewind
        output = file.read
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
