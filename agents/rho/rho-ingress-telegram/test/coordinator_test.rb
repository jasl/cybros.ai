require "test_helper"
require_relative "support/runtime"

class TelegramCoordinatorTest < Minitest::Test
  TOKEN_ENV = "RHO_TELEGRAM_COORDINATOR_TEST_TOKEN_#{Process.pid}".freeze
  Profile = Data.define(:store_entries)
  MemberClient = Data.define(:profile)

  class Client < TelegramRuntimeSupport::Client
    attr_reader :polls

    def initialize(number:, events:)
      super()
      @number, @events = number, events
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
        super
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
    ENV[TOKEN_ENV] = "synthetic-coordinator-token"
    @events, @clients = [], []
    @store_a, @store_b = TelegramStateSupport::Store.new, TelegramStateSupport::Store.new
    @bridge = TelegramRuntimeSupport::Bridge.new
    config = Rho::Config.from_hash({ "mode" => "agent", "plugins" => { Rho::IngressTelegram::NAME => {
      "enabled" => true, "configuration" => { "owner_id" => "1", "token_env" => TOKEN_ENV },
    } } })
    home = Rho::Home.resolve(base_url: "https://nexus.example", root: @directory)
    logger = Object.new
    logger.define_singleton_method(:warn) { |*| }
    @host = Rho::Extensions::Host.new(home: home, config: Rho::Config::Current.new(config), log: logger,
      clock: -> { Time.now }, processes: nil, serving_tools: true,
      member_plane: ->(**) { raise "Telegram state must use the captured connection" })
    settings = Rho::IngressTelegram::Settings.new(config.plugin_configuration(Rho::IngressTelegram::NAME),
      env: ENV)
    with_constructor(Rho::IngressTelegram::Settings, ->(*) { settings }) do
      result = Rho::Runner::Extensions::Loader.call(gems: ["rho/ingress-telegram"], api_class: Rho::Extensions::Api,
        api_options: { host: @host })
      assert_predicate result, :ok?, result.failures.inspect
      @api = result.committed.fetch(0)
    end
    @connection_hook = @api.daemon_hooks.find { |hook| hook.event == :member_connection }.handler
    @binding_hook = @api.daemon_hooks.find { |hook| hook.event == :conversation_binding }.handler
    @shutdown = @api.lifecycle.find { |hook| hook.event == :shutdown }.handler
  end

  def teardown
    @shutdown&.call
    ENV.delete(TOKEN_ENV)
    FileUtils.remove_entry(@directory)
  end

  def test_boot_connection_can_arrive_before_the_background_worker
    seed(@store_a, "bot_id" => "42", "offset" => 100)
    connect(@store_a, "profile-a")
    assert_empty @clients
    assert_equal "starting", status.fetch("connection")

    with_worker do
      assert_equal 100, @clients.fetch(0).polls.pop.fetch(:offset)
      assert_equal "running", status.fetch("connection")
      assert_equal "42", status.fetch("bot_id")
    end
  end

  def test_profile_switch_retires_the_worker_and_keeps_old_state_out_of_the_new_profile
    seed(@store_a, "bot_id" => "42", "offset" => 100,
      "routes" => { "-10:4:1" => route("conversation-a") })
    with_worker do
      connect(@store_a, "profile-a")
      assert_equal 100, @clients.fetch(0).polls.pop.fetch(:offset)
      assert_equal "Telegram · Chat -10 · Topic 4 · User 1", @binding_hook.call("conversation-a").fetch("label")
      change(@store_a) do |document|
        document["pending_update"] = { "update" => { "update_id" => 101 } }
        document["deliveries"]["old"] = { "status" => "pending", "text" => "Profile A only" }
      end
      original = value(@store_a)
      @connection_hook.call(nil)
      assert_equal "waiting_for_nexus", status.fetch("connection")
      assert_nil @binding_hook.call("conversation-a")
      refute status.key?("offset")

      connect(@store_b, "profile-b")
      refute @clients.fetch(1).polls.pop.key?(:offset)
      assert_nil @binding_hook.call("conversation-a")
      assert_equal original, value(@store_a)
      current = value(@store_b)
      assert_nil current["offset"]
      assert_nil current["pending_update"]
      assert_empty current.fetch("routes")
      assert_empty current.fetch("deliveries")
      assert_empty Dir.children(@directory)
      assert_equal [[:created, 0], [:identified, 0], [:closed, 0], [:poll_retired, 0], [:created, 1], [:identified, 1]],
        @events.map { |kind, number, _thread| [kind, number] }
    end
  end

  def test_same_profile_reconnect_reloads_database_and_reidentifies_the_bot
    seed(@store_a, "bot_id" => "42", "offset" => 100)
    with_worker do
      connect(@store_a, "profile-a")
      assert_equal 100, @clients.fetch(0).polls.pop.fetch(:offset)
      @connection_hook.call(nil)
      change(@store_a) { |document| document["offset"] = 200 }

      connect(@store_a, "profile-a")
      assert_equal 200, @clients.fetch(1).polls.pop.fetch(:offset)
      assert_equal 200, status.fetch("offset")
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
    seed(@store_a, "bot_id" => "42", "offset" => 100)
    seed(@store_b, "bot_id" => "99", "offset" => 10)
    with_worker do |task|
      connect(@store_a, "profile-a")
      @clients.fetch(0).polls.pop
      original_a, original_b = value(@store_a), value(@store_b)

      connect(@store_b, "profile-b")
      task.yield
      assert_equal "configuration_error", status.fetch("connection")
      assert_equal "99", status.fetch("bot_id")
      assert_equal 10, status.fetch("offset")
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
    seed(@store_a, "bot_id" => "42", "offset" => 100)
    with_worker do
      connect(@store_a, "profile-a")
      @clients.fetch(0).polls.pop
      configure(configuration: { "owner_id" => "7", "stale_after" => 30, "input_debounce_seconds" => 0 })
      assert_equal 1, @clients.length
      assert_equal "7", status.dig("configuration", "owner_id")
      assert_equal 30, status.dig("configuration", "stale_after")
      assert_equal 0, status.dig("configuration", "input_debounce_seconds")
      assert_equal 100, status.fetch("offset")
      assert_equal "running", status.fetch("connection")
      assert_empty @events.select { |kind, _number, _thread| kind == :closed }
    end
  end

  def test_disable_preserves_access_and_reenable_uses_the_latest_connection
    seed(@store_a, "bot_id" => "42", "offset" => 100)
    with_worker do
      connect(@store_a, "profile-a")
      @clients.fetch(0).polls.pop
      configure(enabled: false)
      assert_equal "disabled", status.fetch("connection")
      assert_equal 100, status.fetch("offset")
      refute status.fetch("enabled")
      route = @api.routes.find { |row| row.path == "/telegram/access" }
      response = route.handler.call(request("list" => "allowed_users", "action" => "add", "id" => "7"), nil)
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
    seed(@store_a, "bot_id" => "42", "offset" => 100)
    with_worker do
      connect(@store_a, "profile-a")
      @clients.fetch(0).polls.pop
      configure(configuration: { "token" => "replacement" })
      assert_equal 100, @clients.fetch(1).polls.pop.fetch(:offset)
      assert_equal "saved", status.dig("token", "source")
      events = @events.map { |kind, number, _thread| [kind, number] }
      assert_operator events.index([:poll_retired, 0]), :<, events.index([:created, 1])
    end
  end

  def test_idle_worker_allows_first_enable_without_restarting_the_daemon
    configure(enabled: false)
    seed(@store_a, "bot_id" => "42", "offset" => 100)
    with_worker do
      connect(@store_a, "profile-a")
      assert_empty @clients
      assert_equal "disabled", status.fetch("connection")
      configure(enabled: true)
      assert_equal 100, @clients.fetch(0).polls.pop.fetch(:offset)
      assert_equal "running", status.fetch("connection")
    end
  end

  def test_bot_binding_error_names_the_profile_owner
    seed(@store_a, "bot_id" => "99")
    state = Rho::IngressTelegram::State.new(store: document(@store_a))
    error = assert_raises(Rho::ConfigurationError) { state.bind(42) }
    assert_equal "telegram: this Agent profile is bound to another bot; use a different Agent", error.message
  end

  private

    def configure(configuration: {}, enabled: @host.config.plugin_enabled?(Rho::IngressTelegram::NAME))
      id = Rho::IngressTelegram::NAME
      values = @host.config.plugin_configuration(id).merge(configuration)
      @host.config.apply(Rho::Config.from_hash(@host.config.to_h.merge("plugins" => {
        id => { "enabled" => enabled, "configuration" => values },
      })))
      @api.daemon_hooks.find { |hook| hook.event == :configuration_change }.handler.call(@host.config)
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
      factory = ->(**) {
        Client.new(number: @clients.length, events: @events).tap { |client| @clients << client }
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

    def status = @api.routes.fetch(0).handler.call(nil, nil).last
    def value(store) = store.rows.values.fetch(0).value
    def document(store) = Rho::StoreDocument.new(store: -> { store }, namespace: "rho.telegram", key: "state")
    def seed(store, attributes) = Rho::IngressTelegram::State.new(store: document(store)).change { |held| held.merge!(attributes) }
    def change(store, &block) = document(store).change(&block)

    def route(conversation_id)
      { "chat_id" => "-10", "topic_id" => 4, "group" => true, "owner_id" => "1", "current" => conversation_id,
        "conversations" => {} }
    end
end
