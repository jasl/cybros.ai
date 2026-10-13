require "test_helper"

class ExtensionReplacementTest < Minitest::Test
  include RhoTest::DaemonHarness

  def test_registration_or_startup_failure_keeps_the_active_routes_and_cleans_the_candidate
    events = []
    phase = :ready
    feature = extension("test.replace") do |api|
      current = phase
      api.on(:shutdown) { events << [:closed, current] }
      raise "registration failed" if current == :register_error

      api.on(:startup) { raise "startup failed" if current == :startup_error }
      api.register_route("GET", "/replacement") { |_request, _ctx| [200, { "version" => current.to_s }] }
    end
    daemon = boot(extensions: Rho::Extensions::DEFAULT_EXTENSIONS + [feature, refresh_control])

    %i[register_error startup_error].each do |failure|
      phase = failure
      response = request(daemon, :post, "/replace-test", token: bearer(daemon), body: {})
      assert_equal "422", response.code, response.body
      assert_equal "ready", read_version(daemon)
      assert_includes events, [:closed, failure]
      refute_includes events, [:closed, :ready]
    end
  end

  def test_replacement_publishes_new_routes_while_an_old_call_keeps_its_resources
    events = Thread::Queue.new
    pollers = Thread::Queue.new
    started = Thread::Queue.new
    release = Thread::Queue.new
    version = "first"
    feature = extension("test.replace") do |api|
      current = version
      api.on(:shutdown) { events << current }
      api.background do
        sleep
      ensure
        pollers << current
      end
      api.register_route("GET", "/replacement") do |_request, _ctx|
        if current == "first"
          started << true
          release.pop
        end
        [200, { "version" => current }]
      end
    end
    daemon = boot(extensions: Rho::Extensions::DEFAULT_EXTENSIONS + [feature, refresh_control])
    call = Thread.new { request(daemon, :get, "/replacement", token: bearer(daemon)) }
    assert started.pop(timeout: 2), "old call never started"
    version = "second"

    response = request(daemon, :post, "/replace-test", token: bearer(daemon), body: {})

    assert_equal "200", response.code, response.body
    assert_equal ["test.replace"], JSON.parse(response.body).fetch("cleanup_pending")
    assert_equal "second", read_version(daemon)
    assert_equal "first", pollers.pop(timeout: 2), "old autonomous work must stop at retirement"
    assert events.empty?, "old resource closed while its call was running"
    release << true
    assert_equal "first", JSON.parse(call.value.body).fetch("version")
    assert_equal "first", events.pop(timeout: 2)
  ensure
    release << true if release
    call&.join(2)
  end

  def test_replacement_keeps_a_browser_read_alive_while_its_authorization_is_pending
    closed, entered, authorizing, release = Queue.new, Queue.new, Queue.new, Queue.new
    version = "first"
    feature = extension("test.replace") do |api|
      current = version
      api.on(:shutdown) { closed << current }
      api.register_route("GET", "/replacement") do |_request, _ctx|
        entered << current
        [200, { "version" => current }]
      end
    end
    daemon = boot(extensions: Rho::Extensions::DEFAULT_EXTENSIONS + [feature, refresh_control])
    daemon.instance_variable_get(:@browser_login).define_singleton_method(:authorized?) do |_request|
      authorizing << true
      release.pop
    end
    call = Thread.new { request(daemon, :get, "/replacement", token: "synthetic-browser-token") }
    assert authorizing.pop(timeout: 2), "browser authorization never started"
    assert entered.empty?, "the route ran before browser authorization completed"
    version = "second"

    replacement = request(daemon, :post, "/replace-test", token: bearer(daemon), body: {})
    assert_equal "200", replacement.code, replacement.body
    closed_while_authorizing = !closed.empty?
    assert_equal "second", read_version(daemon)
    release << true
    response = call.value

    assert_equal "200", response.code, response.body
    assert_equal "first", JSON.parse(response.body).fetch("version")
    assert_equal ["test.replace"], JSON.parse(replacement.body).fetch("cleanup_pending")
    refute closed_while_authorizing, "the old owner closed while its browser read was authorizing"
    assert_equal "first", closed.pop(timeout: 2)
    assert_equal "second", entered.pop
    assert_equal "first", entered.pop
    release << false
    assert_equal "401", request(daemon, :get, "/replacement", token: "synthetic-browser-token").code
    assert entered.empty?, "the route ran after browser authorization was refused"
    assert_equal "second", read_version(daemon)
    daemon.stop
    assert_equal "second", closed.pop(timeout: 2), "a refused request retained its owner"
  ensure
    release&.push(true)
    call&.join(2)
  end

  def test_a_removed_background_task_is_stopped_without_a_cooperative_shutdown_hook
    started = Thread::Queue.new
    stopped = Thread::Queue.new
    feature = extension("test.background") do |api|
      api.background do
        started << true
        sleep
      ensure
        stopped << true
      end
    end
    daemon = boot(extensions: Rho::Extensions::DEFAULT_EXTENSIONS + [feature])
    assert started.pop(timeout: 2), "background task never started"

    daemon.stop

    assert stopped.pop(timeout: 2), "registered background task leaked past shutdown"
  end

  def test_replacement_keeps_an_in_flight_daemon_callback_alive
    closed = Thread::Queue.new
    started = Thread::Queue.new
    release = Thread::Queue.new
    version = "first"
    feature = extension("test.replace") do |api|
      current = version
      api.on(:shutdown) { closed << current }
      api.on(:conversation_binding) do |_public_id|
        if current == "first"
          started << true
          release.pop
        end
        { "label" => current }
      end
    end
    reader = extension("test.reader") do |api|
      api.register_route("GET", "/binding-probe") { |_request, ctx| [200, { "bindings" => ctx.conversation_bindings("conversation") }] }
    end
    daemon = boot(extensions: Rho::Extensions::DEFAULT_EXTENSIONS + [feature, reader, refresh_control])
    call = Thread.new { request(daemon, :get, "/binding-probe", token: bearer(daemon)) }
    assert started.pop(timeout: 2), "daemon callback never started"
    version = "second"

    response = request(daemon, :post, "/replace-test", token: bearer(daemon), body: {})

    assert_equal "200", response.code, response.body
    assert_equal ["test.replace"], JSON.parse(response.body).fetch("cleanup_pending")
    assert closed.empty?, "callback resource closed while its handler was running"
    newer = request(daemon, :get, "/binding-probe", token: bearer(daemon))
    assert_equal "second", JSON.parse(newer.body).fetch("bindings").first.fetch("label")
    release << true
    assert_equal "first", JSON.parse(call.value.body).fetch("bindings").first.fetch("label")
    assert_equal "first", closed.pop(timeout: 2)
  ensure
    release << true if release
    call&.join(2)
  end

  private

    def extension(name, &register)
      Module.new do
        const_set(:NAME, name)
        define_singleton_method(:register, &register)
      end
    end

    def refresh_control
      extension("test.refresh") do |api|
        api.register_route("POST", "/replace-test") do |_request, ctx|
          [200, ctx.refresh_extension("test.replace")]
        rescue Rho::Settings::PreparationError => error
          [422, { "error" => error.message }]
        end
      end
    end

    def read_version(daemon)
      JSON.parse(request(daemon, :get, "/replacement", token: bearer(daemon)).body).fetch("version")
    end
end
