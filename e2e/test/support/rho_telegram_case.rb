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
      File.write(File.join(@home.root, "settings.json"), JSON.generate(
        "extensions" => ["rho/ingress-telegram", "rho/browser"], "default_model" => MODEL, "compose" => "on",
        "image_model" => "dev/mock-image",
        "telegram" => { "token_env" => "E2E_TELEGRAM_TOKEN", "owner_id" => 101 }
      ))
      @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home.root, tools_root: File.join(@root, "project"),
        env: { "RUBYOPT" => "-r#{File.expand_path("../../support/telegram_transport_prelude.rb", __dir__)}",
               "E2E_TELEGRAM_TOKEN" => "12345:synthetic-test-token", "RHO_MODE" => "full" })
      @daemon.start
      E2E::Ceremony.confirm(actor: @ceremony, started: @daemon.start_ceremony, status: -> { @daemon.status })
      workspace_id = await("rho workspace adoption") do
        workspace = @daemon.status.fetch("workspace")
        workspace.fetch("public_id") if workspace.fetch("state") == "adopted"
      end
      @daemon.await_announced(address: "runner")
      connect_bridge(workspace_id)
      await("the Telegram group profile is declared") { @client.profile.agents.list.any? { |agent| agent.name == "telegram-group" } }
      @workspace = @client.workspace(workspace_id)
      @state = telegram_state
      @telegram = E2E::TelegramClient.new
      @bot = E2E::TelegramClient::BOT.merge("id" => SecureRandom.random_number(1_000_000_000) + 1)
      @logs = []
      @memory = []
    end

    def teardown
      @memory&.each do |document|
        @human.profile.memory.delete(document.path, expected_public_id: document.public_id,
          expected_lock_version: document.lock_version)
      end
      unless passed? || !@daemon
        directory = File.expand_path("../../artifacts/rho_telegram/#{name}-#{Process.pid}", __dir__)
        FileUtils.mkdir_p(directory)
        File.write(File.join(directory, "rho.log"), E2E::SecretHygiene.redact(@daemon.log_text))
        File.write(File.join(directory, "adapter.json"), E2E::SecretHygiene.redact(JSON.pretty_generate(@logs || [])))
        E2E::SecretHygiene.save_screenshot(@browser, File.join(directory, "failure.png")) if @browser
      end
    ensure
      @browser&.close
      @runtime&.close
      @daemon&.stop
      FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    end

    private

      def open_console(conversation_id)
        output, status = @daemon.cli("console")
        assert_predicate status, :success?, E2E::SecretHygiene.redact(output)
        uri = URI(output[/^console:\s+(\S+)/, 1])
        E2E::SecretHygiene.register(uri.fragment.delete_prefix("code="))
        uri.query = URI.encode_www_form(conversation: conversation_id, workspace: @workspace.public_id)
        @browser = E2E::BrowserActor.new(uri.to_s)
        @browser.page.current_window.resize_to(1400, 1000)
        @browser.visit(uri.to_s)
      end

      def assert_bound_console(conversation_id)
        open_console(conversation_id)
        page = @browser.page
        assert page.has_text?("Telegram · Chat 101", wait: E2E::RhoDaemon::WATCH_TIMEOUT)
        assert page.has_field?("Message", disabled: true)
        assert page.has_button?("Rename", disabled: true)
        assert page.has_button?("Archive", disabled: true)
        assert page.has_button?("Send answer", disabled: true)
        assert page.has_button?("Stop", disabled: false)
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
        @runtime.consume(update(3, "/observe on", chat: -10, topic: 7))
        @runtime.consume(update(4, "A shared background fact", user: 102, chat: -10, topic: 7))
        observer = @workspace.conversation(@state.read.fetch("rooms").fetch("-10:7").fetch("conversation_id"))
        refute_equal current("101:0"), observer.public_id
        observed = await("observed message") { observer.turns.list.items.first }
        assert_equal "message", observed.kind
        assert_equal "completed", observed.status
        assert_nil observed.active_variant.agent_loop_public_id
        assert_nil observed.active_variant.model
        assert_equal "A shared background fact", observed.active_variant.content
        assert_equal "ingress", observed.speaker.kind
        assert_equal @state.read.fetch("speakers").fetch("102"), observed.speaker.actor_public_id
        assert_empty observer.events(limit: 100).select { |event| event.type == "task_status" }

        profile = @client.profile.agents.list.find { |row| row.name == "telegram-group" }
        refute_nil profile, "the real plugin declared its group answering profile"
        assert_equal Rho::IngressTelegram::GroupProfile::TEMPLATE, profile.configuration.prompt_template
        names = profile.configuration.tool_definitions.map { |row| row.fetch("function").fetch("name") }
        assert_equal %w[memory_delete memory_edit memory_grep memory_ls memory_read memory_write], names.grep(/\Amemory_/).sort
        refute names.any? { |name| name.start_with?("skill_", "conversation_") }
        @runtime.consume(update(5, "@rho_bot\n!mock reply=group-answer -- group question", chat: -10, topic: 7, mention: true))
        chat = @workspace.conversation(current("-10:7"))
        refute_equal observer.public_id, chat.public_id
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
        @runtime.consume(update(6, "/new"))
        conversation_id = current("101:0")
        chat = @workspace.conversation(conversation_id)
        initial_sends = @telegram.formal(101).length
        script = "g.tool({name: 'bash', input: {command: 'printf telegram-background'}, key: 'early'});"
        background = CGI.escape(JSON.generate("script" => script))
        foreground = CGI.escape(JSON.generate("prompt" => "Finish the original answer?"))
        incoming = update(7, "!mock tool_call=compose:#{background}&ask:#{foreground} reply=finished -- original answer")
        @runtime.consume(incoming)
        question_id, question = await("the foreground Telegram question") do
          tick
          @state.read.fetch("questions").find do |_id, row|
            row.fetch("conversation_id") == conversation_id && row.fetch("kind") == "ask"
          end
        end
        loop_context = @workspace.agent_loops.agent_loop(question.fetch("loop_public_id"))
        early = await("the detached result before the original final") do
          loop_context.fetch.tasks.find { |task| task.key.end_with?("-early") && task.status == "completed" }
        end
        original = chat.turns.list.items.find { |turn| turn.kind == "direct_reply" }
        assert_equal "running", original.status
        assert_empty chat.events(limit: 100).select { |event| event.type == "input_accepted" && event.payload["origin"] == "task_result" }
        assert_equal initial_sends, @telegram.formal(101).length
        yield(conversation_id, question_id) if block_given?
        @runtime.consume(update(answer_id, "/answer #{question_id} Finish"))
        replies = await("two separate completed answers") do
          rows = chat.turns.list.items.select { |turn| turn.kind == "direct_reply" && turn.status == "completed" }
          rows if rows.length == 2
        end
        assert_equal 2, replies.map(&:public_id).uniq.length
        assert_equal 2, replies.map { |turn| turn.active_variant.agent_loop_public_id }.uniq.length
        assert_includes request_text(replies.last), "telegram-background"
        receipts = chat.events(limit: 100).select { |event| event.type == "input_accepted" && event.payload["origin"] == "task_result" }
        assert_equal [early.key], receipts.map { |event| event.payload.fetch("task_key") }
        await("separate original and supplementary Telegram messages") { tick; @telegram.formal(101).length == initial_sends + 2 }
        tick
        assert_equal initial_sends + 2, @telegram.formal(101).length
        document = @state.read
        request_key = document.fetch("messages").fetch("101:0:#{incoming.fetch("message").fetch("message_id")}")
        assert_equal original.active_variant.agent_loop_public_id, document.fetch("requests").fetch(request_key).fetch("loop_id")
        delivered = @telegram.messages.select { |_id, params| params[:chat_id] == "101" && params[:parse_mode] == "HTML" }.keys.last(2)
        assert_equal [request_key, request_key], delivered.map { |id| document.fetch("messages").fetch("101:0:#{id}") }
        if check_late_control
          materialized = chat.events(limit: 100).find do |event|
            event.type == "input_materialized" && event.payload["turn_public_id"] == original.public_id
          end
          assert_supplementary_control(chat, delivered.last, task_id: materialized.payload.fetch("input_public_id"),
            loop_id: original.active_variant.agent_loop_public_id, by_task_id: by_task_id)
        end
        assert_empty @logs, "the adapter must not swallow a real wire failure"
      end

      def assert_supplementary_control(chat, message_id, task_id:, loop_id:, by_task_id:)
        # The stateless mock counts the earlier compose/ask answers in history.
        following, turn, question_id, source = telegram_held_parent("supplementary-later", reply: "later-independent", prior_tool_answers: 2)
        assert_equal chat.public_id, following.public_id
        status = telegram_control("supplementary-task-status", "/status #{task_id}")
        assert_includes status, "Root execution: completed (#{loop_id})"
        refute_includes status, turn.active_variant.agent_loop_public_id
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

      def telegram_state
        store = Rho::StoreDocument.new(store: -> { @client.profile.store_entries }, namespace: "rho.telegram", key: "state")
        Rho::IngressTelegram::State.new(store: store)
      end

      def connect_bridge(workspace_id)
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
        @bridge = E2E::TelegramLostAckBridge.new(host: Host.new(home: @home, member_plane: member_plane), core: @core)
      end

      def boot_runtime(allowed:, **options)
        @runtime&.close
        settings = Rho::IngressTelegram::Settings.new({ "owner_id" => 101 }.merge(options.transform_keys(&:to_s)),
          env: { "RHO_TELEGRAM_BOT_TOKEN" => "synthetic" })
        log = Object.new
        logs = @logs
        log.define_singleton_method(:warn) { |event, **fields| logs << [event, fields] }
        @runtime = Rho::IngressTelegram::Runtime.new(settings: settings, state: @state, bridge: @bridge,
          client: @telegram, log: log, default_model: MODEL)
        @runtime.identify(@bot)
        @telegram_bootstrapped_users ||= [101]
        @telegram_bootstrapped_chats ||= []
        (allowed - @telegram_bootstrapped_users).each do |user|
          @runtime.consume(update(["allow-user", user], "/access users add #{user}"))
          @telegram_bootstrapped_users << user
        end
        unless @telegram_bootstrapped_chats.include?(-10)
          @runtime.consume(update(["allow-chat", -10], "/access chats add -10"))
          @telegram_bootstrapped_chats << -10
        end
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

      def telegram_route_key(route, user: 101) = route.start_with?("-") ? "#{route}:#{user}" : route
      def current(route, user: 101)
        document = @state.read
        selected = document.fetch("routes")[telegram_route_key(route, user: user)]
        unless selected
          notices = document.fetch("deliveries").values.filter_map { |entry| entry["text"] if entry["plain"] }
          flunk "No Telegram conversation for #{route}, user #{user}. Notices: #{notices.inspect}"
        end
        selected.fetch("current")
      end
      def tick = @runtime.tick

      def completed_reply(chat)
        await("completed reply") do
          rows = chat.turns.list.items
          failed = rows.find { |turn| turn.status == "failed" }
          flunk "Turn failed: #{failed.to_h.inspect}" if failed
          rows.find { |turn| turn.kind == "direct_reply" && turn.status == "completed" }
        end
      end

      def request_text(turn)
        request = @workspace.agent_loops.agent_loop(turn.active_variant.agent_loop_public_id).tasks_context("r1").request
        request.entries.flat_map { |entry| entry.fetch("parts", []).filter_map { |part| part["text"] } }.join("\n")
      end

      def successful_tool_output(turn, name)
        context = @workspace.agent_loops.agent_loop(turn.active_variant.agent_loop_public_id)
        tasks = context.fetch.tasks.select { |task| task.tool_name == name }
        assert_equal 1, tasks.length, "the model must call #{name} exactly once in this turn"
        task = tasks.fetch(0)
        assert_equal "completed", task.status
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
