require "test_helper"

class ExtensionConnectionLifecycleTest < Minitest::Test
  include RhoTest::DaemonHarness

  def test_published_package_observer_failures_do_not_hide_applied_state_or_announcement_failure
    api = NexusDoubles::FakeAgentApi.new
    daemon = boot(device_flow: connection_device_flow, api_transport: api,
      config: Rho::Config.from_hash({ "kernel_tools" => [], "adaptations" => "off" }))
    token = connect(daemon)
    package = Dir.mktmpdir("package-", @root)
    File.write(File.join(package, "rho-extension.json"), JSON.generate(name: "callback-probe", id: "test.callback_probe"))
    File.write(File.join(package, "extension.rb"), <<~'RUBY')
      module CallbackProbe
        NAME = "test.callback_probe"

        def self.register(api)
          events = []
          api.background { events << "background" }
          api.on(:member_connection) do |connection|
            if connection
              events << "failed"
              raise Rho::ConfigurationError, "private callback detail"
            end
          end
          api.on(:member_connection) { |connection| events << "ready" if connection }
          api.on(:configuration_change) do |_config|
            events << "configuration-failed"
            raise "private configuration detail"
          end
          api.on(:configuration_change) { |_config| events << "announced" }
          api.register_route("GET", "/callback-probe") { |_request, _ctx| [200, { events: events }] }
        end
      end
    RUBY
    installed = request(daemon, :post, "/extensions/packages", token: token, body: { action: "install", path: package })
    assert_equal "200", installed.code, installed.body
    version = JSON.parse(installed.body).fetch("version")
    declarations = api.configuration_declarations.length

    response = request(daemon, :post, "/extensions/packages", token: token,
      body: { action: "activate", name: "callback-probe", version: version })

    assert_equal "200", response.code, response.body
    assert_equal version, JSON.parse(response.body).fetch("active")
    saved = Rho::Packages.new(home: daemon.home).list.fetch(:packages).first
    assert saved.fetch(:selected)
    assert saved.fetch(:enabled)
    assert_equal version, saved.fetch(:version)
    wait_for { probe(daemon, "/callback-probe").fetch("events").include?("background") }
    assert_equal %w[announced background configuration-failed failed ready], probe(daemon, "/callback-probe").fetch("events").sort
    assert_operator api.configuration_declarations.length, :>, declarations
    log = File.read(daemon.home.log_path)
    assert_includes log, "event=extension_task_failed extension=test.callback_probe detail=member_connection error_class=Rho::ConfigurationError"
    assert_includes log, "event=extension_task_failed extension=test.callback_probe detail=configuration_change error_class=RuntimeError"
    refute_includes log, "private callback detail"
    refute_includes log, "private configuration detail"

    unavailable = CybrosAgent::Response.new(status: 503, headers: {}, body: { "error" => { "code" => "unavailable" } })
    daemon.wire.api_transport = NexusDoubles::FakeAgentApi.new(announcement: unavailable, configuration: unavailable)
    retry_response = request(daemon, :post, "/extensions/packages", token: token,
      body: { action: "activate", name: "callback-probe", version: version })
    assert_equal "200", retry_response.code, retry_response.body
    warning = JSON.parse(retry_response.body).fetch("warning")
    assert_match(/platform announcement failed/, warning)
    refute_includes warning, "RuntimeError"
    assert_equal %w[announced announced background configuration-failed configuration-failed failed ready],
      probe(daemon, "/callback-probe").fetch("events").sort
  end

  def test_disconnect_waits_for_a_hot_registration_member_callback
    started, release, events = Queue.new, Queue.new, Queue.new
    phase = 1
    feature = connection_extension(-> { phase }, events: events) do |version, connection|
      if version == 2 && connection
        started << true
        release.pop
      end
    end
    daemon = connected_boot(config: agent_mode, extensions: [feature, refresh_control])
    token = connect(daemon)
    phase = 2
    replacing = Thread.new { request(daemon, :post, "/replace-connection", token: token, body: {}) }
    assert started.pop(timeout: 2), "replacement callback did not start"
    disconnected = Queue.new
    disconnecting = Thread.new { disconnected << request(daemon, :post, "/disconnect", token: token) }
    wait_for { daemon.lineage.credentials.nil? }
    assert_nil disconnected.pop(timeout: 0.1), "disconnect returned while its old callback was running"

    release << true

    assert replacing.join(2)
    assert_equal "200", replacing.value.code
    assert_equal "200", disconnected.pop(timeout: 2).code
    assert_nil probe(daemon, "/connection-probe").fetch("active")
    assert_equal [[1, "adopt"], [2, "adopt"], [2, "lost"]], drain(events)
  ensure
    release&.push(true)
    replacing&.join(2)
    disconnecting&.join(2)
  end

  def test_a_candidate_prepared_during_disconnect_reads_the_disconnected_lineage
    retiring, release, prepared, events = Queue.new, Queue.new, Queue.new, Queue.new
    phase = 1
    feature = connection_extension(-> { phase }, events: events, prepared: prepared) do |version, connection|
      if version == 1 && connection.nil?
        retiring << true
        release.pop
      end
    end
    daemon = connected_boot(config: agent_mode, extensions: [feature, refresh_control])
    token = connect(daemon)
    disconnecting = Thread.new { request(daemon, :post, "/disconnect", token: token) }
    assert retiring.pop(timeout: 2), "disconnect callback did not start"
    phase = 2
    replacing = Thread.new { request(daemon, :post, "/replace-connection", token: token, body: {}) }
    assert prepared.pop(timeout: 2), "candidate did not finish startup"

    release << true

    assert disconnecting.join(2)
    assert replacing.join(2)
    assert_equal "200", replacing.value.code, replacing.value.body
    assert_nil probe(daemon, "/connection-probe").fetch("active")
    assert_equal [[1, "adopt"], [1, "lost"]], drain(events)
    connect(daemon)
    assert_equal [2, "adopt"], events.pop(timeout: 2)
    assert_equal "0199-user", probe(daemon, "/connection-probe").fetch("active")
  ensure
    release&.push(true)
    replacing&.join(2)
    disconnecting&.join(2)
  end

  private

    def connection_extension(phase, events:, prepared: nil, &callback)
      Module.new do
        const_set(:NAME, "test.connection")
        define_singleton_method(:register) do |api|
          version = phase.call
          active = nil
          api.on(:startup) { prepared << true if prepared && version == 2 }
          api.on(:member_connection) do |connection|
            callback.call(version, connection)
            active = connection
            events << [version, connection ? "adopt" : "lost"]
          end
          api.register_route("GET", "/connection-probe") { |_request, _ctx| [200, { active: active&.user_public_id }] }
        end
      end
    end

    def refresh_control
      Module.new do
        const_set(:NAME, "test.refresh_connection")
        define_singleton_method(:register) do |api|
          api.register_route("POST", "/replace-connection") { |_request, ctx| [200, ctx.refresh_extension("test.connection")] }
        end
      end
    end

    def probe(daemon, path)
      response = request(daemon, :get, path, token: bearer(daemon))
      assert_equal "200", response.code, response.body
      JSON.parse(response.body)
    end

    def drain(queue)
      result = []
      result << queue.pop until queue.empty?
      result
    end
end
