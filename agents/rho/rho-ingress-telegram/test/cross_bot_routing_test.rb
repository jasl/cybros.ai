require "support/runtime"

class TelegramCrossBotRoutingTest < Minitest::Test
  include TelegramRuntimeSupport

  TARGET = "019a0000-0000-7000-8000-000000000002"
  TARGET_CONNECTION = "019a0000-0000-7000-8000-000000000003"
  TASK = "019a0000-0000-7000-8000-000000000010"

  def setup
    super
    host = Struct.new(:config).new(Struct.new(:enabled) { def plugin_enabled?(_name) = enabled }.new(true))
    @settings = Rho::IngressTelegram::Settings.new(@settings.to_h.merge("target" => { "chat_id" => "1" }))
    @target_settings = Rho::IngressTelegram::Settings.new(@settings.to_h.merge("connection_public_id" => TARGET_CONNECTION, "input_debounce_seconds" => 0))
    @coordinator = Rho::IngressTelegram::Coordinator.new(host: host, settings: { BOT => @settings, TARGET => @target_settings },
      connections: { CONNECTION => Rho::IngressTelegram::ConnectionSettings.new({ "token" => "source-token" }),
                     TARGET_CONNECTION => Rho::IngressTelegram::ConnectionSettings.new({ "token" => "target-token" }) })
    @runtime = build_runtime(@state, @bridge, @client)
    @target_store = TelegramStateSupport::Store.new
    @target_state = Rho::IngressTelegram::State.new(store: Rho::StoreDocument.new(
      namespace: "rho.telegram", key: TARGET, store: -> { @target_store }))
    @target_bridge, @target_client = Bridge.new, Client.new
    @target_bridge.bot_audience = "external"
    @target_runtime = build_runtime(@target_state, @target_bridge, @target_client, agent: TARGET, identity: 43)
    bindings = @coordinator.instance_variable_get(:@bindings)
    bindings.fetch(BOT).state, bindings.fetch(BOT).runtime = @state, @runtime
    bindings.fetch(TARGET).state, bindings.fetch(TARGET).runtime = @target_state, @target_runtime
    transport(CONNECTION, @client, @connection_state, bindings, 42)
    target_connection_state = Rho::IngressTelegram::ConnectionState.new(store: TelegramStateSupport.document(@home, key: "target-connection"))
    transport(TARGET_CONNECTION, @target_client, target_connection_state, bindings, 43)
    @worker = { "public_id" => "child-turn", "input_public_id" => TASK, "position" => 0,
      "answering_user_public_id" => TARGET, "variant_public_id" => "child-variant", "run_public_id" => "child-loop",
      "kind" => "direct_reply", "status" => "completed", "sender_conversation_public_id" => "conversation-1",
      "sender_run_public_id" => "loop-1", "text" => "Independent child answer" }
    worker = @worker
    @bridge.define_singleton_method(:worker_request) { |*, **| worker }
    @bridge.define_singleton_method(:worker_result) { |*, **| worker }
    receive(telegram_message(1, "Delegate a request"))
  end

  def test_fast_worker_uses_target_identity_and_source_owned_receipt
    admit_target
    publish_result
    @runtime.tick

    assert_equal 1, sends(@target_client, "Independent child answer").length
    assert_empty sends(@client, "Independent child answer")
    assert_equal 1, sends(@client, "Parent report").length
    delivery = @state.read.fetch("deliveries").values.find { |row| row["destination_agent_public_id"] == TARGET }
    assert_equal "sent", delivery.fetch("status")
    assert_equal "1", delivery.fetch("destination_owner_id")
    assert_equal "1", delivery.fetch("chat_id")
    assert_empty @target_state.read.fetch("deliveries")
    assert @coordinator.delivered_copy?(TARGET, Rho::IngressTelegram::Update.new(
      telegram_message(2, "continue", reply_to: delivery.fetch("message_ids").first, reply_user: 43), connection_public_id: TARGET_CONNECTION))
  end

  def test_busy_worker_freezes_destination_and_target_revocation_prevents_send
    admit_target(user: 2)
    @state.change do |document|
      document.fetch("requests").fetch("telegram:#{BOT}:#{CONNECTION}:42:1:input")["owner_id"] = "2"
    end
    @bridge.current["children"] = [{ "public_id" => "child", "busy" => true }]
    @runtime.tick
    request = @state.read.fetch("requests").fetch("worker:#{TASK}")
    assert_equal "2", request.fetch("result_destination").fetch("destination_owner_id")
    @target_state.change { |document| document.fetch("access").fetch("allowed_users").delete("2") }
    publish_result
    @now += 60
    @runtime.tick

    assert_empty sends(@target_client, "Independent child answer")
    delivery = @state.read.fetch("deliveries").values.find { |row| row["destination_agent_public_id"] == TARGET }
    assert_equal "refused", delivery.fetch("status")
    assert_equal "destination_unavailable", delivery.fetch("error_code")
    assert_equal 1, sends(@client, "Parent report").length
  end

  def test_configured_but_unbound_target_reports_failure_without_source_substitution
    publish_result
    @runtime.tick
    @now += 60
    @runtime.tick

    assert_empty sends(@target_client, "Independent child answer")
    assert_empty sends(@client, "Independent child answer")
    assert_equal "destination_unavailable", @state.read.fetch("requests").fetch("worker:#{TASK}").fetch("delivery_error")
    assert_equal 1, sends(@client, "no available Telegram connection").length
    assert_equal 1, sends(@client, "Parent report").length
  end

  def test_worker_without_telegram_identity_uses_only_normal_parent_callback
    @worker["answering_user_public_id"] = "019a0000-0000-7000-8000-000000000099"
    publish_result
    @runtime.tick

    assert_empty @target_client.calls
    request = @state.read.fetch("requests").fetch("worker:#{TASK}")
    refute request.key?("result_destination")
    refute request.key?("delivery_error")
    assert_equal 1, sends(@client, "Parent report").length
  end

  def test_only_an_explicit_bot_binding_is_a_destination_and_same_bot_children_do_not_export
    main = "019a0000-0000-7000-8000-000000000099"
    route = @state.read.fetch("routes").fetch("#{CONNECTION}:1:0")
    assert_nil @coordinator.result_destination(agent_public_id: main, owner_id: "1", source_route: route)
    assert_nil @coordinator.result_destination(agent_public_id: BOT, owner_id: "1", source_route: route, source_agent_public_id: BOT)
    destination = @coordinator.result_destination(agent_public_id: BOT, owner_id: "1", source_route: route,
      source_agent_public_id: TARGET)
    assert_equal BOT, destination.fetch("destination_agent_public_id")
    assert_same @runtime.instance_variable_get(:@delivery), @coordinator.delivery_sender(destination)
  end

  private

    def build_runtime(state, bridge, client, agent: BOT, identity: 42)
      Rho::IngressTelegram::Runtime.new(settings: agent == BOT ? @settings : @target_settings, state: state, bridge: bridge,
        client: client, log: nil, clock: -> { @now }, agent_public_id: agent, coordinator: @coordinator)
        .tap { |runtime| runtime.identify("id" => identity, "username" => "rho_bot") }
    end

    def transport(id, client, state, bindings, identity)
      row = @coordinator.instance_variable_get(:@transports).fetch(id)
      row.state = state
      row.connection = Rho::IngressTelegram::Connection.new(public_id: id, client: client, state: state,
        bindings: -> { bindings.transform_values(&:runtime) }, log: nil, clock: -> { @now })
      row.connection.identify("id" => identity, "username" => "rho_bot")
    end

    def admit_target(user: 1)
      @target_state.change do |document|
        document.fetch("access").fetch("allowed_users") << user.to_s unless user == 1
      end
      # The target has already admitted a conversation in this same chat/topic.
      @target_runtime.consume(telegram_message(1, "Target's own conversation", user: user, chat: 1))
      @target_state.change { |document| document.fetch("deliveries").clear }
      @target_client.calls.clear
    end

    def publish_result
      source = { "input_public_id" => "callback", "sender_run_public_id" => "loop-1", "result" => {
        "conversation_public_id" => "child", "input_public_id" => TASK, "turn_public_id" => "child-turn",
        "variant_public_id" => "child-variant", "requester_speaker_public_id" => "speaker-1",
      } }
      @bridge.turn_rows["conversation-1"] = [turn(1, "Parent report").merge("input_public_id" => "callback",
        "run_public_id" => "report-loop", "callback_sources" => [source])]
      @bridge.current["sequence"] += 1
    end

    def sends(client, text)
      client.calls.select { |method, params| method == "sendMessage" && params.fetch(:text, "").include?(text) }
    end
end
