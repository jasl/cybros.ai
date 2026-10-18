require "test_helper"
require "tmpdir"
require "rho/ingress-telegram"
require "support/actor_provisioning"
require "support/browser_actor"
require "support/ceremony"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"
require "support/telegram_http_server"
require "support/rho_external_bots"

# Real daemon workers and Nexus; only Telegram's remote HTTP service is synthetic.
class RhoTelegramBotsTest < Minitest::Test
  include E2E::RhoExternalBots
  MODEL = "dev/mock-text".freeze
  BOT_MODEL = "dev/mock-text-only".freeze
  TOKEN = E2E::TelegramHttpServer::TOKEN

  def setup
    @job_doors = {}
    @base_url = E2E.base_url
    @steward = E2E::ActorProvisioning.world(@base_url).rho_steward
    @human = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @ceremony = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
    E2E.enable_dev_lane!
    E2E.hosts.start
    @root = Dir.mktmpdir("rho-telegram-bots-e2e")
    @home = Rho::Home.resolve(base_url: @base_url, root: File.join(@root, "home"))
    project = File.join(@root, "project")
    FileUtils.mkdir_p([@home.root, project])
    File.write(@home.settings_path, JSON.generate(
      "settings_version" => 1, "default_model" => MODEL, "webui_access" => "open",
      "plugins" => { "rho.ingress_telegram" => { "enabled" => true, "configuration_version" => 1,
        "configuration" => { "connections" => {}, "bots" => {} } } }
    ), perm: 0o600)
    # One physical Telegram account serves every fixed Bot destination.
    bot_id = SecureRandom.random_number(1_000_000_000) + 1
    @telegram = E2E::TelegramHttpServer.new(bots: {
      TOKEN => E2E::TelegramHttpServer::BOT.merge("id" => bot_id),
    }).start
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home.root, tools_root: project,
      env: { "RHO_MODE" => "full", "E2E_TELEGRAM_URL" => @telegram.url,
        "RUBYOPT" => "-r#{File.expand_path("../support/telegram_http_prelude.rb", __dir__)}" })
    @daemon.start
    E2E::Ceremony.confirm(actor: @ceremony, started: @daemon.start_ceremony, status: -> { @daemon.status })
    @daemon.await("rho workspace adoption") { @daemon.status.dig("workspace", "state") == "adopted" }
    @daemon.await_announced(address: "runner")
    @core = Rho::Core.new(home: @home)
    @default_workspace = @daemon.status.dig("workspace", "public_id")
    @first_workspace = @core.create_workspace(name: "Bot home one").fetch("public_id")
    @second_workspace = @core.create_workspace(name: "Bot home two").fetch("public_id")
    @bot_preset = @daemon.control(:post, "/presets", body: { name: "Telegram test", description: "Answers Telegram test requests.",
      configuration: { model: BOT_MODEL, system_prompt: "Answer the current person's question." } }).fetch("presets")
      .find { |preset| preset.fetch("name") == "Telegram test" }
    @alpha = create_bot("alpha")
    @beta = create_bot("beta")
  end

  def teardown
    unless passed? || !@daemon
      directory = artifact_directory
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "failure.txt"), E2E::SecretHygiene.redact(failures.map(&:to_s).join("\n\n")))
      File.write(File.join(directory, "rho.log"), E2E::SecretHygiene.redact(@daemon.log_text))
      File.write(File.join(directory, "messages.json"), JSON.pretty_generate(@telegram.messages(token: TOKEN)))
      [@default_workspace, @first_workspace, @second_workspace].compact.each_with_index do |workspace_id, index|
        rows = conversations(workspace_id).map do |conversation|
          { "conversation" => conversation.to_h, "turns" => @human.workspace(workspace_id).conversation(conversation.public_id).turns.list.items.map(&:to_h) }
        end
        File.write(File.join(directory, "workspace-#{index}.json"), JSON.pretty_generate(rows))
      end
      E2E::SecretHygiene.save_screenshot(@browser, File.join(directory, "failure.png")) if @browser
    end
  ensure
    @job_doors&.each do |id, door|
      door.cancel(id)
    rescue CybrosAgent::Error => error
      warn "Could not cancel scheduled job #{id}: #{error.message}"
    end
    @browser&.close
    @daemon&.stop
    @telegram&.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_bot_subagent_setting_changes_future_inputs_without_changing_accepted_workers
    set_home(@alpha, @first_workspace)
    configure(@alpha, chat_id: 101)
    await_connected(@alpha)
    assert_equal true, @core.bot_detail(agent_public_id: @alpha.fetch("public_id")).fetch("bot").fetch("subagent")

    brief = "!mock reply=mode-worker -- Finish the assigned task"
    send_message(@alpha, 1, external_script([
      ["spawn", { "role" => "worker", "prompt" => brief, "label" => "mode-worker", "wait" => true }],
    ], reply: "delegation-on"))
    await_reply(@alpha, "Mock: delegation-on")
    chat = bot_conversation(@first_workspace, @alpha)
    first = external_turn(chat, "delegation-on")
    first_tools = bot_round_tools(first)
    assert_includes first_tools, "nexus.conversation.spawn"
    refute_includes first_tools, "code"
    child = chat.children.items.find { |row| row.parent&.label == "mode-worker" }
    refute_nil child
    child_turn = external_turn(external_chat(child.public_id), "mode-worker")
    child_tools = bot_round_tools(child_turn)
    assert_includes child_tools, "code", "the worker retains its own Code Mode choice"

    saved = @daemon.control(:put, "/agents/settings", body: { agent_public_id: @alpha.fetch("public_id"), subagent: false })
    assert_equal false, saved.fetch("subagent")
    send_message(@alpha, 2, "!mock reply=direct-work -- Complete the work here")
    await_reply(@alpha, "Mock: direct-work")
    direct = external_turn(chat, "direct-work")
    direct_tools = bot_round_tools(direct)
    %w[code nexus.conversation.spawn nexus.graph.delegate_task].each { |tool| refute_includes direct_tools, tool }
    assert_includes external_request_text(direct), "Carry out the person's work directly in this conversation"
    assert_equal chat.public_id, bot_current(@alpha).fetch("public_id")
    assert_equal [child.public_id], chat.children.items.map(&:public_id)
    assert_equal first_tools, bot_round_tools(first), "accepted parent tools stay captured"
    assert_equal child_tools, bot_round_tools(child_turn), "accepted worker tools stay captured"

    restored = @daemon.control(:put, "/agents/settings", body: { agent_public_id: @alpha.fetch("public_id"), subagent: true })
    assert_equal true, restored.fetch("subagent")
    send_message(@alpha, 3, "!mock reply=delegation-restored -- Ready for another task")
    await_reply(@alpha, "Mock: delegation-restored")
    assert_includes bot_round_tools(external_turn(chat, "delegation-restored")), "nexus.conversation.spawn"
    assert_equal chat.public_id, bot_current(@alpha).fetch("public_id")
  end

  def test_an_owner_bot_and_its_worker_use_the_paired_applications_private_runner
    set_home(@alpha, @first_workspace)
    configure(@alpha, chat_id: 101)
    await_connected(@alpha)
    send_message(@alpha, 1, "!mock reply=runner-ready -- Prepare the file tools")
    await_reply(@alpha, "Mock: runner-ready")
    chat = bot_conversation(@first_workspace, @alpha)
    first = external_turn(chat, "runner-ready")
    runner_id = @daemon.status.fetch("identity").fetch("runner_executor_public_id")
    declaration = @human.workspace(@first_workspace).runs.run(first.active_variant.run_public_id).task("r1").tool_definitions
    read = declaration.find do |entry|
      route = entry["route"]
      route && route["runner_executor_public_id"] == runner_id && route["tool_name"] == "read"
    end
    refute_nil read, "the owner Bot imports its application's Runner tools"
    callable = read.fetch("function").fetch("name")
    path = File.join(@daemon.tools_root, "family.txt")
    marker = "application-family-#{SecureRandom.hex(6)}"
    File.write(path, "#{marker}\n")
    worker_prompt = external_script([[callable, { "path" => path }]], reply: "worker-read")
    send_message(@alpha, 2, external_script([
      [callable, { "path" => path }],
      ["spawn", { "role" => "worker", "prompt" => worker_prompt, "label" => "file-worker", "wait" => true }],
    ], reply: "bot-read"))
    await_reply(@alpha, "Mock: bot-read")
    parent = external_turn(chat, "bot-read")
    child = chat.children.items.find { |row| row.parent&.label == "file-worker" }
    refute_nil child
    worker = external_turn(external_chat(child.public_id), "worker-read")

    [parent, worker].each do |turn|
      run = @human.workspace(@first_workspace).runs.run(turn.active_variant.run_public_id)
      task = run.fetch.tasks.find { |row| row.tool_name == "read" }
      refute_nil task, "both the Bot and its child must actually call read"
      assert_equal "completed", task.status
      assert_equal runner_id, task.addressed_to.executor_public_id
      assert_includes run.task(task.key).output, marker
    end
  end

  def test_shared_connection_routes_fixed_bots_and_preserves_identity_and_workspace_across_restart
    set_home(@alpha, @first_workspace)
    set_home(@beta, @first_workspace)
    configure(@alpha, chat_id: 101)
    configure(@beta, chat_id: 102, owner_id: 102)
    [@alpha, @beta].each { |bot| await_connected(bot) }
    assert_equal 1, @daemon.control(:get, "/telegram/connections").fetch("connections").length
    assert_equal [@connection_id], [@alpha, @beta].map { |bot| telegram_status(bot).dig("configuration", "connection_public_id") }.uniq

    # Admission rejects an unknown sender and an unbound destination before media IO.
    photo = [{ "file_id" => "must-not-download", "file_unique_id" => "forbidden", "width" => 1, "height" => 1 }]
    @telegram.message(token: TOKEN, id: 1, user: 202, chat: 101, text: "!mock reply=forbidden", photo: photo)
    @telegram.message(token: TOKEN, id: 2, user: 101, chat: -10, text: "!mock reply=forbidden", photo: photo)
    @daemon.await("denied updates are consumed by the shared connection") { connection_status["offset"] == 3 }
    assert_empty conversations(@first_workspace)
    assert_nil bot_current(@alpha)
    assert_nil bot_current(@beta)
    refute @telegram.calls(token: TOKEN).any? { |method, _| method == "getFile" }

    send_message(@alpha, 3, "!mock reply=alpha-first -- First alpha question")
    send_message(@beta, 4, "!mock reply=beta-first -- First beta question")
    await_reply(@alpha, "Mock: alpha-first")
    await_reply(@beta, "Mock: beta-first")
    alpha_chat = bot_conversation(@first_workspace, @alpha)
    beta_chat = bot_conversation(@first_workspace, @beta)
    refute_equal alpha_chat.public_id, beta_chat.public_id
    assert_equal 1, accepted_inputs(alpha_chat).length
    assert_equal 1, accepted_inputs(beta_chat).length
    assert_equal [BOT_MODEL], reply_models(alpha_chat)
    assert_equal [BOT_MODEL], reply_models(beta_chat)
    assert_empty conversations(@default_workspace), "the shared connection creates no implicit Main conversation"
    assert_equal "telegram", @core.conversation(alpha_chat.public_id, workspace_public_id: @first_workspace).fetch("ingresses").first.fetch("channel")
    assert_equal @alpha.fetch("public_id"), alpha_chat.fetch.metadata.fetch("rho_bot_public_id")
    assert_equal @beta.fetch("public_id"), beta_chat.fetch.metadata.fetch("rho_bot_public_id")

    send_message(@alpha, 5, "/job create once in 1h !mock reply=alpha-schedule -- Original workspace job")
    schedule = @daemon.await("the Bot's scheduled job") do
      @core.schedules(alpha_chat.public_id, workspace_public_id: @first_workspace).fetch("schedules").first
    end
    @job_doors[schedule.fetch("public_id")] = alpha_chat.schedules
    assert_equal @alpha.fetch("public_id"), schedule.fetch("answering_user_public_id")
    assert_equal BOT_MODEL, schedule.dig("model", "model")

    set_home(@alpha, @second_workspace)
    send_message(@alpha, 6, "!mock reply=alpha-old-home -- Continue the current dialogue")
    await_reply(@alpha, "Mock: alpha-old-home")
    assert_empty conversations(@second_workspace), "changing Home does not move the current dialogue"
    assert_equal 2, accepted_inputs(alpha_chat).length
    send_message(@alpha, 7, "/new")
    next_current = @daemon.await("New immediately creates the Bot conversation in its latest Home") do
      selected = bot_current(@alpha)
      selected if selected && selected.fetch("public_id") != alpha_chat.public_id
    end
    assert_equal @second_workspace, next_current.fetch("workspace_public_id")
    assert alpha_chat.fetch.archived?
    assert_equal beta_chat.public_id, bot_current(@beta).fetch("public_id")
    send_message(@alpha, 8, "!mock reply=alpha-new-home -- Begin in the new Home")
    await_reply(@alpha, "Mock: alpha-new-home")
    new_chat = bot_conversation(@second_workspace, @alpha)
    refute_equal alpha_chat.public_id, new_chat.public_id
    assert_equal @default_workspace, @daemon.status.dig("workspace", "public_id")

    @daemon.stop
    @daemon.start
    @core = Rho::Core.new(home: @home)
    [@alpha, @beta].each { |bot| await_connected(bot) }
    assert_equal 9, connection_status.fetch("offset")
    assert_equal new_chat.public_id, bot_current(@alpha).fetch("public_id")
    assert_equal beta_chat.public_id, bot_current(@beta).fetch("public_id")
    send_message(@alpha, 9, "/resume #{alpha_chat.public_id}")
    send_message(@alpha, 10, "!mock reply=alpha-resumed -- Return to the original dialogue")
    await_reply(@alpha, "Mock: alpha-resumed")
    assert_equal @first_workspace, bot_current(@alpha).fetch("workspace_public_id")
    assert_equal 3, accepted_inputs(alpha_chat).length
    assert_equal [BOT_MODEL], reply_models(alpha_chat).uniq
    assert_equal 1, accepted_inputs(new_chat).length
    assert_equal 1, accepted_inputs(beta_chat).length
    messages_before_job = bot_messages(@alpha).length
    send_message(@alpha, 11, "/job run #{schedule.fetch("public_id")}")
    execution = @daemon.await("the job completes in its original workspace") do
      row = alpha_chat.schedules.executions(schedule.fetch("public_id")).items.first
      flunk "the scheduled child failed: #{row.to_h.inspect}" if row && %w[failed canceled].include?(row.status)
      row if row&.status == "completed"
    end
    child = @human.workspace(@first_workspace).conversation(execution.child_conversation_public_id)
    assert_equal alpha_chat.public_id, child.fetch.parent.public_id
    assert_equal @alpha.fetch("public_id"), child.fetch.answering_user_public_id
    assert_equal [BOT_MODEL], reply_models(child)
    assert_equal "Mock: alpha-schedule", child.turns.list.items.find { |turn| turn.public_id == execution.turn_public_id }.text
    callback = @daemon.await("the scheduled result reaches the original Bot conversation") do
      alpha_chat.turns.list.items.find do |turn|
        turn.sender_conversation_public_id == child.public_id && turn.kind == "direct_reply" && turn.status == "completed"
      end
    end
    assert_equal schedule.fetch("public_id"), callback.sender_task_key
    assert_equal @alpha.fetch("public_id"), callback.answering_user_public_id
    assert_includes callback.active_variant.prompt_text, "Mock: alpha-schedule"
    # The mock uses the conversation's last directive for its callback answer.
    @daemon.await("the original Telegram destination delivers the new callback") do
      bot_messages(@alpha).drop(messages_before_job).any? do |message|
        message["parse_mode"] == "HTML" && message["text"] == callback.text
      end
    end
    assert_equal @alpha.fetch("public_id"), @core.schedule(alpha_chat.public_id, schedule.fetch("public_id"),
      workspace_public_id: @first_workspace).fetch("answering_user_public_id")
    assert bot_messages(@beta).none? { |message| message.fetch("text").include?("alpha-") }

    # A target switch does not stop the connection or another Bot sharing it.
    before_disabled = accepted_inputs(alpha_chat).length
    assert @daemon.control(:post, "/telegram/configuration", body: { agent_public_id: @alpha.fetch("public_id"), enabled: false }).fetch("saved")
    send_message(@alpha, 12, "!mock reply=disabled-alpha -- This target is disabled")
    send_message(@beta, 13, "!mock reply=beta-still-running -- Continue beta")
    await_reply(@beta, "Mock: beta-still-running")
    assert_equal 2, accepted_inputs(beta_chat).length
    assert_equal before_disabled, accepted_inputs(alpha_chat).length, "the disabled target admits no input"
    assert_equal "running", connection_status.fetch("connection")
    assert telegram_status(@beta).fetch("enabled")
    configure(@alpha, chat_id: 101)
    await_connected(@alpha)

    set_home(@alpha, nil)
    send_message(@alpha, 14, "!mock reply=alpha-without-home -- Continue the existing dialogue")
    await_reply(@alpha, "Mock: alpha-without-home")
    before = [conversations(@first_workspace).length, conversations(@second_workspace).length]
    send_message(@alpha, 15, "/new")
    @daemon.await("the unset Home refuses only new conversations") { connection_status["offset"] == 16 }
    @daemon.await("Telegram explains the missing Home") do
      bot_messages(@alpha).any? do |message|
        message.fetch("text") == "Request not accepted: Choose this Bot's Home Workspace before opening its conversation"
      end
    end
    assert_equal before, [conversations(@first_workspace).length, conversations(@second_workspace).length]
    assert_equal alpha_chat.public_id, bot_current(@alpha).fetch("public_id")
    assert_equal beta_chat.public_id, bot_current(@beta).fetch("public_id")
  end

  def test_browser_configures_one_shared_connection_and_distinct_bot_targets
    output, status = @daemon.cli("console")
    assert_predicate status, :success?, output
    endpoint = output[/^console:\s+(\S+)/, 1]
    @browser = E2E::BrowserActor.new(endpoint)
    @browser.visit(endpoint)
    page = @browser.page
    resize_browser(page, 1400, 1000)
    open_connections(page)
    page.click_button "New connection"
    page.fill_in "Connection name", with: "Shared Telegram"
    page.fill_in "Bot token", with: TOKEN
    page.click_button "Verify and save"
    assert page.has_text?("Shared Telegram connection saved.", wait: E2E::RhoDaemon::WATCH_TIMEOUT)
    assert page.has_field?("Bot token", with: "")
    @connection_id = @daemon.control(:get, "/telegram/connections").fetch("connections").fetch(0).fetch("public_id")
    page.fill_in "Bot token", with: "unsaved-synthetic-token"

    open_bot(page, @alpha)
    assert page.has_text?("Only the bot owner can use this bot in a private Telegram chat.")
    assert page.has_no_select?("Access list")
    assert page.has_no_field?("Bot token"), "a Bot destination does not edit shared credentials"
    save_home(page, "Bot home one")
    save_target(page, chat_id: 101, owner_id: 101)
    await_connected(@alpha)
    assert_nil bot_current(@alpha), "configuring a target does not create a conversation"

    open_bot(page, @beta)
    assert page.has_select?("Home Workspace", selected: "Not set")
    save_home(page, "Bot home two")
    save_target(page, chat_id: 102, owner_id: 102)
    await_connected(@beta)
    assert_nil bot_current(@beta)
    open_bot(page, @alpha)
    assert page.has_select?("Home Workspace", selected: "Bot home one")
    assert page.has_field?("Chat ID", with: "101")
    assert page.has_field?("Bot owner user ID", with: "101")
    assert_equal [@connection_id], [@alpha, @beta].map { |bot| telegram_status(bot).dig("configuration", "connection_public_id") }.uniq
    FileUtils.mkdir_p(artifact_directory)
    assert page.has_no_css?(".toast"), "save notices finish before capturing the page"
    target = page.find(".card", text: "Telegram target")
    page.find(".bots-page").scroll_to(target, align: :top)
    E2E::SecretHygiene.save_screenshot(@browser, File.join(artifact_directory, "telegram-bot-desktop.png"))
    resize_browser(page, 390, 844)
    page.find(".bots-page").scroll_to(target, align: :top)
    assert page.has_button?("Save Telegram target")
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "the narrow target page does not overflow"
    E2E::SecretHygiene.save_screenshot(@browser, File.join(artifact_directory, "telegram-bot-narrow.png"))
    resize_browser(page, 1400, 1000)

    send_message(@alpha, 1, "!mock reply=alpha-from-ui -- Alpha configured in the browser")
    send_message(@beta, 2, "!mock reply=beta-from-ui -- Beta configured in the browser")
    await_reply(@alpha, "Mock: alpha-from-ui")
    await_reply(@beta, "Mock: beta-from-ui")
    alpha = bot_conversation(@first_workspace, @alpha)
    beta = bot_conversation(@second_workspace, @beta)
    refute_equal alpha.public_id, beta.public_id
    assert_empty conversations(@default_workspace)
    page.click_button "Open current conversation", exact: true
    assert page.has_text?("Telegram · Chat 101 — Continue in the original channel. This page is read-only. Stop remains available.", wait: E2E::RhoDaemon::WATCH_TIMEOUT)
    assert page.has_field?("Message", disabled: true)
    assert_equal "/workspaces/#{@first_workspace}/conversations/#{alpha.public_id}", URI(page.current_url).path
    assert_equal alpha.public_id, bot_current(@alpha).fetch("public_id")
    assert_equal beta.public_id, bot_current(@beta).fetch("public_id")
    E2E::SecretHygiene.save_screenshot(@browser, File.join(artifact_directory, "telegram-current-desktop.png"))
    resize_browser(page, 390, 844)
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "the narrow current view does not overflow"
    E2E::SecretHygiene.save_screenshot(@browser, File.join(artifact_directory, "telegram-current-narrow.png"))
    resize_browser(page, 1400, 1000)

    open_connections(page)
    assert page.has_field?("Bot token", with: ""), "leaving Connections discarded the unsaved token"
    assert connection_status.fetch("token").fetch("present")
    assert_equal 1, @daemon.control(:get, "/telegram/connections").fetch("connections").length
    refute_includes JSON.generate(@daemon.control(:get, "/extensions")), TOKEN
    refute_includes JSON.generate(telegram_status(@beta)), TOKEN
  end

  private

    def open_connections(page)
      page.click_link "Settings", exact: true
      assert page.has_css?(".settings-page", wait: E2E::RhoDaemon::WATCH_TIMEOUT)
      page.click_button "Connections", exact: true
      assert page.has_text?("Telegram connections", wait: E2E::RhoDaemon::WATCH_TIMEOUT)
    end

    def open_bot(page, bot)
      page.click_link "Bots", exact: true
      page.within(%(article[data-bot="#{bot.fetch("name")}"])) { page.click_button "Settings", exact: true }
      assert page.has_field?("Name", with: bot.fetch("name"), wait: E2E::RhoDaemon::WATCH_TIMEOUT)
    end

    def save_home(page, name)
      page.select name, from: "Home Workspace"
      page.click_button "Save Home Workspace"
      assert page.has_text?("Home Workspace was saved.", wait: E2E::RhoDaemon::WATCH_TIMEOUT)
    end

    def save_target(page, chat_id:, owner_id:)
      page.within(".card", text: "Telegram target") do
        page.find_field("Shared connection").find(%(option[value="#{@connection_id}"]), visible: :all, wait: E2E::RhoDaemon::WATCH_TIMEOUT).select_option
        page.fill_in "Chat ID", with: chat_id.to_s
        page.fill_in "Bot owner user ID", with: owner_id.to_s
        page.check "Enable this Telegram target", allow_label_click: true
        page.click_button "Save Telegram target"
      end
      assert page.has_text?("Telegram settings saved.", wait: E2E::RhoDaemon::WATCH_TIMEOUT)
    end

    def resize_browser(page, width, height)
      page.current_window.resize_to(width, height)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: width, height: height, deviceScaleFactor: 1, mobile: false)
      assert_equal width, page.evaluate_script("window.innerWidth")
      assert page.has_css?(".frame__main") { |main|
        (width >= 768 || main.native.rect.x.zero?) &&
          page.evaluate_script("document.querySelector('.frame').getAnimations().every(animation => animation.playState !== 'running')")
      }
    end

    def create_bot(name, audience: "owner", preset_public_id: @bot_preset.fetch("public_id"))
      @daemon.control(:put, "/agents", body: { name: "#{name}-#{SecureRandom.hex(4)}", display_name: name.capitalize,
        description: "Answers the configured Telegram destination.", audience: audience, preset_public_id: preset_public_id }).fetch("agent")
    end

    def bot_round_tools(turn)
      @mode_tool_catalog ||= @daemon.control(:get, "/kernel_tools").fetch("tools").to_h do |tool|
        [tool.fetch("name"), tool.fetch("canonical_name")]
      end
      detail = @human.workspace(@first_workspace).runs.run(turn.active_variant.run_public_id).task("r1")
      detail.tool_definitions.map do |entry|
        name = entry.fetch("function").fetch("name")
        entry["canonical"] || entry.dig("route", "tool_name") || @mode_tool_catalog.fetch(name, name)
      end
    end

    def set_home(bot, workspace_id, audience: nil)
      body = { agent_public_id: bot.fetch("public_id"), home_workspace_public_id: workspace_id }
      body[:audience] = audience unless audience.nil?
      result = @daemon.control(:put, "/agents/settings", body: body)
      assert_equal bot.fetch("public_id"), result.fetch("agent_public_id")
      if workspace_id
        assert_equal workspace_id, result.fetch("home_workspace_public_id")
      else
        assert_nil result.fetch("home_workspace_public_id")
      end
      assert_equal audience, result.fetch("audience") if audience
    end

    def connect_shared
      unless @connection_id
        saved = @daemon.control(:post, "/telegram/connection", body: { name: "Shared Telegram", enabled: true, token: TOKEN })
        @connection_id = saved.fetch("connection").fetch("public_id")
      end
      connection_status
    end

    def configure(bot, chat_id:, owner_id: 101)
      connect_shared
      result = @daemon.control(:post, "/telegram/configuration", body: { agent_public_id: bot.fetch("public_id"),
        enabled: true, connection_public_id: @connection_id, owner_id: owner_id,
        target: { chat_id: chat_id, topic_id: nil }, input_debounce_seconds: 0 })
      assert result.fetch("saved"), result.inspect
    end

    def telegram_status(bot)
      @daemon.control(:get, "/telegram?#{URI.encode_www_form(agent_public_id: bot.fetch("public_id"))}")
    end

    def connection_status
      @daemon.control(:get, "/telegram/connection?#{URI.encode_www_form(connection_public_id: @connection_id)}").fetch("connection")
    end

    def bot_current(bot) = @core.bot_detail(agent_public_id: bot.fetch("public_id")).fetch("current")

    def await_connected(bot)
      @daemon.await("#{bot.fetch("name")} connects to Telegram") { telegram_status(bot)["connection"] == "running" }
    end

    def send_message(bot, id, text, user: nil)
      configuration = telegram_status(bot).fetch("configuration")
      target = configuration.fetch("target")
      mention = "@#{E2E::TelegramHttpServer::BOT.fetch("username")}"
      if target.fetch("chat_id").to_i.negative? && !text.start_with?("/")
        text = "#{mention}\n#{text}"
        entities = [{ "type" => "mention", "offset" => 0, "length" => mention.length }]
      end
      @telegram.message(token: TOKEN, id: id, user: user || configuration.fetch("owner_id").to_i,
        chat: target.fetch("chat_id").to_i, topic: target["topic_id"], text: text, entities: entities)
    end

    def bot_messages(bot)
      chat = telegram_status(bot).dig("configuration", "target", "chat_id").to_s
      @telegram.messages(token: TOKEN).select { |message| message["chat_id"].to_s == chat }
    end

    def await_reply(bot, text)
      @daemon.await("Telegram reply #{text}") do
        bot_messages(bot).find { |message| message["parse_mode"] == "HTML" && message["text"] == text }
      end
    end

    def conversations(workspace_id)
      @human.workspace(workspace_id).conversations.list.items
    end

    def bot_conversation(workspace_id, bot)
      selected = bot_current(bot)
      refute_nil selected
      assert_equal workspace_id, selected.fetch("workspace_public_id")
      chat = @human.workspace(workspace_id).conversation(selected.fetch("public_id"))
      assert_equal bot.fetch("public_id"), chat.fetch.answering_user_public_id
      chat
    end

    def accepted_inputs(chat)
      chat.events(limit: 100).select { |event| event.type == "input_accepted" }
    end

    def reply_models(chat)
      chat.turns.list.items.select { |turn| turn.kind == "direct_reply" }.map do |turn|
        model = turn.active_variant.model
        "#{model.provider_id}/#{model.model_ref}"
      end
    end

    def artifact_directory
      File.expand_path("../artifacts/rho_telegram_bots/#{name}-#{Process.pid}", __dir__)
    end
end
