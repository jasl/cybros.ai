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
require "support/web_fixture"

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
    dispose_daemon(@runner)
    dispose_daemon(@daemon)
    @web_fixture&.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_device_login_connects_an_unconnected_console_without_a_separate_pairing_screen
    @daemon = boot_daemon("agent", mode: "full", project: @project, connect: false)
    visit_console(width: 1400, height: 1000, authenticate: false)
    assert @page.has_button?("Connect to Nexus")
    assert @page.has_button?("Use a device code")
    assert @page.has_no_field?("Password")
    assert @page.has_no_field?("Message")
    screenshot("login-desktop")
    resize_console(width: 390, height: 844)
    assert @page.has_button?("Connect to Nexus")
    screenshot("login-narrow")

    E2E::DeviceAuthorizationBudget.consume
    @page.click_button "Use a device code"
    assert @page.has_link?("Open Nexus to approve", wait: WAIT)
    connection_window = @page.window_opened_by { @page.click_link "Open Nexus to approve" }
    @page.within_window(connection_window) do
      @page.fill_in "Email", with: @steward.email
      @page.fill_in "Password", with: @steward.password
      E2E::SessionSignInBudget.consume
      @page.click_button "Sign in"
      @page.click_button "Continue"
      assert @page.has_text?("Also runs as a runner on that machine")
      @page.click_button "Connect", exact: true
      assert @page.has_text?(/Connection ready|This connection is complete/)
    end
    connection_window.close
    assert @page.has_field?("Message", wait: WAIT)
    @page.click_button "Settings" unless @page.has_css?("dialog.settings-dialog[open]", wait: 0)
    @page.within('section[aria-label="Nexus account"]') do
      assert @page.has_text?(@steward.display_name, wait: WAIT)
    end
    @daemon.await("rho never adopted its workspace") { @daemon.status.dig("workspace", "state") == "adopted" }
    @daemon.await_announced(address: "runner")
    @runner_id = @daemon.status.dig("identity", "runner_executor_public_id")
    configure_console_model
    assert @page.has_css?("#model option[value='#{MODEL}']", visible: :all, wait: WAIT)
    refute @page.has_css?("[role=alert]:not([hidden])")
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

    send_message(reply_prompt(MARKDOWN, usage: "17:5").sub("!mock ", "!mock stream_chunk_delay=0.2 "))
    assert @page.has_text?("Mock: A small report.", wait: WAIT)
    assert @page.has_css?(".conversation-usage > summary", text: "Usage · 22 tokens", wait: WAIT)
    draft = reply_prompt("The second answer remembers this conversation.", usage: "31:9")
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
    assert_conversation_usage(requests: 2, input: 48, output: 14, context: 40)
    @page.refresh
    assert @page.has_css?("article[data-turn-id] h2", text: "Browser report", wait: WAIT)
    assert @page.has_text?("Mock: The second answer remembers this conversation.")
    assert @page.has_css?("#model option:checked[value='#{MODEL}']", visible: :all), "initial history selection survives model discovery"
    assert @page.has_css?("#model option:checked[value='#{MODEL}']:not([disabled])", visible: :all, wait: WAIT),
      "the saved conversation model remains usable after model discovery"
    assert_equal 4, @page.all("article[data-turn-id]").length, "two user messages and two durable answers"
    assert_conversation_usage(requests: 2, input: 48, output: 14, context: 40)
    screenshot("desktop-usage")
    resize_console(width: 390, height: 844)
    assert_conversation_usage(requests: 2, input: 48, output: 14, context: 40)
    assert_expanded_usage_keeps_composer_in_view
    screenshot("narrow-usage")
    resize_console(width: 1400, height: 1000)

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
    assert_conversation_usage(requests: 2, input: 48, output: 14, context: 40)
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

    client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    workspace = client.workspace(@workspace_id)
    answered = workspace.conversation(conversation_id).turns.list.items.last
    declared = workspace.runs.run(answered.active_variant.run_public_id).task("r1").tool_definitions
    entry = declared.find do |tool|
      tool.dig("route", "runner_executor_public_id") == @runner_id && tool.dig("route", "tool_name") == "bash"
    end
    refute_nil entry, "the accepted turn declares the separate Runner's bash callable"
    bash = entry.fetch("function").fetch("name")

    new_conversation
    command = "printf '%s' '#{SVG}' > preview.svg; printf preview.svg"
    send_message(tool_prompt(bash, { "command" => command }, "The preview is ready: preview.svg"))
    assert @page.has_button?("Approve", wait: WAIT)
    refute @page.has_button?("Allow this site until restart", wait: 0)
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
    send_message(tool_prompt(bash, { "command" => "printf refused > denied.txt" }, "The denial was received."))
    assert @page.has_button?("Deny", wait: WAIT)
    @page.click_button "Deny"
    assert @page.has_text?("Mock: The denial was received.", wait: WAIT)
    refute File.exist?(File.join(@project, "denied.txt")), "denial never executes the command"

    new_conversation(approval: "bypass")
    send_message(tool_prompt(bash, { "command" => "printf running > running.txt; sleep #{3 * E2E::RhoDaemon::HOLD_SECONDS}" },
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

  def test_a_site_approval_allows_future_fetches_from_the_same_written_origin
    @web_fixture = E2E::WebFixture.new.start
    boot_console(mode: "full", width: 1400, height: 1000,
      settings: { "plugins" => { "rho.web_tools" => {
        "configuration" => { "allow_private_network" => true },
      } } })
    new_conversation
    first_url = "#{@web_fixture.site}/page.html"
    send_message(tool_prompt("web_fetch", { "url" => first_url }, "The first page was fetched."))
    assert @page.has_button?("Allow this site until restart", wait: WAIT)
    assert @page.has_css?(".ask-card pre", text: first_url)
    assert @page.has_text?("exact scheme, host and written port")
    assert @page.has_text?("Initial URLs must begin")
    assert @page.has_text?("followed by /")
    assert @page.has_text?("No subdomains, www variants, or added/removed default ports.")
    assert @page.has_text?("Redirects keep web_fetch’s same-site policy, including www.")
    assert_empty @web_fixture.requests, "the held fetch has not reached the website"
    first_conversation = conversation_id
    screenshot("site-approval-desktop")
    resize_console(width: 390, height: 844)
    assert @page.has_button?("Allow this site until restart")
    screenshot("site-approval-narrow")
    @page.click_button "Allow this site until restart"
    assert @page.has_text?("Mock: The first page was fetched.", wait: WAIT)
    assert_equal [first_url], @web_fixture.requests

    new_conversation
    next_url = "#{@web_fixture.site}/notes.txt"
    send_message(tool_prompt("web_fetch", { "url" => next_url }, "Another page from this site was fetched."))
    assert @page.has_text?("Mock: Another page from this site was fetched.", wait: WAIT)
    refute_equal first_conversation, conversation_id
    assert_equal [first_url, next_url], @web_fixture.requests,
      "a fresh conversation reuses the site permission without another approval"
    refute @page.has_button?("Allow this site until restart", wait: 0)
    screenshot("site-approved-narrow")
    assert_clean_console
  end

  def test_send_now_reads_a_steer_while_the_original_tool_keeps_running
    boot_console(mode: "full", width: 1400, height: 1000)
    new_conversation(approval: "bypass")
    assert_equal "steer", @page.find_field("Send behavior").value
    marker = SecureRandom.hex(4)
    command = "until test -f release; do sleep 0.1; done; printf 'long-%s\\n' complete-#{marker}"
    send_message(tool_prompt("bash", { "command" => command, "timeout" => 180 }, "The original work finished."))
    assert @page.has_current_path?(/conversation=/, url: true, wait: WAIT)
    client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    workspace = client.workspace(@workspace_id)
    chat = workspace.conversation(conversation_id)
    turn = @daemon.await("the conversation never started its original turn") do
      chat.turns.list.items.find { |row| row.kind == "direct_reply" && row.active_variant&.run_public_id }
    end
    run_id = turn.active_variant.run_public_id
    run = workspace.run(run_id)
    original = @daemon.await("the runner never claimed the long shell") do
      run.fetch.tasks.find { |task| task.tool_name == "bash" && task.claimed_by }
    end
    continuation = run.fetch.deliverable_task_key
    ordinary = reply_prompt("The correction was read while the shell runs.")
    send_message(ordinary)
    assert @page.has_text?("Additional instruction waiting to be read", wait: WAIT)
    held = chat.inputs.list.items.find { |input| input.text == ordinary }
    assert_equal ["steering", "steer"], [held.state, held.delivery_mode]
    assert_equal "waiting", run.fetch.tasks.find { |task| task.key == continuation }.status
    refute run.fetch.tasks.any? { |task| task.key.start_with?("steer") }
    assert @page.has_field?("Message", with: "")
    screenshot("steer-waiting-desktop")
    resize_console(width: 320, height: 844)
    assert @page.has_button?("Send now", disabled: false)
    screenshot("steer-waiting-narrow")
    @page.click_button "Send now"
    @daemon.await("Send now never produced an immediate model response") do
      run.fetch.tasks.any? { |task| task.key == "steer1" && task.status == "completed" }
    end
    first_request = workspace.run_task(run_public_id: run_id, task_key: "steer1").request.entries.to_json
    assert_includes first_request, ordinary
    assert_includes first_request, "still pending"
    refute chat.inputs.list.items.any? { |input| input.public_id == held.public_id }
    live = run.fetch.tasks.find { |task| task.key == original.key }
    assert_equal ["dispatched", original.started_at, original.claimed_by, original.lifetime],
      [live.status, live.started_at, live.claimed_by, live.lifetime]
    assert_nil live.completed_at
    assert_equal "running", run.fetch.status
    assert_equal turn.public_id, chat.turns.list.items.find { |row| row.active_variant&.run_public_id == run_id }.public_id

    @page.select "Queue after current reply", from: "Send behavior"
    queued = reply_prompt("The queued next turn finished.")
    send_message(queued)
    assert @page.has_text?("Message queued", wait: WAIT)
    assert_equal "queue", chat.inputs.list.items.find { |input| input.text == queued }.delivery_mode
    immediate = reply_prompt("The keyboard correction was read immediately.")
    @page.fill_in "Message", with: immediate
    assert @page.has_button?("Send now", disabled: false, wait: WAIT)
    @page.find_field("Message").send_keys([:control, :enter])
    @daemon.await("Control Enter never produced a second immediate response") do
      run.fetch.tasks.any? { |task| task.key == "steer2" && task.status == "completed" }
    end
    assert_includes workspace.run_task(run_public_id: run_id, task_key: "steer2").request.entries.to_json, immediate
    assert_equal [queued], chat.inputs.list.items.map(&:text)
    assert_equal "dispatched", run.fetch.tasks.find { |task| task.key == original.key }.status
    assert_equal continuation, run.fetch.deliverable_task_key
    released = @daemon.control(:post, "/runs/call_tool", body: {
      "runner_executor_public_id" => @runner_id, "tool" => "bash",
      "input" => { "command" => "touch #{File.join(@project, "release")}" },
    })
    assert_equal "completed", released.dig("call_tool", "task", "status")
    @daemon.await("the foreground turn did not join the original shell result") { run.fetch.status == "completed" }
    final_request = workspace.run_task(run_public_id: run_id, task_key: continuation).request.entries.to_json
    assert_equal 1, final_request.scan("long-complete-#{marker}").length
    assert_equal first_request, workspace.run_task(run_public_id: run_id, task_key: "steer1").request.entries.to_json
    assert @page.has_text?("Mock: The queued next turn finished.", wait: WAIT)
    replies = chat.turns.list.items.select { |row| row.kind == "direct_reply" }
    assert_equal 2, replies.length
    assert_equal turn.public_id, replies.first.public_id
    assert_equal original.started_at, run.fetch.tasks.find { |task| task.key == original.key }.started_at
    assert_clean_console
  end

  private

    def dispose_daemon(daemon)
      if (result = daemon&.dispose_connection)
        output, status = result
        assert_predicate status, :success?, "rho disconnect failed during cleanup:\n#{output}"
      end
    end

    def configure_provider
      E2E::SessionSignInBudget.consume
      grant = CybrosAgent::Sessions.new(base_url: @base_url)
        .create(email: @people.owner_email, password: @people.owner_password)
      operator = CybrosAgent::PlatformClient.new(base_url: @base_url, credential: grant.token)
      lane = operator.model_providers.provider("dev")
      lane.enable(expected_lock_version: lane.fetch.lock_version)
    ensure
      operator&.session&.revoke
    end

    def boot_console(mode:, width:, height:, settings: {})
      @daemon = boot_daemon("agent", mode: mode, project: mode == "full" ? @project : @agent_project, settings: settings)
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
      configure_console_model
      assert @page.has_css?("#model option[value='#{MODEL}']", visible: :all, wait: WAIT)
      show_conversations
      assert @page.has_button?("New conversation", wait: WAIT)
    end

    def visit_console(width:, height:, authenticate: true)
      output, status = @daemon.cli("console")
      assert_predicate status, :success?, E2E::SecretHygiene.redact(output)
      url = output[/^console:\s+(\S+)/, 1]
      refute_nil url
      @browser = E2E::BrowserActor.new(url)
      @page = @browser.page
      resize_console(width: width, height: height)
      @browser.visit(url)
      assert @page.has_button?("Connect to Nexus", wait: WAIT)
      assert_equal width, @page.evaluate_script("window.innerWidth")
      if authenticate
        @page.click_button "Connect to Nexus"
        @page.fill_in "Email", with: @steward.email
        @page.fill_in "Password", with: @steward.password
        E2E::SessionSignInBudget.consume
        @page.click_button "Sign in"
        assert @page.has_css?("h1", text: "Sign in to your application", wait: WAIT)
        @page.click_button "Continue"
        assert @page.has_field?("Message", wait: WAIT)
        assert_nil URI(@page.current_url).query, "OAuth code is removed after login"
      end
    end

    def resize_console(width:, height:)
      @page.current_window.resize_to(width, height)
      @page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: width, height: height, deviceScaleFactor: 1, mobile: false)
    end

    def boot_daemon(name, mode:, project:, connect: true, settings: {})
      home = File.join(@root, name)
      FileUtils.mkdir_p(home)
      File.open(File.join(home, "settings.json"), File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(JSON.generate({ "settings_version" => 1, "plugins" => {} }.merge(settings)))
      end
      daemon = E2E::RhoDaemon.new(base_url: @base_url, home: home, tools_root: project,
        browser_url: mode == "runner" ? nil : E2E.handle.fetch("rho_browser_url"), env: { "RHO_MODE" => mode })
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
      @page.find("summary", text: "Working location", exact_text: true).click unless @page.has_field?("Runner", wait: 0)
      @page.find_field("Runner").find("option[value='#{@runner_id}']", visible: :all, wait: WAIT).select_option
      @page.fill_in "Working directory", with: @project
      @page.find_field("Approval mode").find("option[value='#{approval}']").select_option
    end

    def configure_console_model
      @page.click_button "Settings" unless @page.has_css?("dialog.settings-dialog[open]", wait: 0)
      assert @page.has_css?("dialog.settings-dialog[open]", wait: WAIT)
      @page.find_field("Default model").find("option[value='#{MODEL}']", visible: :all, wait: WAIT).select_option
      @page.click_button "Save default model"
      assert @page.has_text?("Default model: #{MODEL}.", wait: WAIT)
      @page.click_button "Close", exact: true
      assert @page.has_no_css?("dialog[open]")
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

    def reply_prompt(text, usage: nil)
      "!mock reply=#{CGI.escape(text)}#{" usage=#{usage}" if usage} -- Give the requested report."
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

    def assert_conversation_usage(requests:, input:, output:, context:)
      assert_equal "rho", @page.title
      assert_equal "/", URI(@page.current_url).path
      assert @page.has_css?(".bar h1", text: "rho", exact_text: true)
      assert @page.has_no_css?("dialog[open]"), "usage is read in the conversation, without a settings overlay"
      assert @page.has_css?(".conversation-usage > summary", text: "Usage · #{input + output} tokens", wait: WAIT)
      assert @page.has_css?(".conversation-usage > summary", text: "Cost 0.0 USD", wait: WAIT),
        "the configured free model has an exact known zero cost"
      @page.find(".conversation-usage > summary").click unless @page.has_css?(".conversation-usage[open]", wait: 0)
      @page.within(".conversation-usage") do
        { "Requests" => requests, "Input tokens" => input, "Output tokens" => output,
          "Total tokens" => input + output }.each do |label, count|
          assert @page.has_xpath?(".//dt[normalize-space(.) = '#{label}']/following-sibling::dd[1]",
            exact_text: count.to_s, wait: WAIT), "#{label} must show the conversation's cumulative usage"
        end
      end
      assert @page.has_css?(".conversation-context > summary", text: "Context · #{context} /", wait: WAIT),
        "context occupancy stays the latest request's usage, not the sum of both requests"
      @page.find(".conversation-context > summary").click unless @page.has_css?(".conversation-context[open]", wait: 0)
      @page.within(".conversation-context") do
        assert @page.has_text?("Latest successful request")
        assert @page.has_text?(MODEL)
      end
    end

    def assert_expanded_usage_keeps_composer_in_view
      @page.find(".conversation-metrics").send_keys(:end)
      @daemon.await("context details must remain reachable by scrolling the metrics") do
        @page.evaluate_script(<<~JS)
          (() => {
            const metrics = document.querySelector(".conversation-metrics").getBoundingClientRect();
            const lastFact = document.querySelector(".conversation-context dd:last-child").getBoundingClientRect();
            return lastFact.top >= metrics.top && lastFact.bottom <= metrics.bottom;
          })()
        JS
      end
      layout = @page.evaluate_script(<<~JS)
        (() => {
          const rect = (selector) => document.querySelector(selector).getBoundingClientRect().toJSON();
          return {
            viewport: { width: window.innerWidth, height: window.innerHeight },
            heading: rect(".conversation-heading"), title: rect(".conversation-title-block"),
            controls: {
              Message: rect("#message"), Send: rect(".composer button[type=submit]"),
              "Conversation history": rect(".transcript")
            }
          };
        })()
      JS
      assert_operator layout.fetch("title").fetch("width"), :>=, layout.fetch("heading").fetch("width") / 2,
        "conversation actions must leave enough width to read the title"
      viewport = layout.fetch("viewport")
      layout.fetch("controls").each do |label, rect|
        assert rect.fetch("width").positive? && rect.fetch("height").positive? &&
          rect.fetch("left") >= 0 && rect.fetch("top") >= 0 &&
          rect.fetch("right") <= viewport.fetch("width") && rect.fetch("bottom") <= viewport.fetch("height"),
          "#{label} must remain inside the viewport with both usage details expanded: #{rect.inspect}"
      end
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
