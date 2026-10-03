require "test_helper"
require "cgi/escape"
require "fileutils"
require "securerandom"
require "tmpdir"
require "uri"
require "support/actor_provisioning"
require "support/ceremony"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

# The shipped page drives the same daemon a terminal uses. Pairing, provider
# setup and long-history preparation use public APIs; the journeys exercise
# ordinary browser interactions against the real kernel and fake provider.
class RhoWebuiTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  WAIT = E2E::RhoDaemon::WATCH_TIMEOUT
  MARKDOWN = <<~TEXT.freeze
    A small report.

    # Browser report

    **Ready** and [reference](https://example.com/).

    ```ruby
    puts "hello"
    ```

    <script>document.body.dataset.injected = "yes"</script>
    [unsafe](javascript:alert%281%29)
  TEXT
  SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="80" height="50"><rect width="80" height="50" fill="#278b73"/></svg>'.freeze

  def setup
    @base_url = E2E.base_url
    @people = E2E::ActorProvisioning.world(@base_url)
    @steward = @people.rho_steward
    @ceremony_actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
    @root = Dir.mktmpdir("rho-webui-e2e")
    @project = File.join(@root, "project")
    @agent_project = File.join(@root, "agent-project")
    FileUtils.mkdir_p([@project, @agent_project])
    @artifacts = File.expand_path("../artifacts/rho_webui/#{name}-#{Process.pid}", __dir__)
    @console_logs = []
    configure_provider
    E2E.hosts.start
  end

  def teardown
    if @browser
      @console_logs.concat(@browser.console_logs)
      FileUtils.mkdir_p(@artifacts)
      File.write(File.join(@artifacts, "browser-console.json"),
        E2E::SecretHygiene.redact(JSON.pretty_generate(@console_logs)))
      E2E::SecretHygiene.save_screenshot(@browser, File.join(@artifacts, "failure.png")) unless passed?
      unless passed?
        File.write(File.join(@artifacts, "page.html"), E2E::SecretHygiene.redact(@page.html))
        resources = @page.evaluate_script('performance.getEntriesByType("resource").map(({name, duration, responseStatus}) => ({name, duration, responseStatus}))')
        File.write(File.join(@artifacts, "browser-requests.json"), E2E::SecretHygiene.redact(JSON.pretty_generate(resources)))
      end
    end
    capture_failure_logs unless passed?
  rescue StandardError => error
    warn "Could not capture rho WebUI diagnostics: #{error.class}: #{E2E::SecretHygiene.redact(error.message)}"
  ensure
    @browser&.close
    @runner&.stop
    @daemon&.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_an_unconnected_console_explains_setup_and_recovers_after_connection
    @daemon = boot_daemon("agent", mode: "full", project: @project, connect: false)
    visit_console(width: 1400, height: 1000)
    assert @page.has_css?("[role=alert]", text: "rho is not connected to Nexus.")
    assert @page.has_text?("./cybros connect")
    assert @page.has_text?("./cybros setup")
    assert @page.has_select?("Model", selected: "Models unavailable")
    assert @page.has_select?("Runner", selected: "Runners unavailable")
    assert @page.has_button?("Send", disabled: true)
    screenshot("disconnected-desktop")
    @page.current_window.resize_to(390, 844)
    @page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 390, height: 844, deviceScaleFactor: 1, mobile: false)
    @page.click_button "Refresh"
    assert @page.has_css?("[role=alert]", text: "rho is not connected to Nexus.")
    screenshot("disconnected-narrow")

    E2E::Ceremony.confirm(actor: @ceremony_actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
    @daemon.await("rho never adopted its workspace") { @daemon.status.dig("workspace", "state") == "adopted" }
    @daemon.await_announced(address: "runner")
    @runner_id = @daemon.status.dig("identity", "runner_executor_public_id")
    @page.click_button "Refresh"
    assert @page.has_css?("#model option[value='#{MODEL}']", visible: :all, wait: WAIT)
    refute @page.has_css?("[role=alert]", text: "rho is not connected to Nexus.")
    new_conversation
    send_message(reply_prompt("Connected after setup."))
    assert @page.has_text?("Mock: Connected after setup.", wait: WAIT)
  end

  def test_a_desktop_conversation_keeps_its_messages_and_lifecycle_after_reload
    boot_console(mode: "full", width: 1400, height: 1000)
    new_conversation
    assert_includes @page.find_field("Model").all("option").map(&:value), MODEL
    assert_includes @page.find_field("Runner").all("option").map(&:value), @runner_id
    refute_includes @page.find_field("Model").all("option").map(&:value), "e2e-key/mock-keyed-text"

    send_message(reply_prompt(MARKDOWN).sub("!mock ", "!mock stream_chunk_delay=0.2 "))
    assert @page.has_text?("Mock: A small report.", wait: WAIT)
    draft = reply_prompt("The second answer remembers this conversation.")
    @page.fill_in "Message", with: draft
    composer = @page.find_field("Message").native
    assert @page.has_css?("article[data-turn-id] h2", text: "Browser report", wait: WAIT)
    conversation = conversation_id
    within_assistant_report do
      assert @page.has_css?("strong", text: "Ready")
      assert @page.has_css?("pre code", text: 'puts "hello"')
      assert @page.has_link?("reference", href: "https://example.com/")
      assert @page.has_text?('<script>document.body.dataset.injected = "yes"</script>')
      refute @page.has_css?("script", visible: :all)
      refute @page.has_css?('a[href^="javascript:"]', visible: :all)
    end
    assert_nil @page.evaluate_script("document.body.dataset.injected")
    assert_equal composer, @page.find_field("Message").native, "streamed output keeps the same composer element"
    assert_equal "message", @page.evaluate_script("document.activeElement.id"), "streamed output preserves focus"
    assert @page.has_field?("Message", with: draft)

    send_after_network_failure(draft)
    assert @page.has_text?("Mock: The second answer remembers this conversation.", wait: WAIT)
    assert_equal conversation, conversation_id
    @page.refresh
    assert @page.has_css?("article[data-turn-id] h2", text: "Browser report", wait: WAIT)
    assert @page.has_text?("Mock: The second answer remembers this conversation.")
    assert @page.has_css?("#model option:checked[value='#{MODEL}']", visible: :all), "initial history selection survives model discovery"
    assert_equal 4, @page.all("article[data-turn-id]").length, "two user messages and two durable answers"

    @page.click_button "Rename"
    @page.fill_in "Conversation title", with: "Browser lifecycle"
    @page.click_button "Save title"
    assert @page.has_css?("main h2", text: "Browser lifecycle")
    screenshot("desktop-conversation")
    @page.click_button "Archive"
    show_conversations
    @page.check "Archived conversations"
    @page.click_button "Browser lifecycle", exact: false
    assert @page.has_button?("Restore")
    assert @page.has_text?("Mock: The second answer remembers this conversation.")
    @page.click_button "Restore"
    @page.refresh
    assert @page.has_css?("main h2", text: "Browser lifecycle", wait: WAIT)
    assert @page.has_text?("Mock: The second answer remembers this conversation.")
    assert @page.has_button?("Archive")
    assert_equal conversation, conversation_id
    assert_long_history(conversation)
    assert_clean_console
  end

  def test_a_narrow_console_answers_approvals_and_stops_work_on_a_separate_runner
    boot_console(mode: "agent", width: 390, height: 844)
    new_conversation
    send_message(tool_prompt("ask", { "prompt" => "Which database?" }, "Question answered."))
    assert @page.has_text?("Which database?", wait: WAIT)
    assert @page.has_field?("Answer", wait: WAIT)
    @page.refresh
    assert @page.has_field?("Answer", wait: WAIT), "a pending question survives page reload"
    draft = "A draft written while waiting for the answer."
    @page.fill_in "Message", with: draft
    @page.fill_in "Answer", with: "Postgres"
    screenshot("narrow-question")
    @page.click_button "Send answer"
    assert @page.has_text?("Mock: Question answered.", wait: WAIT)
    assert @page.has_field?("Message", with: draft), "answering does not discard the conversation draft"

    new_conversation
    command = "printf '%s' '#{SVG}' > preview.svg; printf preview.svg"
    send_message(tool_prompt("bash", { "command" => command }, "The preview is ready: preview.svg"))
    assert @page.has_button?("Approve", wait: WAIT)
    refute File.exist?(File.join(@project, "preview.svg")), "the held command has not executed"
    screenshot("narrow-approval")
    @page.click_button "Approve"
    assert @page.has_text?("Mock: The preview is ready: preview.svg", wait: WAIT)
    assert_equal SVG, File.read(File.join(@project, "preview.svg"))
    refute File.exist?(File.join(@agent_project, "preview.svg")), "the separate runner owns the working directory"
    @page.click_button "Open artifact preview.svg", match: :first
    assert @page.has_css?('img[src^="blob:"]', wait: WAIT)
    @daemon.await("the remote artifact image did not decode") do
      @page.evaluate_script('Array.from(document.images).some((image) => image.src.startsWith("blob:") && image.complete && image.naturalWidth === 80)')
    end
    screenshot("narrow-remote-artifact")

    new_conversation
    send_message(tool_prompt("bash", { "command" => "printf refused > denied.txt" }, "The denial was received."))
    assert @page.has_button?("Deny", wait: WAIT)
    @page.click_button "Deny"
    assert @page.has_text?("Mock: The denial was received.", wait: WAIT)
    refute File.exist?(File.join(@project, "denied.txt")), "denial never executes the command"

    new_conversation(approval: "bypass")
    send_message(tool_prompt("bash", { "command" => "printf running > running.txt; sleep #{3 * E2E::RhoDaemon::HOLD_SECONDS}" },
      "This answer must not finish."))
    @daemon.await("the remote command never started") { File.file?(File.join(@project, "running.txt")) }
    @page.click_button "Pause", exact: true
    assert @page.has_button?("Resume", wait: WAIT)
    @page.click_button "Resume", exact: true
    assert @page.has_button?("Pause", wait: WAIT)
    @page.click_button "Stop"
    assert @page.has_text?(/canceled|stopped/i, wait: WAIT)
    refute @page.has_text?("Mock: This answer must not finish.")
    send_message(reply_prompt("Recovered after stop."))
    assert @page.has_text?("Mock: Recovered after stop.", wait: WAIT)
    screenshot("narrow-stopped")
    assert_clean_console
  end

  private

    def configure_provider
      grant = CybrosAgent::Sessions.new(base_url: @base_url)
        .create(email: @people.owner_email, password: @people.owner_password)
      operator = CybrosAgent::PlatformClient.new(base_url: @base_url, credential: grant.token)
      lane = operator.model_providers.provider("dev")
      lane.enable(expected_lock_version: lane.fetch.lock_version)
    ensure
      operator&.session&.revoke
    end

    def boot_console(mode:, width:, height:)
      @daemon = boot_daemon("agent", mode: mode, project: mode == "full" ? @project : @agent_project)
      @workspace_id = @daemon.await("rho never adopted its workspace") do
        workspace = @daemon.status.fetch("workspace")
        workspace.fetch("public_id") if workspace.fetch("state") == "adopted"
      end
      if mode == "agent"
        @runner = boot_daemon("runner", mode: "runner", project: @project)
        @runner.await_announced(address: "runner")
        @runner_id = @runner.status.dig("identity", "runner_executor_public_id")
      else
        @daemon.await_announced(address: "runner")
        @runner_id = @daemon.status.dig("identity", "runner_executor_public_id")
      end
      refute_nil @runner_id
      visit_console(width: width, height: height)
      assert @page.has_css?("#model option[value='#{MODEL}']", visible: :all, wait: WAIT)
      show_conversations
      assert @page.has_button?("New conversation", wait: WAIT)
    end

    def visit_console(width:, height:)
      output, status = @daemon.cli("console")
      assert_predicate status, :success?, E2E::SecretHygiene.redact(output)
      url = output[/^console:\s+(\S+)/, 1]
      refute_nil url
      E2E::SecretHygiene.register(URI(url).fragment.delete_prefix("code="))
      @browser = E2E::BrowserActor.new(url)
      @page = @browser.page
      @page.current_window.resize_to(width, height)
      @page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: width, height: height, deviceScaleFactor: 1, mobile: false)
      @browser.visit(url)
      assert @page.has_field?("Message", wait: WAIT)
      assert_equal width, @page.evaluate_script("window.innerWidth")
      assert_nil URI(@page.current_url).fragment, "the page spends and removes the console code"
    end

    def boot_daemon(name, mode:, project:, connect: true)
      home = File.join(@root, name)
      FileUtils.mkdir_p(home)
      File.write(File.join(home, "settings.json"), JSON.generate("extensions" => [], "extension_paths" => []))
      daemon = E2E::RhoDaemon.new(base_url: @base_url, home: home, tools_root: project, env: { "RHO_MODE" => mode })
      daemon.start
      E2E::Ceremony.confirm(actor: @ceremony_actor, started: daemon.start_ceremony, status: -> { daemon.status }) if connect
      daemon
    rescue StandardError
      daemon&.stop
      raise
    end

    def new_conversation(approval: "ask")
      show_conversations
      @page.click_button "New conversation"
      @page.find_field("Model").find("option[value='#{MODEL}']", visible: :all, wait: WAIT).select_option
      @page.find_field("Runner").find("option[value='#{@runner_id}']", visible: :all, wait: WAIT).select_option
      @page.fill_in "Working directory", with: @project
      @page.find_field("Approval mode").find("option[value='#{approval}']").select_option
    end

    def show_conversations
      unless @page.has_button?("New conversation", wait: 0)
        @page.click_button "Conversations", exact: true
      end
    end

    def send_message(text)
      @page.fill_in "Message", with: text
      assert @page.has_field?("Message", with: text)
      @page.click_button "Send", exact: true
    end

    def reply_prompt(text)
      "!mock reply=#{CGI.escape(text)} -- Give the requested report."
    end

    def send_after_network_failure(text)
      @console_logs.concat(@browser.console_logs)
      @page.driver.browser.network_conditions = { offline: true }
      send_message(text)
      assert @page.has_text?(/failed to fetch|network.*error/i)
      assert @page.has_field?("Message", with: text), "a failed request retains the text"
      offline_logs = @browser.console_logs
      offline_logs.each do |entry|
        next unless entry.fetch("level") == "SEVERE"

        assert_match(/ERR_INTERNET_DISCONNECTED/, entry.fetch("message"))
        entry["expected_network_failure"] = true
      end
      @console_logs.concat(offline_logs)
      @page.driver.browser.delete_network_conditions
      @page.click_button "Refresh"
      assert @page.has_field?("Message", with: text)
      @page.click_button "Send", exact: true
    ensure
      @page.driver.browser.delete_network_conditions
    end

    def tool_prompt(name, arguments, reply)
      "!mock tool_call=#{name} tool_args=#{CGI.escape(JSON.generate(arguments))} reply=#{CGI.escape(reply)} -- Do the requested work."
    end

    def conversation_id
      URI.decode_www_form(URI(@page.current_url).query.to_s).to_h.fetch("conversation")
    end

    def assert_long_history(conversation)
      client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
      chat = client.workspace(@workspace_id).conversations.conversation(conversation)
      # Ordinary message inputs make durable history without forty model calls.
      # The browser still owns reopening, paging and displaying that history.
      44.times do |index|
        chat.inputs.create(kind: "message", text: "History message #{index + 1}", idempotency_key: SecureRandom.uuid)
      end
      @page.refresh
      assert @page.has_text?("History message 44", wait: WAIT)
      refute @page.has_css?("article[data-turn-id] h2", text: "Browser report", wait: 0)
      @page.click_button "Load more messages"
      assert @page.has_css?("article[data-turn-id] h2", text: "Browser report", wait: WAIT)
      assert @page.has_text?("History message 44")
      assert_equal 48, @page.all("article[data-turn-id]").length
    end

    def within_assistant_report(&block)
      @page.within("article[data-turn-id]", text: "Browser report", &block)
    end

    def screenshot(name)
      assert @page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
        "the page must fit the viewport without horizontal scrolling"
      E2E::SecretHygiene.save_screenshot(@browser, File.join(@artifacts, "#{name}.png"))
    end

    def assert_clean_console
      @console_logs.concat(@browser.console_logs)
      errors = @console_logs.select { |entry| entry.fetch("level") == "SEVERE" && !entry["expected_network_failure"] }
      assert_empty errors, E2E::SecretHygiene.redact(JSON.pretty_generate(errors))
    end

    def capture_failure_logs
      FileUtils.mkdir_p(@artifacts)
      [@daemon, @runner].compact.each_with_index do |daemon, index|
        [daemon.log_path, daemon.rho_log_path].each do |path|
          next unless File.file?(path)

          File.write(File.join(@artifacts, "#{index}-#{File.basename(path)}"), E2E::SecretHygiene.redact(File.read(path)))
        end
      end
      rails_log = File.join(E2E.handle.fetch("log_dir"), "rails.log")
      if File.file?(rails_log)
        File.write(File.join(@artifacts, "rails.log"), E2E::SecretHygiene.redact(File.read(rails_log)))
      end
      warn "rho WebUI failure artifacts: #{@artifacts}"
    end
end
