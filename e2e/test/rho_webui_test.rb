require "test_helper"
require "cgi/escape"
require "fileutils"
require "securerandom"
require "tmpdir"
require "uri"
require "support/actor_provisioning"
require "support/ceremony"
require "support/rho_daemon"
require "support/rho_webui_browser"
require "support/secret_hygiene"
require "support/steward_session"
require "support/web_fixture"

# The shipped page drives the same daemon a terminal uses. Pairing, provider
# setup and long-history preparation use public APIs; the journeys exercise
# ordinary browser interactions against the real kernel and fake provider.
class RhoWebuiTest < Minitest::Test
  include E2E::RhoWebuiBrowser

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

    # Leaving for Nexus and coming Back lands on a working login page, whether
    # the browser kept the document in its back/forward cache or loads it again.
    @page.click_button "Connect to Nexus"
    assert @page.has_field?("Email", wait: WAIT), "the browser is on the Nexus sign-in page"
    @page.go_back
    assert @page.has_button?("Use a device code", wait: WAIT)

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
    open_settings
    @page.within(".settings-page") do
      assert @page.has_text?(@steward.display_name, wait: WAIT)
    end
    close_settings
    @daemon.await("rho never adopted its workspace") { @daemon.status.dig("workspace", "state") == "adopted" }
    @daemon.await_announced(address: "runner")
    @runner_id = @daemon.status.dig("identity", "runner_executor_public_id")
    configure_console_model
    refute @page.has_css?("[role=alert]:not([hidden])")
    new_conversation
    send_message(reply_prompt("Connected after setup."))
    assert @page.has_text?("Mock: Connected after setup.", wait: WAIT)
    assert_a_sidebar_workspace_scopes_the_list_and_new_conversations
  end

  # The sidebar's top row switches workspaces and creates one. A new
  # workspace lists nothing yet, a conversation made there belongs to it, and
  # switching back shows the first workspace's conversations again; rho's
  # own default workspace is untouched.
  def assert_a_sidebar_workspace_scopes_the_list_and_new_conversations
    first = conversation_id
    own = @daemon.control(:get, "/workspaces").dig("workspace", "public_id")
    show_conversations
    assert @page.has_css?(".browser__row", count: 1, wait: WAIT)
    @page.find("button[aria-label^='Workspace: ']").click
    @page.find('[role="menuitem"]', text: "New workspace…").click
    @page.fill_in "Name", with: "Side project"
    @page.click_button "Create workspace"
    assert @page.has_text?("Side project is your current workspace.", wait: WAIT)
    # Switching navigates to the new workspace's hero, which closes a drawer.
    show_conversations
    assert @page.has_button?("Workspace: Side project", wait: WAIT)
    assert @page.has_no_css?(".browser__row", wait: WAIT), "a fresh workspace lists no conversations"
    side = @daemon.control(:get, "/workspaces").fetch("workspaces").find { |row| row.fetch("name") == "Side project" }
    assert_equal own, @daemon.control(:get, "/workspaces").dig("workspace", "public_id"), "the daemon's default workspace is unchanged"
    assert_equal "/workspaces/#{side.fetch("public_id")}", URI(@page.current_url).path

    new_conversation
    send_message(reply_prompt("Hello from the side project."))
    assert @page.has_text?("Mock: Hello from the side project.", wait: WAIT)
    client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    made = conversation_id
    assert_equal made, client.workspace(side.fetch("public_id")).conversation(made).fetch.public_id, "the conversation lives in the new workspace"
    assert_raises(CybrosAgent::Api::NotFound) { client.workspace(own).conversation(made).fetch }
    show_conversations
    assert @page.has_css?(".browser__row", count: 1, wait: WAIT)

    @page.find("button[aria-label^='Workspace: ']").click
    @page.find('[role="menuitemradio"]', text: /rho's default/).click
    own_name = @daemon.control(:get, "/workspaces").fetch("workspaces").find { |row| row.fetch("public_id") == own }.fetch("name")
    show_conversations
    assert @page.has_button?("Workspace: #{own_name}", wait: WAIT)
    assert @page.has_css?(".browser__row", count: 1, wait: WAIT)
    @page.find(".browser__row a").click
    assert_equal first, conversation_id
    assert @page.has_text?("Mock: Connected after setup.", wait: WAIT)
    close_sidebar

    # Back walks the address history and the page follows it: rho's default
    # hero, then the side project's conversation in its workspace, then that
    # workspace's hero, then the first conversation back in rho's default.
    @page.go_back
    assert @page.has_no_text?("Mock: Connected after setup.", wait: WAIT)
    @page.go_back
    assert @page.has_text?("Mock: Hello from the side project.", wait: WAIT)
    show_conversations
    assert @page.has_button?("Workspace: Side project", wait: WAIT)
    close_sidebar
    @page.go_back
    assert @page.has_no_text?("Mock: Hello from the side project.", wait: WAIT)
    show_conversations
    assert @page.has_button?("Workspace: Side project", wait: WAIT)
    assert @page.has_css?(".browser__row", count: 1, wait: WAIT)
    close_sidebar
    @page.go_back
    assert @page.has_text?("Mock: Connected after setup.", wait: WAIT)
    show_conversations
    assert @page.has_button?("Workspace: #{own_name}", wait: WAIT)
    close_sidebar
    # Forward returns the same way, and an address without a workspace — rho's
    # default hero — moves the page out of the side project again.
    @page.go_forward
    @page.go_forward
    assert @page.has_text?("Mock: Hello from the side project.", wait: WAIT)
    @page.go_forward
    assert @page.has_no_text?("Mock: Hello from the side project.", wait: WAIT)
    show_conversations
    assert @page.has_button?("Workspace: #{own_name}", wait: WAIT)
    assert @page.has_css?(".browser__row", count: 1, wait: WAIT)
    close_sidebar
  end

  # The gate in front of a paired rho. On loopback it opens by itself, so a
  # page needs no sign-in to use rho; the owner may ask for rho's unlock
  # password instead, which every fresh browser must then give. A Nexus
  # sign-in still works from Settings and is what Nexus account facts need.
  def test_the_gate_opens_a_loopback_console_by_itself_and_can_ask_for_a_password_instead
    boot_console(mode: "full", width: 1400, height: 1000, settings: { "webui_access" => nil }, gate: :open)
    status = @daemon.control(:get, "/auth/status")
    assert_equal({ "mode" => "open", "configured" => nil, "password_set" => false }, status.fetch("access"))
    open_settings
    @page.within(".settings-page") do
      assert @page.has_text?("rho's gate is open here", wait: WAIT)
      assert @page.has_button?("Sign in with Nexus")
      assert @page.has_no_button?("Sign out")
      assert @page.has_text?("Right now: Open · anyone who reaches this page.")
      @page.select "Unlock password", from: "Who can open this page"
      @page.fill_in "Unlock password", with: "correct horse battery"
      @page.within(".card", text: "Opening this page") { @page.click_button "Save", exact: true }
      assert @page.has_text?("Right now: Unlock password.", wait: WAIT)
    end
    assert_equal "password", @daemon.control(:get, "/settings").dig("settings", "webui_access")
    assert_equal true, @daemon.control(:get, "/auth/status").dig("access", "password_set")
    refute_includes File.read(File.join(@daemon.home, "webui_password.json")), "correct horse battery"
    assert @page.has_css?(".settings-page", wait: WAIT), "the page that set the password stays in"
    assert @page.has_no_css?("h1", text: "Unlock rho")
    close_settings

    # A fresh browser meets the gate.
    locked = E2E::BrowserActor.new(console_url)
    locked.page.current_window.resize_to(1400, 1000)
    locked.visit(console_url)
    assert locked.page.has_css?("h1", text: "Unlock rho", wait: WAIT)
    assert locked.page.has_no_button?("Connect to Nexus")
    locked.page.fill_in "Unlock password", with: "wrong"
    locked.page.click_button "Unlock"
    assert locked.page.has_text?("That is not the unlock password", wait: WAIT)
    locked.page.fill_in "Unlock password", with: "correct horse battery"
    locked.page.click_button "Unlock"
    assert locked.page.has_field?("Message", wait: WAIT)
    locked.page.click_link "Settings", exact: true
    locked.page.within(".settings-page") do
      assert locked.page.has_text?("Unlocked with rho's password", wait: WAIT)
      assert locked.page.has_button?("Lock")
      locked.page.click_button "Sign in with Nexus"
    end
    locked.page.fill_in "Email", with: @steward.email
    locked.page.fill_in "Password", with: @steward.password
    E2E::SessionSignInBudget.consume
    locked.page.click_button "Sign in"
    assert locked.page.has_css?("h1", text: "Sign in to your application", wait: WAIT)
    locked.page.click_button "Continue"
    # The sign-in returns to the page it left from: Settings.
    assert locked.page.has_link?("Settings", exact: true, wait: WAIT)
    locked.page.click_link "Settings", exact: true
    locked.page.within(".settings-page") do
      assert locked.page.has_text?("Signed in to Nexus as #{@steward.display_name}", wait: WAIT)
      locked.page.click_button "Sign out"
    end
    assert locked.page.has_css?("h1", text: "Unlock rho", wait: WAIT), "signing out of the Nexus account meets the gate again"
    locked.close
  end

  def test_editing_an_imported_preset_preserves_its_prompt_template_model_and_empty_tools
    preset_name = "template-#{SecureRandom.hex(4)}"
    prompt = "Review in {{tone}} style.\n"
    template = {
      "blocks" => [{ "type" => "slot", "slot" => "system_prompt" },
                   { "type" => "inline", "role" => "system", "text" => "Use the {{tone}} review style." },
                   { "type" => "history" }, { "type" => "input" }],
      "variables" => { "tone" => "brief" },
    }
    directory = File.join(@project, ".agents", "agents")
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "#{preset_name}.md"), <<~TEXT)
      ---
      description: Reviews a diff for defects.
      model: #{MODEL}
      tools: []
      prompt_template: #{JSON.generate(template)}
      ---
      Review in {{tone}} style.
    TEXT

    boot_console(mode: "full", width: 1400, height: 1000)
    bot_ids = @daemon.control(:get, "/agents").fetch("bots").map { |row| row.fetch("public_id") }.sort
    open_settings
    @page.click_button "Agent Presets", exact: true
    @page.click_button "Import project Presets"
    assert @page.has_text?("1 Presets imported", wait: WAIT)
    imported = @daemon.control(:get, "/presets").fetch("presets").find { |row| row.fetch("name") == preset_name }
    refute_nil imported
    assert_equal template, imported.dig("configuration", "prompt_template")
    assert_equal MODEL, imported.dig("configuration", "model")
    assert_equal [], imported.dig("configuration", "tools")
    @page.within(%(article[data-preset="#{imported.fetch("public_id")}"])) { @page.click_button preset_name, exact: true }
    @page.within(".preset-editor") do
      assert @page.has_field?("Preset name", with: preset_name, wait: WAIT)
      assert @page.has_field?("System prompt", with: prompt)
      @page.fill_in "Description", with: "Reviews architecture and implementation."
      @page.click_button "Save", exact: true
    end
    assert @page.has_css?(
      %(article[data-preset="#{imported.fetch("public_id")}"]),
      text: "Reviews architecture and implementation.", wait: WAIT
    )

    saved = @daemon.control(:get, "/presets").fetch("presets").find { |row| row.fetch("name") == preset_name }
    refute_nil saved
    assert_equal imported.fetch("public_id"), saved.fetch("public_id")
    assert_equal "Reviews architecture and implementation.", saved.fetch("description")
    assert_equal prompt, saved.dig("configuration", "system_prompt")
    assert_equal template, saved.dig("configuration", "prompt_template")
    assert_equal MODEL, saved.dig("configuration", "model")
    assert_equal [], saved.dig("configuration", "tools")
    assert_equal bot_ids, @daemon.control(:get, "/agents").fetch("bots").map { |row| row.fetch("public_id") }.sort
    assert_clean_console
  end

  def test_the_title_model_setting_generates_a_first_title_and_can_disable_generation
    boot_console(mode: "full", width: 1400, height: 1000)
    open_settings
    @page.click_button "Defaults", exact: true
    assert @page.has_select?("Conversation title model", selected: "Follow current model", wait: WAIT)
    assert_equal "follow_current", @daemon.control(:get, "/settings").dig("settings", "conversation_title_model")
    title_model_ref = "dev/mock-text-only"
    title_model = @page.find_field("Conversation title model")
    assert title_model.has_css?("option[value='#{title_model_ref}']", visible: :all, wait: WAIT)
    title_model.find("option[value='#{title_model_ref}']", visible: :all).select_option
    @page.within(".card", text: "Agent behavior") { @page.click_button "Save", exact: true }
    assert @page.has_text?("Settings saved and active.", wait: WAIT)
    assert_equal title_model_ref, @daemon.control(:get, "/settings").dig("settings", "conversation_title_model")
    screenshot("title-model-desktop")
    resize_console(width: 390, height: 844)
    screenshot("title-model-narrow")
    resize_console(width: 1400, height: 1000)
    assert @page.has_button?("New conversation", wait: WAIT)
    close_settings

    client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    workspace = client.workspace(@workspace_id)
    title_sides = lambda do |chat|
      chat.events(limit: 100).filter_map do |event|
        event.payload.fetch("child_conversation_public_id") if event.type == "fork_created" && event.payload["side"]
      end
    end
    new_conversation
    # Keep the temporary title execution observable through its public turn
    # before completion deletes it. The provider's existing stream controls
    # bound the delay without changing the requested answer.
    reasoning = CGI.escape("Planning context. " * 60)
    send_message(reply_prompt("Project planning").sub("!mock ", "!mock reasoning=#{reasoning} stream_chunk_delay=0.2 "))
    assert @page.has_current_path?(%r{/conversations/}, url: true, wait: WAIT)
    conversation = workspace.conversation(conversation_id)
    title_side_id = @daemon.await("the title's temporary Side never appeared") { title_sides.call(conversation).first }
    title_side = workspace.conversation(title_side_id)
    title_turn = @daemon.await("the title's model never started") do
      title_side.turns.list(include_hidden: true).items.find do |turn|
        !turn.inherited? && !turn.reference? && turn.kind == "direct_reply" &&
          turn.status == "running" && turn.active_variant&.model
      end
    end
    title_model = title_side.turns.fetch(title_turn.public_id, include_hidden: true).active_variant.model
    assert_equal title_model_ref, "#{title_model.provider_id}/#{title_model.model_ref}"
    assert @page.has_css?("main h1", text: "Mock: Project planning", exact_text: true, wait: WAIT)
    assert_equal "Mock: Project planning", conversation.fetch.title
    @daemon.await("the title's temporary Side was not reaped") do
      title_side.fetch
      false
    rescue CybrosAgent::Api::NotFound
      true
    end
    assert_equal [title_side_id], title_sides.call(conversation), "one background title execution is sufficient"
    assert_empty workspace.inference_requests.list.items, "title content stays under the source conversation's access"
    assert @page.has_button?("Model: #{model_label(MODEL)}"), "the reply keeps its selected model"
    show_conversations
    assert @page.has_link?("Mock: Project planning", wait: WAIT), "the sidebar receives the generated title"
    close_sidebar
    send_message(reply_prompt("A later request"))
    assert @page.has_text?("Mock: A later request", wait: WAIT)
    assert_equal "Mock: Project planning", conversation.fetch.title, "later input does not retitle the conversation"
    assert_equal [title_side_id], title_sides.call(conversation), "later input creates no additional title execution"

    conversation_action "Rename"
    @page.fill_in "Conversation title", with: "My project"
    @page.find_field("Conversation title").send_keys(:enter)
    assert @page.has_css?("main h1", text: "My project", exact_text: true, wait: WAIT)
    @page.refresh
    assert @page.has_css?("main h1", text: "My project", exact_text: true, wait: WAIT)

    open_settings
    @page.click_button "Defaults", exact: true
    @page.select "None", from: "Conversation title model"
    @page.within(".card", text: "Agent behavior") { @page.click_button "Save", exact: true }
    assert @page.has_text?("Settings saved and active.", wait: WAIT)
    assert_nil @daemon.control(:get, "/settings").dig("settings", "conversation_title_model")
    @page.refresh
    @page.click_button "Defaults", exact: true
    assert @page.has_select?("Conversation title model", selected: "None", wait: WAIT)
    close_settings
    new_conversation
    send_message(reply_prompt("A disabled title"))
    assert @page.has_text?("Mock: A disabled title", wait: WAIT)
    disabled = workspace.conversation(conversation_id)
    assert_nil disabled.fetch.title
    assert_empty title_sides.call(disabled), "a disabled title setting creates no title execution"
    assert_empty workspace.inference_requests.list.items
    assert_clean_console
  end

  def test_a_desktop_conversation_keeps_its_messages_and_lifecycle_after_reload
    boot_console(mode: "full", width: 1400, height: 1000)
    new_conversation
    assert_includes menu_choices("Model"), model_label(MODEL)
    assert_includes menu_choices("Runner"), runner_choice(@runner_id)
    refute_includes menu_choices("Model"), "e2e-key/mock-keyed-text"

    send_message(reply_prompt(MARKDOWN, usage: "17:5").sub("!mock ", "!mock stream_chunk_delay=0.2 "))
    assert @page.has_text?("Mock: A small report.", wait: WAIT)
    assert @page.has_css?('.usage-chip[aria-label^="Usage · 22 tokens"]', wait: WAIT)
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
    assert_equal "message", @page.evaluate_script("document.activeElement.name"), "streamed output preserves focus"
    assert @page.has_field?("Message", with: draft)

    send_after_network_failure(draft)
    assert @page.has_text?("Mock: The second answer remembers this conversation.", wait: WAIT)
    assert_equal conversation, conversation_id
    assert_conversation_usage(requests: 2, input: 48, output: 14, context: 40)
    @page.refresh
    assert @page.has_css?("article[data-turn-id] h2", text: "Browser report", wait: WAIT)
    assert @page.has_text?("Mock: The second answer remembers this conversation.")
    assert @page.has_button?("Model: #{model_label(MODEL)}", wait: WAIT), "the conversation's model survives reload and model discovery"
    assert_equal 4, @page.all("article[data-turn-id]").length, "two user messages and two durable answers"
    assert_conversation_usage(requests: 2, input: 48, output: 14, context: 40)
    screenshot("desktop-usage")
    resize_console(width: 390, height: 844)
    assert_conversation_usage(requests: 2, input: 48, output: 14, context: 40)
    assert_expanded_usage_keeps_composer_in_view
    screenshot("narrow-usage")
    resize_console(width: 1400, height: 1000)

    conversation_action "Rename"
    @page.fill_in "Conversation title", with: "Browser lifecycle"
    @page.find_field("Conversation title").send_keys(:enter)
    assert @page.has_css?("main h1", text: "Browser lifecycle", wait: WAIT)
    screenshot("desktop-conversation")
    conversation_action "Archive"
    assert @page.has_css?(".conversation__heading", text: "Archived", wait: WAIT)
    show_conversations
    @page.click_button "Conversation list options"
    @page.find('[role="menuitemcheckbox"]', text: "Show archived").click
    @page.click_link "Browser lifecycle"
    assert @page.has_text?("Mock: The second answer remembers this conversation.", wait: WAIT)
    assert menu_items("Conversation actions").include?("Restore")
    conversation_action "Restore"
    @page.refresh
    assert @page.has_css?("main h1", text: "Browser lifecycle", wait: WAIT)
    assert @page.has_text?("Mock: The second answer remembers this conversation.")
    assert menu_items("Conversation actions").include?("Archive")
    assert_equal conversation, conversation_id
    assert_conversation_usage(requests: 2, input: 48, output: 14, context: 40)
    assert_long_history(conversation)
    assert_clean_console
  end

  def test_a_narrow_console_answers_approvals_and_stops_work_on_a_separate_runner
    # The mock echoes the scripted final reply as a title too; these assertions
    # follow tool completion, so this journey opts out of that independent call.
    boot_console(mode: "agent", width: 390, height: 844, settings: { "conversation_title_model" => nil })
    new_conversation
    send_message(tool_prompt("ask", { "prompt" => "Which database?" }, "Question answered."))
    assert @page.has_text?("Which database?", wait: WAIT)
    assert @page.has_field?("Answer", wait: WAIT)
    @page.refresh
    assert @page.has_field?("Answer", wait: WAIT), "a pending question survives page reload"
    assert @page.has_no_field?("Message", wait: 0), "the question takes the composer's seat until it is answered"
    @page.fill_in "Answer", with: "Postgres"
    screenshot("narrow-question")
    @page.click_button "Send answer"
    assert @page.has_text?("Mock: Question answered.", wait: WAIT)
    assert @page.has_field?("Message", wait: WAIT), "the composer returns once the question is answered"

    client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    workspace = client.workspace(@workspace_id)
    answered = workspace.conversation(conversation_id).turns.list.items.last
    declared = workspace.runs.run(answered.active_variant.run_public_id).task("r1").tool_definitions
    entry = declared.find do |tool|
      tool.dig("route", "runner_executor_public_id") == @runner_id && tool.dig("route", "tool_name") == "bash"
    end
    refute_nil entry, "the accepted turn declares the separate Runner's bash callable"
    bash = entry.fetch("function").fetch("name")
    publisher = declared.find do |tool|
      tool.dig("route", "runner_executor_public_id") == @runner_id && tool.dig("route", "tool_name") == "file_publish"
    end
    refute_nil publisher, "the separate Runner can publish the file it created"
    publish = publisher.fetch("function").fetch("name")

    new_conversation
    command = "printf '%s' '#{SVG}' > preview.svg; printf preview.svg"
    publish_arguments = CGI.escape(JSON.generate("path" => "preview.svg"))
    send_message(tool_prompt("#{bash},#{publish}:#{publish_arguments}", { "command" => command }, "The preview is ready: preview.svg"))
    assert @page.has_button?("Approve", wait: WAIT)
    refute @page.has_button?("Allow this site until restart", wait: 0)
    refute File.exist?(File.join(@project, "preview.svg")), "the held command has not executed"
    screenshot("narrow-approval")
    @page.click_button "Approve"
    assert @page.has_text?("Mock: The preview is ready: preview.svg", wait: WAIT)
    assert_equal SVG, File.read(File.join(@project, "preview.svg"))
    refute File.exist?(File.join(@agent_project, "preview.svg")), "the separate runner owns the working directory"
    @page.click_button "Preview preview.svg", match: :first
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
      settings: { "conversation_title_model" => nil, "plugins" => { "rho.web_tools" => {
        "configuration" => { "allow_private_network" => true },
      } } })
    new_conversation
    first_url = "#{@web_fixture.site}/page.html"
    send_message(tool_prompt("web_fetch", { "url" => first_url }, "The first page was fetched."))
    assert @page.has_button?("Allow this site until restart", wait: WAIT)
    assert @page.has_css?(".ask__input", text: first_url)
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
    marker = SecureRandom.hex(4)
    command = "until test -f release; do sleep 0.1; done; printf 'long-%s\\n' complete-#{marker}"
    send_message(tool_prompt("bash", { "command" => command, "timeout" => 180 }, "The original work finished."))
    assert @page.has_current_path?(%r{/conversations/}, url: true, wait: WAIT)
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
    assert @page.has_button?("Send behavior: Steer current work"), "a running turn defaults to steering"
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

    @page.click_button "Send behavior: Steer current work"
    @page.find('[role="menuitemradio"]', text: "Queue after current reply").click
    queued = reply_prompt("The queued next turn finished.")
    send_message(queued)
    assert @page.has_text?("Message queued", wait: WAIT)
    assert_equal "queue", chat.inputs.list.items.find { |input| input.text == queued }.delivery_mode
    immediate = reply_prompt("The keyboard correction was read immediately.")
    @page.fill_in "Message", with: immediate
    @page.click_button "Send behavior: Queue after current reply"
    assert @page.has_css?('[role="menuitem"]:not([disabled])', text: "Send now", wait: WAIT),
      "a typed draft offers Send now while the queue holds another message"
    @page.send_keys :escape
    assert @page.has_no_css?('[role="menu"]', wait: WAIT)
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
end
