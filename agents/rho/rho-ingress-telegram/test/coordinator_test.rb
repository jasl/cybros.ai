require "test_helper"
require_relative "support/runtime"

class TelegramCoordinatorTest < Minitest::Test
  BOT = "019a0000-0000-7000-8000-000000000001"
  NAMED_BOT = "019a0000-0000-7000-8000-000000000002"
  CONNECTION = "019a0000-0000-7000-8000-000000000003"
  NAMED_CONNECTION = "019a0000-0000-7000-8000-000000000004"
  Profile = Data.define(:store_entries)
  MemberClient = Data.define(:profile)

  class Client < TelegramRuntimeSupport::Client
    attr_reader :polls

    def initialize(number:, events:, identity: 42)
      super()
      @number, @events = number, events
      @identity = identity
      @polls, @release = Thread::Queue.new, Thread::Queue.new
      @events << [:created, @number, Thread.current]
    end

    def call(method, params = {}, poll: false)
      if method == "getUpdates"
        @polls.push(params)
        begin
          @release.pop
        ensure
          @events << [:poll_retired, @number, Thread.current]
        end
        []
      else
        @events << [:identified, @number, Thread.current] if method == "getMe"
        answer = super
        method == "getMe" ? answer.merge("id" => @identity) : answer
      end
    end

    def close
      unless @closed
        @closed = true
        @events << [:closed, @number, Thread.current]
        @release.close
      end
    end
  end

  def setup
    @directory = Dir.mktmpdir("rho-telegram-coordinator")
    @events, @clients = [], []
    @store_a, @store_b = TelegramStateSupport::Store.new, TelegramStateSupport::Store.new
    @bridge = TelegramRuntimeSupport::Bridge.new
    config = Rho::Config.from_hash({ "mode" => "agent", "plugins" => { Rho::IngressTelegram::NAME => {
      "enabled" => true, "configuration" => {
        "connections" => { CONNECTION => { "token" => "synthetic-coordinator-token" } },
        "bots" => { BOT => { "enabled" => true, "connection_public_id" => CONNECTION, "target" => { "chat_id" => "1" }, "owner_id" => "1" } },
      },
    } } })
    home = Rho::Home.resolve(base_url: "https://nexus.example", root: @directory)
    logger = Object.new
    logger.define_singleton_method(:warn) { |*| }
    @host = Rho::Extensions::Host.new(home: home, config: Rho::Config::Current.new(config), log: logger,
      clock: -> { Time.now }, processes: nil, serving_tools: true,
      member_plane: ->(**) { raise "Telegram state must use the captured connection" })
    result = Rho::Runner::Extensions::Loader.call(gems: ["rho/ingress-telegram"], api_class: Rho::Extensions::Api,
        api_options: { host: @host })
      assert_predicate result, :ok?, result.failures.inspect
    @api = result.committed.fetch(0)
    @connection_hook = @api.daemon_hooks.find { |hook| hook.event == :member_connection }.handler
    @binding_hook = @api.daemon_hooks.find { |hook| hook.event == :conversation_binding }.handler
    @shutdown = @api.lifecycle.find { |hook| hook.event == :shutdown }.handler
  end

  def teardown
    @shutdown&.call
    FileUtils.remove_entry(@directory)
  end

  def test_boot_connection_can_arrive_before_the_background_worker
    seed(@store_a, { "bot_id" => "42", "offset" => 100 })
    connect(@store_a, "profile-a")
    assert_empty @clients
    assert_equal "starting", status.fetch("connection")

    with_worker do
      assert_equal 100, @clients.fetch(0).polls.pop.fetch(:offset)
      assert_equal "running", status.fetch("connection")
      assert_equal 42, connection_status.dig("bot", "id")
    end
  end

  def test_profile_switch_retires_the_worker_and_keeps_old_state_out_of_the_new_profile
    seed(@store_a, { "bot_id" => "42", "offset" => 100 })
    bot_state(@store_a).change { |document| document["routes"] = { "#{CONNECTION}:-10:4" => route("conversation-a") } }
    with_worker do
      connect(@store_a, "profile-a")
      assert_equal 100, @clients.fetch(0).polls.pop.fetch(:offset)
      assert_equal "Telegram · Chat -10 · Topic 4", @binding_hook.call("conversation-a").fetch("label")
      change(@store_a) do |document|
        document["pending_update"] = { "update" => { "update_id" => 101 } }
      end
      bot_state(@store_a).change do |document|
        document["deliveries"]["old"] = { "status" => "pending", "text" => "Profile A only" }
      end
      original = value(@store_a)
      original_bot = bot_state(@store_a).read
      @connection_hook.call(nil)
      assert_equal "waiting_for_nexus", status.fetch("connection")
      assert_nil @binding_hook.call("conversation-a")
      refute status.key?("offset")

      connect(@store_b, "profile-b")
      refute @clients.fetch(1).polls.pop.key?(:offset)
      assert_nil @binding_hook.call("conversation-a")
      assert_equal original, value(@store_a)
      assert_equal original_bot, bot_state(@store_a).read
      current = value(@store_b)
      assert_nil current["offset"]
      assert_nil current["pending_update"]
      assert_empty bot_state(@store_b).read.fetch("routes")
      assert_empty bot_state(@store_b).read.fetch("deliveries")
      assert_empty Dir.children(@directory)
      assert_equal [[:created, 0], [:identified, 0], [:closed, 0], [:poll_retired, 0], [:created, 1], [:identified, 1]],
        @events.map { |kind, number, _thread| [kind, number] }
    end
  end

  def test_same_profile_reconnect_reloads_database_and_reidentifies_the_bot
    seed(@store_a, { "bot_id" => "42", "offset" => 100 })
    with_worker do
      connect(@store_a, "profile-a")
      assert_equal 100, @clients.fetch(0).polls.pop.fetch(:offset)
      @connection_hook.call(nil)
      change(@store_a) { |document| document["offset"] = 200 }

      connect(@store_a, "profile-a")
      assert_equal 200, @clients.fetch(1).polls.pop.fetch(:offset)
      assert_equal 200, connection_status.fetch("offset")
      assert_equal 2, @events.count { |kind, _number, _thread| kind == :identified }
    end
  end

  def test_disconnect_waits_for_the_in_flight_follower_before_starting_a_replacement
    entered, release = Thread::Queue.new, Thread::Queue.new
    cleanup_started, finish_cleanup = Thread::Queue.new, Thread::Queue.new
    events = @events
    @bridge.define_singleton_method(:runs) do
      if events.none? { |kind, _number, _thread| kind == :follower_retired }
        entered.push(true)
        begin
          release.pop
        ensure
          Async::Task.current.defer_stop do
            cleanup_started.push(true)
            finish_cleanup.pop
            events << [:follower_retired, 0, Thread.current]
          end
        end
      end
      {}
    end
    with_worker do |task|
      connect(@store_a, "profile-a")
      entered.pop
      @clients.fetch(0).polls.pop
      disconnected = false
      retiring = task.async { @connection_hook.call(nil); disconnected = true }
      cleanup_started.pop
      begin
        refute disconnected
        replacing = task.async { connect(@store_b, "profile-b") }
        assert_equal 1, @clients.length
      ensure
        finish_cleanup.push(true)
      end
      retiring.wait
      replacing.wait
      assert_includes @events.map(&:first), :follower_retired
      old_calls = @clients.fetch(0).calls.dup
      @clients.fetch(1).polls.pop
      task.yield
      assert_equal old_calls, @clients.fetch(0).calls
      kinds = @events.map { |kind, number, _thread| [kind, number] }
      assert_operator kinds.index([:follower_retired, 0]), :<, kinds.index([:created, 1])
      assert_operator kinds.index([:poll_retired, 0]), :<, kinds.index([:created, 1])
    end
  end

  def test_switch_to_a_profile_bound_to_another_bot_refuses_without_mutating_either_profile
    seed(@store_a, { "bot_id" => "42", "offset" => 100 })
    seed(@store_b, { "bot_id" => "99", "offset" => 10 })
    with_worker do |task|
      connect(@store_a, "profile-a")
      @clients.fetch(0).polls.pop
      original_a, original_b = value(@store_a), value(@store_b)

      connect(@store_b, "profile-b")
      task.yield
      assert_equal "configuration_error", status.fetch("connection")
      assert_equal "99", value(@store_b).fetch("bot_id")
      assert_equal 10, connection_status.fetch("offset")
      assert_empty @clients.fetch(1).polls
      assert_equal original_a, value(@store_a)
      assert_equal original_b, value(@store_b)
      assert_equal [:closed, 1], @events.last.take(2)
    end
  end

  def test_shutdown_from_another_thread_retires_on_the_worker_reactor
    connect(@store_a, "profile-a")
    ready = Thread::Queue.new
    with_clients do
      thread = Thread.new do
        Async do |task|
          worker = task.async { @api.background_tasks.fetch(0).handler.call }
          @clients.fetch(0).polls.pop
          ready.push(true)
          worker.wait
        end.wait
      end
      ready.pop
      @shutdown.call
      thread.join
      assert_equal "stopped", status.fetch("connection")
      assert_nil @binding_hook.call("conversation-a")
      assert_equal thread, @events.find { |kind, _number, _owner| kind == :closed }.last
    ensure
      thread&.kill
      thread&.join
    end
  end

  def test_live_settings_keep_the_poller_and_profile_state
    seed(@store_a, { "bot_id" => "42", "offset" => 100 })
    with_worker do
      connect(@store_a, "profile-a")
      @clients.fetch(0).polls.pop
      configure(configuration: { "owner_id" => "7", "stale_after" => 30, "input_debounce_seconds" => 0 })
      assert_equal 1, @clients.length
      assert_equal "7", status.dig("configuration", "owner_id")
      assert_equal 30, status.dig("configuration", "stale_after")
      assert_equal 0, status.dig("configuration", "input_debounce_seconds")
      assert_equal 100, connection_status.fetch("offset")
      assert_equal "running", status.fetch("connection")
      assert_empty @events.select { |kind, _number, _thread| kind == :closed }
    end
  end

  def test_disable_preserves_access_and_reenable_uses_the_latest_connection
    seed(@store_a, { "bot_id" => "42", "offset" => 100 })
    with_worker do
      connect(@store_a, "profile-a")
      @clients.fetch(0).polls.pop
      configure(enabled: false)
      assert_equal "disabled", status.fetch("connection")
      assert_equal 100, connection_status.fetch("offset")
      refute status.fetch("plugin_enabled")
      route = @api.routes.find { |row| row.path == "/telegram/access" }
      response = route.handler.call(request("agent_public_id" => BOT, "list" => "allowed_users", "action" => "add", "id" => "7"), context)
      assert_equal 200, response.first
      assert_equal ["7"], response.last.dig("access", "allowed_users")
      configure(enabled: true)
      assert_equal 100, @clients.fetch(1).polls.pop.fetch(:offset)
      assert_equal ["7"], status.dig("access", "allowed_users")
      events = @events.map { |kind, number, _thread| [kind, number] }
      assert_operator events.index([:poll_retired, 0]), :<, events.index([:created, 1])
    end
  end

  def test_replacing_token_retires_the_old_poller_before_starting_another
    seed(@store_a, { "bot_id" => "42", "offset" => 100 })
    with_worker do
      connect(@store_a, "profile-a")
      @clients.fetch(0).polls.pop
      configure_connections(CONNECTION => { "token" => "replacement" })
      assert_equal 100, @clients.fetch(1).polls.pop.fetch(:offset)
      assert connection_status.dig("token", "present")
      events = @events.map { |kind, number, _thread| [kind, number] }
      assert_operator events.index([:poll_retired, 0]), :<, events.index([:created, 1])
    end
  end

  def test_idle_worker_allows_first_enable_without_restarting_the_daemon
    configure(enabled: false)
    seed(@store_a, { "bot_id" => "42", "offset" => 100 })
    with_worker do
      connect(@store_a, "profile-a")
      assert_empty @clients
      assert_equal "disabled", status.fetch("connection")
      configure(enabled: true)
      assert_equal 100, @clients.fetch(0).polls.pop.fetch(:offset)
      assert_equal "running", status.fetch("connection")
    end
  end

  def test_identity_binding_error_names_the_connection_owner
    seed(@store_a, { "bot_id" => "99" })
    state = Rho::IngressTelegram::ConnectionState.new(store: document(@store_a))
    error = assert_raises(Rho::ConfigurationError) { state.bind(42) }
    assert_equal "telegram: this Connection is bound to another physical bot", error.message
  end

  def test_each_connection_uses_its_own_offset_and_disabling_one_keeps_the_other_polling
    @token_identities = { "named-token" => 99 }
    configure_bindings(connections: { CONNECTION => { "token" => "rho-token" }, NAMED_CONNECTION => { "token" => "named-token" } },
      bots: { BOT => bot_settings, NAMED_BOT => bot_settings(connection: NAMED_CONNECTION, owner: "2") })
    seed(@store_a, { "bot_id" => "42", "offset" => 100 })
    seed(@store_a, { "bot_id" => "99", "offset" => 700 }, key: "connection:#{NAMED_CONNECTION}")
    with_worker do
      connect(@store_a, "profile-a")
      assert_equal 100, @clients.fetch(0).polls.pop.fetch(:offset)
      assert_equal 700, @clients.fetch(1).polls.pop.fetch(:offset)
      assert_equal "1", status.dig("configuration", "owner_id")
      assert_equal "2", status(agent_public_id: NAMED_BOT).dig("configuration", "owner_id")
      assert_nil status(agent_public_id: NAMED_BOT).fetch("access")
      configure_connections(CONNECTION => { "token" => "rho-token" }, NAMED_CONNECTION => { "enabled" => false, "token" => "named-token" })
      assert_equal "running", status.fetch("connection")
      assert_equal "disabled", status(agent_public_id: NAMED_BOT).fetch("connection")
      assert_equal 700, connection_status(NAMED_CONNECTION).fetch("offset")
      refute_includes @events.map { |kind, number, _| [kind, number] }, [:closed, 0]
      assert_includes @events.map { |kind, number, _| [kind, number] }, [:poll_retired, 1]
      configure_connections(CONNECTION => { "token" => "rho-token" }, NAMED_CONNECTION => { "token" => "named-token" })
      assert_equal 700, @clients.fetch(2).polls.pop.fetch(:offset)
      assert_equal 100, connection_status.fetch("offset")
      assert_equal %W[connection:#{CONNECTION} connection:#{NAMED_CONNECTION} bot:#{BOT} bot:#{NAMED_BOT}], @store_a.rows.values.map(&:key)
    end
  end

  def test_different_tokens_for_the_same_physical_bot_never_start_two_pollers
    configure_bindings(connections: { CONNECTION => { "token" => "rho-token" }, NAMED_CONNECTION => { "token" => "rotated-same-bot-token" } },
      bots: { BOT => bot_settings, NAMED_BOT => bot_settings(connection: NAMED_CONNECTION) })
    with_worker do |task|
      connect(@store_a, "profile-a")
      @clients.fetch(0).polls.pop
      task.yield
      assert_equal "running", status.fetch("connection")
      assert_equal "configuration_error", status(agent_public_id: NAMED_BOT).fetch("connection")
      assert_empty @clients.fetch(1).polls
      assert_nil connection_status(NAMED_CONNECTION)["bot"]
      assert_empty value(@store_a, key: "connection:#{NAMED_CONNECTION}")
      assert_equal "42", value(@store_a).fetch("bot_id")
    end
  end

  def test_removing_a_conflicting_binding_restarts_its_previously_refused_worker
    configure_bindings(connections: { CONNECTION => { "token" => "rho-token" }, NAMED_CONNECTION => { "token" => "rotated-same-bot-token" } },
      bots: { BOT => bot_settings, NAMED_BOT => bot_settings(connection: NAMED_CONNECTION) })
    with_worker do |task|
      connect(@store_a, "profile-a")
      @clients.fetch(0).polls.pop
      task.yield
      assert_equal "configuration_error", status(agent_public_id: NAMED_BOT).fetch("connection")
      assert_empty @clients.fetch(1).polls

      configure_bindings(connections: { NAMED_CONNECTION => { "token" => "rotated-same-bot-token" } },
        bots: { NAMED_BOT => bot_settings(connection: NAMED_CONNECTION) })
      task.yield
      assert_equal "running", status(agent_public_id: NAMED_BOT).fetch("connection")
      refute @clients.fetch(2).polls.pop.key?(:offset)
      events = @events.map { |kind, number, _thread| [kind, number] }
      assert_operator events.index([:poll_retired, 0]), :<, events.index([:identified, 2])
      assert_operator events.index([:closed, 1]), :<, events.index([:created, 2])
    end
  end

  def test_a_rejected_state_binding_cannot_claim_another_workers_identity_during_store_io
    @token_identities = { "wrong-rho-token" => 43, "named-token" => 43 }
    configure_bindings(connections: { CONNECTION => { "token" => "wrong-rho-token" }, NAMED_CONNECTION => { "token" => "named-token" } },
      bots: { BOT => bot_settings, NAMED_BOT => bot_settings(connection: NAMED_CONNECTION) })
    seed(@store_a, { "bot_id" => "42", "offset" => 100 })
    original = value(@store_a)
    entered, release = Thread::Queue.new, Thread::Queue.new
    fetch = @store_a.method(:fetch)
    connection_key = "connection:#{CONNECTION}"
    blocked = false
    @store_a.define_singleton_method(:fetch) do |id|
      row = fetch.call(id)
      if row.key == connection_key && !blocked
        blocked = true
        entered.push(true)
        release.pop
      end
      row
    end
    with_worker do |task|
      begin
        connecting = task.async { connect(@store_a, "profile-a") }
        entered.pop
        task.yield
        @clients.fetch(1).polls.pop
        assert_equal "running", status(agent_public_id: NAMED_BOT).fetch("connection")
      ensure
        release.push(true)
      end
      connecting.wait
      task.yield
      assert_equal "configuration_error", status.fetch("connection")
      assert_equal "42", value(@store_a).fetch("bot_id")
      assert_empty @clients.fetch(0).polls
      assert_equal original, value(@store_a)
      assert_equal 43, connection_status(NAMED_CONNECTION).dig("bot", "id")
    end
  end

  private

    def configure(configuration: {}, enabled: @host.config.plugin_enabled?(Rho::IngressTelegram::NAME))
      id = Rho::IngressTelegram::NAME
      document = @host.config.plugin_configuration(id)
      values = document.fetch("bots").fetch(BOT).merge(configuration)
      @host.config.apply(Rho::Config.from_hash(@host.config.to_h.merge("plugins" => {
        id => { "enabled" => enabled, "configuration" => document.merge("bots" => { BOT => values }) },
      })))
      @api.daemon_hooks.find { |hook| hook.event == :configuration_change }.handler.call(@host.config)
    end

    def configure_bindings(connections:, bots:)
      id = Rho::IngressTelegram::NAME
      @host.config.apply(Rho::Config.from_hash(@host.config.to_h.merge("plugins" => {
        id => { "enabled" => true, "configuration" => { "connections" => connections, "bots" => bots } },
      })))
      @api.daemon_hooks.find { |hook| hook.event == :configuration_change }.handler.call(@host.config)
    end

    def configure_connections(connections)
      configure_bindings(connections: connections, bots: @host.config.plugin_configuration(Rho::IngressTelegram::NAME).fetch("bots"))
    end

    def bot_settings(connection: CONNECTION, owner: "1")
      { "enabled" => true, "connection_public_id" => connection, "owner_id" => owner, "target" => { "chat_id" => owner } }
    end

    def request(body)
      Protocol::HTTP::Request["POST", "/telegram/access", { "content-type" => "application/json" }, [JSON.generate(body)]]
    end

    def with_worker
      with_clients do
        Async do |task|
          task.with_timeout(3) do
            worker = task.async { @api.background_tasks.fetch(0).handler.call }
            yield task
          ensure
            @shutdown.call
            worker&.wait
          end
        end.wait
      end
    end

    def with_clients(&block)
      factory = ->(token:, **) {
        Client.new(number: @clients.length, events: @events, identity: (@token_identities || {}).fetch(token, 42))
          .tap { |client| @clients << client }
      }
      with_constructor(Rho::IngressTelegram::Client, factory) do
        with_constructor(Rho::IngressTelegram::Bridge, ->(**) { @bridge }, &block)
      end
    end

    def with_constructor(type, factory)
      singleton = type.singleton_class
      owned = singleton.instance_methods(false).include?(:new)
      original = type.method(:new)
      singleton.remove_method(:new) if owned
      type.define_singleton_method(:new) { |*arguments, **options| factory.call(*arguments, **options) }
      yield
    ensure
      singleton.remove_method(:new)
      type.define_singleton_method(:new, original) if owned
    end

    def connect(store, id)
      @connection_hook.call(Rho::Extensions::MemberConnection.new(user_public_id: id,
        client: MemberClient.new(profile: Profile.new(store_entries: store))))
    end

    def context
      context = Object.new
      context.define_singleton_method(:list_named_definitions) do
        { bots: [{ public_id: BOT, home_workspace_public_id: "workspace", audience: "external" },
                 { public_id: NAMED_BOT, home_workspace_public_id: "workspace", audience: "owner" }] }
      end
      context
    end

    def status(agent_public_id: BOT)
      request = Protocol::HTTP::Request["GET", "/telegram?agent_public_id=#{agent_public_id}"]
      @api.routes.fetch(0).handler.call(request, context).last
    end

    def connection_status(id = CONNECTION)
      request = Protocol::HTTP::Request["GET", "/telegram/connection?connection_public_id=#{id}"]
      @api.routes.find { |row| row.path == "/telegram/connection" && row.method == "GET" }.handler.call(request, nil).last.fetch("connection")
    end

    def value(store, key: "connection:#{CONNECTION}") = document(store, key: key).read.to_h
    def document(store, key: "connection:#{CONNECTION}") = Rho::StoreDocument.new(store: -> { store }, namespace: "rho.telegram", key: key)
    def seed(store, attributes, key: "connection:#{CONNECTION}") = Rho::IngressTelegram::ConnectionState.new(store: document(store, key: key)).change { |held| held.merge!(attributes) }
    def bot_state(store, agent: BOT) = Rho::IngressTelegram::State.new(store: document(store, key: "bot:#{agent}"))
    def change(store, &block) = document(store).change(&block)

    def route(conversation_id)
      { "chat_id" => "-10", "topic_id" => 4, "group" => true, "owner_id" => "1", "current" => conversation_id,
        "connection_public_id" => CONNECTION, "conversations" => { conversation_id => { "position" => nil, "workspace_public_id" => "workspace" } } }
    end
end
