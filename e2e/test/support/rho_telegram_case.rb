require "test_helper"
require "cgi/escape"
require "tmpdir"
require "rho/ingress-telegram"
require "support/actor_provisioning"
require "support/ceremony"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"
require "support/telegram_client"
require "support/rho_telegram_media"
require_relative "rho_telegram_memory"
require_relative "rho_telegram_commands"
require_relative "rho_telegram_controls"
require_relative "rho_telegram_history"
require_relative "rho_telegram_groups"
require_relative "rho_telegram_permissions"
require_relative "rho_telegram_participation"

module E2E
  # Shared setup and controls only; concrete suites own every runnable journey.
  class RhoTelegramCase < Minitest::Test
    include RhoTelegramCommands::Helpers
    include RhoTelegramControls::Helpers
    include RhoTelegramGroups::Helpers

    MODEL = "dev/mock-text".freeze
    Host = Data.define(:home, :member_plane)

    def setup
      @connection_id = SecureRandom.uuid
      @base_url = E2E.base_url
      people = E2E::ActorProvisioning.world(@base_url)
      steward = people.rho_steward
      @human = CybrosAgent::Client.new(base_url: @base_url, credential: steward.member_token)
      @ceremony = E2E::StewardSession.actor(base_url: @base_url, human: steward)
      E2E.enable_dev_lane!
      E2E.hosts.start
      @root = Dir.mktmpdir("rho-telegram-e2e")
      @home = Rho::Home.resolve(base_url: @base_url, root: File.join(@root, "home"))
      FileUtils.mkdir_p([@home.root, File.join(@root, "project")])
      # The console journeys sign in with Nexus (`webui_access: nexus`); on
      # loopback the gate would otherwise open by itself.
      File.write(File.join(@home.root, "settings.json"), JSON.generate(
        "settings_version" => 1, "default_model" => MODEL, "webui_access" => "nexus", "plugins" => {
          "rho.browser" => { "enabled" => true },
          "rho.images" => { "configuration" => { "model" => "dev/mock-image" } },
          "rho.ingress_telegram" => { "enabled" => true, "configuration_version" => 1,
            "configuration" => { "connections" => { @connection_id => { "token" => "12345:synthetic-test-token" } }, "bots" => {} } },
        }
      ), perm: 0o600)
      @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home.root, tools_root: File.join(@root, "project"),
        env: { "RUBYOPT" => "-r#{File.expand_path("../../support/telegram_transport_prelude.rb", __dir__)}", "RHO_MODE" => "full" })
      @daemon.start
      E2E::Ceremony.confirm(actor: @ceremony, started: @daemon.start_ceremony, status: -> { @daemon.status })
      workspace_id = await("rho workspace adoption") do
        workspace = @daemon.status.fetch("workspace")
        workspace.fetch("public_id") if workspace.fetch("state") == "adopted"
      end
      @daemon.await_announced(address: "runner")
      connect_bridge(workspace_id)
      @workspace = @client.workspace(workspace_id)
      declare_telegram_bots(workspace_id)
      @telegram = E2E::TelegramClient.new
      @bot = E2E::TelegramClient::BOT.merge("id" => SecureRandom.random_number(1_000_000_000) + 1)
      @logs = []
      @memory = []
      @agent_memory = []
    end

    def teardown
      [[@human, @memory], [@client, @agent_memory]].each do |client, documents|
        documents&.each do |document|
          client.memory_collections.documents(document.collection_public_id).delete(document.path, expected_public_id: document.public_id,
            expected_lock_version: document.lock_version)
        end
      end
      unless passed? || !@daemon
        directory = File.expand_path("../../artifacts/rho_telegram/#{name}-#{Process.pid}", __dir__)
        FileUtils.mkdir_p(directory)
        File.write(File.join(directory, "failure.txt"), E2E::SecretHygiene.redact(failures.map(&:to_s).join("\n\n")))
        File.write(File.join(directory, "rho.log"), E2E::SecretHygiene.redact(@daemon.log_text))
        File.write(File.join(directory, "adapter.json"), E2E::SecretHygiene.redact(JSON.pretty_generate(@logs || [])))
        E2E::SecretHygiene.save_screenshot(@browser, File.join(directory, "failure.png")) if @browser
      end
    ensure
      @browser&.close
      @runtime&.close
      @bot_runtimes&.each_value(&:close)
      @daemon&.stop
      FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    end

    private

      def telegram_runner_route
        { "kind" => "runner", "runner_executor_public_id" => @daemon.status.fetch("identity").fetch("runner_executor_public_id") }
      end

      def telegram_group_tool_name(served_name, conversation_id:)
        agent_id = @core.conversation(conversation_id).fetch("metadata").fetch("rho_bot_public_id")
        profile = @client.profile.agents.list.find { |row| row.public_id == agent_id }
        assembly = telegram_group_assembly(profile, conversation_id: conversation_id)
        definition = assembly.tool_definitions.find do |entry|
          entry.dig("route", "tool_name") == served_name &&
            entry.dig("route", "runner_executor_public_id") == assembly.environment.fetch("default_runner_executor_public_id")
        end
        definition.fetch("function").fetch("name")
      end

      def telegram_group_assembly(profile, conversation_id:)
        runner = @workspace.conversation(conversation_id).fetch.default_runner&.executor_public_id
        configuration = profile.configuration.to_h.slice(:tool_definitions, :kernel_tools, :runner_executor_public_ids, :runner_tool_names).transform_keys(&:to_s)
        @client.tools.assemble(configuration: configuration, default_runner_executor_public_id: runner)
      end

      def open_console(conversation_id)
        output, status = @daemon.cli("console")
        assert_predicate status, :success?, E2E::SecretHygiene.redact(output)
        uri = URI(output[/^console:\s+(\S+)/, 1])
        assert_nil uri.fragment, "rho console opens its public login page"
        # The page's address is its path: the conversation in its workspace.
        uri.path = "/workspaces/#{@workspace.public_id}/conversations/#{conversation_id}"
        @browser = E2E::BrowserActor.new(uri.to_s)
        @browser.page.current_window.resize_to(1400, 1000)
        @browser.visit(uri.to_s)
        page = @browser.page
        E2E::DeviceAuthorizationBudget.consume
        page.click_button "Use a device code"
        @ceremony.visit(page.find_link("Open Nexus to approve")[:href])
        @ceremony.page.click_button "Continue"
        @ceremony.page.click_button "Connect", exact: true
        assert @ceremony.page.has_text?(/Connection ready|This connection is complete/)
        assert page.has_link?("Settings", exact: true, wait: E2E::RhoDaemon::WATCH_TIMEOUT), "the signed-in page is shown"
        assert_equal "/workspaces/#{@workspace.public_id}/conversations/#{conversation_id}", URI(page.current_url).path,
          "Nexus login retains the requested Telegram conversation and workspace"
      end

      def assert_bound_console(conversation_id)
        open_console(conversation_id)
        page = @browser.page
        assert page.has_text?("Telegram 101", wait: E2E::RhoDaemon::WATCH_TIMEOUT)
        assert page.has_text?("Telegram · Chat 101 — Continue in the original channel. This page is read-only. Stop remains available.")
        assert page.has_field?("Message", disabled: true)
        # Rename and Archive live in the conversation's actions menu, closed to a
        # bound conversation; stopping its work stays open there.
        page.click_button "Conversation actions"
        assert page.has_css?('[role="menuitem"][disabled]', text: "Rename", visible: :all, wait: E2E::RhoDaemon::WATCH_TIMEOUT), "Rename is closed"
        assert page.has_css?('[role="menuitem"][disabled]', text: "Archive", visible: :all), "Archive is closed"
        assert page.has_css?('[role="menuitem"]:not([disabled])', text: "Stop all work", visible: :all), "Stop remains available"
        page.find("body").send_keys(:escape)
        # The pending question's card stands where the composer would, and cannot be answered here.
        assert page.has_button?("Send answer", disabled: true), "the pending question cannot be answered here"
        directory = File.expand_path("../../artifacts/rho_telegram/#{name}-#{Process.pid}", __dir__)
        FileUtils.mkdir_p(directory)
        E2E::SecretHygiene.save_screenshot(@browser, File.join(directory, "ingress-desktop.png"))
        page.current_window.resize_to(390, 844)
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
          width: 390, height: 844, deviceScaleFactor: 1, mobile: false)
        assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 391
        E2E::SecretHygiene.save_screenshot(@browser, File.join(directory, "ingress-narrow.png"))
      end

      def assert_group_privacy(marker, skill)
        receive(update(3, "/observe on", chat: -10, topic: 7))
        receive(update(4, "A shared background fact", user: 102, chat: -10, topic: 7))
        observer = @workspace.conversation(current("-10:7"))
        refute_equal current("101:0"), observer.public_id
        observed = await("observed message") { observer.turns.list.items.first }
        assert_equal "message", observed.kind
        assert_equal "completed", observed.status
        assert_nil observed.active_variant.run_public_id
        assert_nil observed.active_variant.model
        assert_equal "A shared background fact", observed.active_variant.content
        assert_equal "ingress", observed.speaker.kind
        assert_equal @state.read.fetch("speakers").fetch("102"), observed.speaker.speaker_public_id
        assert_empty observer.events(limit: 100).select { |event| event.type == "task_status" }

        profile = @client.profile.agents.list.find { |row| row.public_id == bot_id_for("-10:7") }
        refute_nil profile, "the configured group Bot owns its answering identity"
        names = telegram_group_assembly(profile, conversation_id: observer.public_id).tool_definitions.map { |row| row.fetch("function").fetch("name") }
        assert_equal %w[memory_delete memory_edit memory_grep memory_ls memory_read memory_write], names.grep(/\Amemory_/).sort
        assert_empty profile.configuration.runner_executor_public_ids
        refute_includes names, "read"
        refute_includes names, "code"
        receive(update(5, "@rho_bot\n!mock reply=group-answer -- group question", chat: -10, topic: 7, mention: true))
        chat = @workspace.conversation(current("-10:7"))
        assert_equal observer.public_id, chat.public_id
        reply = completed_reply(chat)
        assert_equal profile.public_id, reply.speaker.user_public_id
        material = request_text(reply)
        assert_includes material, "A shared background fact"
        assert_includes material, @state.read.fetch("speakers").fetch("102")
        assert_includes material, @state.read.fetch("speakers").fetch("101")
        refute_includes material, marker
        refute_includes material, skill
        refute_includes material, "private question"
        await("group final delivery") { tick; @telegram.formal(-10).length == 1 }
        assert_equal 7, @telegram.formal(-10).first.last.fetch(:message_thread_id)
        assert_equal "Mock: group-answer", @telegram.formal(-10).first.last.fetch(:text)
      end

      def assert_supplementary_delivery(answer_id: 8, check_late_control: false, by_task_id: false)
        receive(update(6, "/new"))
        conversation_id = current("101:0")
        chat = @workspace.conversation(conversation_id)
        initial_sends = @telegram.formal(101).length
        command = CGI.escape(JSON.generate("command" => "printf telegram-background"))
        prompt = "!mock tool_call=bash:#{command} reply=telegram-background -- background work"
        background = CGI.escape(JSON.generate("prompt" => prompt, "lifetime" => "conversation", "wake" => "auto"))
        foreground = CGI.escape(JSON.generate("prompt" => "Finish the original answer?"))
        incoming = update(7, "!mock tool_call=delegate_task:#{background}&ask:#{foreground} reply=finished -- original answer")
        receive(incoming)
        question_id, question = await("the foreground Telegram question") do
          tick
          @state.read.fetch("questions").find do |_id, row|
            row.fetch("conversation_id") == conversation_id && row.fetch("kind") == "ask"
          end
        end
        loop_context = @workspace.runs.run(question.fetch("run_public_id"))
        early = await("the detached result before the original final") do
          tasks = loop_context.fetch.tasks
          call = tasks.find { |task| task.tool_name == "delegate_task" && task.status == "completed" }
          completed = call && loop_context.transcript(prefix: call.key).rounds.reverse.find { |round| round.status == "completed" }
          call if completed && loop_context.task(completed.task_key).output == "Mock: telegram-background"
        end
        assert loop_context.fetch.tasks.any? { |task| task.tool_name == "bash" && task.status == "completed" }
        original = chat.turns.list.items.find { |turn| turn.kind == "direct_reply" }
        assert_equal "running", original.status
        assert_empty chat.events(limit: 100).select { |event| event.type == "input_accepted" && event.payload["origin"] == "task_result" }
        assert_equal initial_sends, @telegram.formal(101).length
        yield(conversation_id, question_id) if block_given?
        receive(update(answer_id, "/answer #{question_id} Finish"))
        replies = await("two separate completed answers") do
          rows = chat.turns.list.items.select { |turn| turn.kind == "direct_reply" && turn.status == "completed" }
          rows if rows.length == 2
        end
        assert_equal 2, replies.map(&:public_id).uniq.length
        assert_equal 2, replies.map { |turn| turn.active_variant.run_public_id }.uniq.length
        assert_includes request_text(replies.last), "telegram-background"
        receipts = chat.events(limit: 100).select { |event| event.type == "input_accepted" && event.payload["origin"] == "task_result" }
        assert_equal [early.key], receipts.map { |event| event.payload.fetch("task_key") }
        await("separate original and supplementary Telegram messages") { tick; @telegram.formal(101).length == initial_sends + 2 }
        tick
        assert_equal initial_sends + 2, @telegram.formal(101).length
        document = @state.read
        request_key = document.fetch("messages").fetch("#{telegram_route_key("101:0")}:#{incoming.fetch("message").fetch("message_id")}")
        assert_equal original.active_variant.run_public_id, document.fetch("requests").fetch(request_key).fetch("run_id")
        delivered = @telegram.messages.select { |_id, params| params[:chat_id] == "101" && params[:parse_mode] == "HTML" }.keys.last(2)
        assert_equal [request_key, request_key], delivered.map { |id| document.fetch("messages").fetch("#{telegram_route_key("101:0")}:#{id}") }
        if check_late_control
          materialized = chat.events(limit: 100).find do |event|
            event.type == "input_materialized" && event.payload["turn_public_id"] == original.public_id
          end
          assert_supplementary_control(chat, delivered.last, task_id: materialized.payload.fetch("input_public_id"),
            loop_id: original.active_variant.run_public_id, by_task_id: by_task_id)
        end
        assert_empty @logs, "the adapter must not swallow a real wire failure"
      end

      def assert_supplementary_control(chat, message_id, task_id:, loop_id:, by_task_id:)
        # The stateless mock counts the earlier delegate_task/ask answers in history.
        following, turn, question_id, source = telegram_held_parent("supplementary-later", reply: "later-independent", prior_tool_answers: 2)
        assert_equal chat.public_id, following.public_id
        status = telegram_control("supplementary-task-status", "/status #{task_id}")
        assert_includes status, "Root execution: completed (#{loop_id})"
        refute_includes status, turn.active_variant.run_public_id
        # Each route makes the first Stop on its own completed execution. A
        # second Stop legitimately reports already_terminal, not a new acceptance.
        response = if by_task_id
          telegram_control("supplementary-task-stop", "/stop #{task_id}", reply_to: source)
        else
          message = { "message_id" => message_id, "from" => @bot.merge("is_bot" => true),
            "text" => @telegram.messages.fetch(message_id).fetch(:text) }
          telegram_control("supplementary-stop", "/stop", reply_to: message)
        end
        assert_includes response, "Stop requested"
        assert_equal "awaiting_input", telegram_question_task(turn).status
        telegram_control("supplementary-answer", "/answer #{question_id} Continue")
        await("the later independent turn survives Stop on an earlier supplementary answer") do
          tick
          following.turns.list.items.any? do |row|
            row.public_id == turn.public_id && row.status == "completed" && row.active_variant.content == "Mock: later-independent"
          end
        end
      ensure
        stop_group_work(following)
      end

      def telegram_state(route = @selected_route || "101:0")
        store = Rho::StoreDocument.new(store: -> { @client.profile.store_entries }, namespace: "rho.telegram", key: "bot:#{bot_id_for(route)}")
        Rho::IngressTelegram::State.new(store: store)
      end

      def connect_bridge(workspace_id)
        # The external adapter driver enters at the same connection boundary as
        # the production coordinator's member_connection callback.
        @daemon.await("the daemon restores its Agent connection before the Telegram driver starts") do
          @daemon.status.fetch("state") == "active"
        end
        @core = Rho::Core.new(home: @home)
        identity = @core.stored_identity(@core.stored_connection)
        # The daemon owns refresh. This short journey reads its current access token
        # without creating a second OAuth rotation owner.
        token = identity.vault.read.fetch("access_token")
        E2E::SecretHygiene.register(token)
        @client = CybrosAgent::Client.new(base_url: @base_url, credential: token)
        # The external adapter driver uses the same host store as the daemon's
        # Extension Host callback; it never invents or writes a workspace binding.
        hosts = Rho::HostStore.new(@home.host_cache_path(@client.profile.fetch.member.public_id))
        member_plane = ->(host_public_id: nil, workspace_public_id: nil, **) do
          selected = workspace_public_id || (host_public_id && hosts.find(host_public_id)&.workspace)
          Rho::Extensions::MemberPlane.new(client: @client, workspace_public_id: selected || workspace_id)
        end
        @telegram_host = Host.new(home: @home, member_plane: member_plane)
      end

      def telegram_bot_targets
        { "101:0" => [101, "owner"], "102:0" => [101, "external"], "-10:7" => [101, "external"], "-10:8" => [101, "external"] }
      end

      def declare_telegram_bots(workspace_id)
        @bot_ids = {}
        @bot_settings = {}
        telegram_bot_targets.each do |route, (owner, audience)|
          chat, topic = route.split(":").map(&:to_i)
          result = @daemon.control(:put, "/agents", body: {
            name: "telegram-#{route.tr(":-", "_")}", display_name: "Telegram #{route}",
            description: "Answers the configured Telegram destination.", audience: audience,
          })
          id = result.fetch("agent").fetch("public_id")
          @bot_ids[route] = id
          @daemon.control(:put, "/agents/settings", body: { agent_public_id: id, home_workspace_public_id: workspace_id })
          settings = { "enabled" => true, "connection_public_id" => @connection_id, "owner_id" => owner,
            "target" => { "chat_id" => chat, "topic_id" => (topic unless topic.zero?) } }
          configured = @daemon.control(:post, "/telegram/configuration", body: settings.merge("agent_public_id" => id))
          assert configured["saved"], configured.inspect
          if chat.negative?
            @daemon.await("the group Bot's access settings become available") do
              @daemon.control(:get, "/telegram?#{URI.encode_www_form(agent_public_id: id)}")["access"]
            end
            access = @daemon.control(:post, "/telegram/access", body: { agent_public_id: id, list: "allowed_chats", action: "add", id: chat })
            assert_includes access.fetch("access").fetch("allowed_chats"), chat.to_s
          end
          @bot_settings[route] = settings
        end
      end

      def boot_runtime(allowed:, clock: -> { Time.now.to_f }, **options)
        @runtime&.close
        @bot_runtimes&.each_value(&:close)
        log = Object.new
        logs = @logs
        log.define_singleton_method(:warn) { |event, **fields| logs << [event, fields] }
        @states, @bridges = {}, {}
        @bot_runtimes = @bot_ids.to_h do |route, id|
          settings = Rho::IngressTelegram::Settings.new(@bot_settings.fetch(route).merge(options.transform_keys(&:to_s)))
          @states[route] = telegram_state(route)
          @states.fetch(route).recover_deliveries
          @bridges[route] = E2E::TelegramLostAckBridge.new(host: @telegram_host, core: @core, agent_public_id: id)
          runtime = Rho::IngressTelegram::Runtime.new(settings: settings, state: @states.fetch(route), bridge: @bridges.fetch(route),
            client: @telegram, log: log, default_model: MODEL, agent_public_id: id, clock: clock)
          runtime.identify(@bot)
          [id, runtime]
        end
        connection_store = Rho::StoreDocument.new(store: -> { @client.profile.store_entries }, namespace: "rho.telegram", key: "connection:#{@connection_id}")
        @connection_state = Rho::IngressTelegram::ConnectionState.new(store: connection_store)
        @runtime = Rho::IngressTelegram::Connection.new(public_id: @connection_id, client: @telegram, state: @connection_state,
          bindings: -> { @bot_runtimes }, log: log, clock: clock)
        @runtime.identify(@bot)
        selected = @selected_route || @bot_ids.keys.first
        @telegram_bootstrapped_users ||= {}
        @bot_settings.each do |route, settings|
          bootstrapped = @telegram_bootstrapped_users[route] ||= [settings.fetch("owner_id")]
          chat, topic = route.split(":").map(&:to_i)
          (allowed - bootstrapped).each do |user|
            receive(update(["allow-user", route, user], "/access users add #{user}", user: settings.fetch("owner_id"),
              chat: chat, topic: (topic unless topic.zero?)))
            bootstrapped << user
          end
        end
        select_bot(selected)
      end

      def bot_id_for(route) = @bot_ids.fetch(route)
      def state_for(route) = @states.fetch(route)
      def bridge_for(route) = @bridges.fetch(route)

      def select_bot(route)
        @selected_route = route
        @state = state_for(route)
        @bridge = bridge_for(route)
      end

      def pending_input(incoming)
        @state.read.fetch("pending_inputs").values.find { |row| row.fetch("update_id") == incoming.fetch("update_id") }
      end

      def update(id, text, user: 101, chat: 101, topic: nil, mention: false)
        @telegram_update_ids ||= {}
        @telegram_update_sequence ||= 10_000
        actual_id = @telegram_update_ids[id] ||= (@telegram_update_sequence += 1)
        message = { "message_id" => actual_id, "date" => Time.now.to_i, "text" => text,
          "from" => { "id" => user, "first_name" => user == 101 ? "External Ada" : "External Bob" },
          "chat" => { "id" => chat, "type" => chat.positive? ? "private" : "supergroup" } }
        message["message_thread_id"] = topic if topic
        message["is_topic_message"] = true if topic
        message["entities"] = [{ "type" => "mention", "offset" => 0, "length" => 8 }] if mention
        { "update_id" => actual_id, "message" => message }
      end

      def telegram_route_key(route, user: nil) = "#{@connection_id}:#{route}"

      def current(route, user: nil)
        selected = @core.bot_detail(agent_public_id: bot_id_for(route))["current"]
        unless selected
          state = state_for(route).read.slice("access", "pending_update", "pending_inputs", "routes")
          flunk "No Telegram conversation for #{route}: #{state.inspect}; connection=#{@connection_state.read.inspect}; calls=#{@telegram.calls.last(10).inspect}"
        end
        selected.fetch("public_id")
      end

      def tick = @bot_runtimes.each_value(&:tick)

      # Separate controls cross the quiet window; burst/media tests drive the
      # real shared Connection directly to retain their admission timing.
      def receive(incoming)
        update = Rho::IngressTelegram::Update.new(incoming)
        route = "#{update.chat_id}:#{update.topic_id || 0}"
        select_bot(route) if @bot_ids.key?(route)
        @runtime.consume(incoming)
        row = pending_input(incoming)
        return unless row && !row["media"]

        sleep [row.fetch("ready_at") - Time.now.to_f + 0.05, 0].max
        tick
      end

      def completed_reply(chat)
        await("completed reply") do
          rows = chat.turns.list.items
          failed = rows.find { |turn| turn.status == "failed" }
          flunk "Turn failed: #{failed.to_h.inspect}" if failed
          rows.find { |turn| turn.kind == "direct_reply" && turn.status == "completed" }
        end
      end

      def request_text(turn)
        request = @workspace.runs.run(turn.active_variant.run_public_id).tasks_context("r1").request
        request.entries.flat_map { |entry| entry.fetch("parts", []).filter_map { |part| part["text"] } }.join("\n")
      end

      def successful_tool_output(turn, name)
        context = @workspace.runs.run(turn.active_variant.run_public_id)
        tasks = context.fetch.tasks.select { |task| task.tool_name == name }
        assert_equal 1, tasks.length, "the model must call #{name} exactly once in this turn"
        task = tasks.fetch(0)
        assert_equal "completed", task.status, task.to_h.inspect
        refute task.result&.fetch("is_error", false), task.to_h.inspect
        context.task(task.key).output
      end

      def await(message)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + E2E::RhoDaemon::WATCH_TIMEOUT
        loop do
          result = yield
          return result if result
          flunk "Timed out: #{message}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 1
        end
      end
  end
end
