require_relative "../test_helper"
require_relative "../support/ops_harness"

class OpsLifecycleTest < Minitest::Test
  include RhoTest::OpsHarness

  class ArchivedApi < NexusDoubles::FakeAgentApi
    private

      def conversation_row(public_id, **options)
        super.merge("archived_at" => "2026-09-30T00:00:00Z")
      end

      def agent_loop_response(method, path, credential, body = nil)
        if method == :get && path.end_with?("/agent_loops/c-1")
          return respond(404, { "error" => { "code" => "not_found", "message" => "No such loop" } })
        end

        super
      end
  end

  def test_an_archived_conversations_queue_remains_readable_after_its_follower_is_released
    api = ArchivedApi.new(conversation_events: [event("conversation_ended", { "reason" => "archived" })],
      workspaces: [{ public_id: "ws-1", name: "Original" }])
    daemon = member_ready(boot, api)
    core = Rho::Core.new(home: daemon.home)

    core.attach("c-1", host_type: "conversation", workspace_public_id: "ws-1")
    wait_for { store.find("c-1").nil? && daemon.context.run("c-1").nil? }

    assert_empty core.inputs("c-1", host_type: "conversation", workspace_public_id: "ws-1")
    assert api.requests.any? { |path, _| path.end_with?("/conversations/c-1/inputs") }
    refute api.requests.any? { |path, _| path.end_with?("/agent_loops/c-1", "/cancellation") }
    assert_nil store.find("c-1"), "reading an archived queue must not follow it again"
    assert_nil daemon.context.run("c-1")
  end

  def test_a_normally_opened_host_is_released_and_can_be_attached_after_restoration
    assert_host_ends_and_reattaches(:open)
  end

  def test_an_attached_host_uses_the_same_end_cleanup_and_can_be_attached_after_restoration
    assert_host_ends_and_reattaches(:attach)
  end

  def test_a_request_forbidden_by_nexus_stays_403_without_ending_the_follow
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, conversation_events: [])
    daemon = member_ready(boot, api)
    capturing_spawns(daemon) { attach(daemon) }
    run = daemon.context.run("c-1")
    original = api.method(:call)
    api.define_singleton_method(:call) do |path, **arguments|
      if arguments[:method] == :post && path.end_with?("/inputs")
        CybrosAgent::Response.new(status: 403, headers: {}, body: {
          "error" => { "code" => "forbidden", "message" => "This workspace is read-only" },
        })
      else
        original.call(path, **arguments)
      end
    end

    response = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: "c-1", text: "continue", model: "dev/mock-text" })

    assert_equal "403", response.code, response.body
    assert_equal "forbidden", JSON.parse(response.body).dig("error", "code")
    assert_same run, daemon.context.run("c-1")
    refute_predicate run, :stopped?
    refute api.requests.any? { |path, _| path.end_with?("/cancellation") }
  end

  private

    def attach(daemon)
      response = request(daemon, :post, "/loops/attach", token: bearer(daemon),
        body: { public_id: "c-1", host_type: "conversation", live: false })
      assert_equal "200", response.code, response.body
    end

    def assert_host_ends_and_reattaches(entry)
      events = nil
      api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE,
        conversation_events: -> { events || api.send(:materialized_events, "c-1") })
      hook = File.join(@root, "release.rb")
      released = File.join(@root, "released.txt")
      File.write(hook, <<~RUBY)
        module ReleaseExtension
          def self.register(api)
            api.on(:host_ended) { |id| File.open(#{released.inspect}, "a") { |file| file.puts(id) } }
          end
        end
      RUBY
      daemon = member_ready(boot(config: Rho::Config.from_hash({ "mode" => "agent", "extension_paths" => [hook] })), api)
      capturing_spawns(daemon) do
        if entry == :attach
          attach(daemon)
        else
          response = request(daemon, :post, "/conversations", token: bearer(daemon),
            body: { prompt: "hello", model: "dev/mock-text", live: false })
          assert_equal "201", response.code, response.body
        end
      end
      ended = daemon.context.run("c-1")
      refute_nil ended
      events = [event("conversation_ended", {})]

      ended.follow

      assert_predicate ended, :stopped?
      assert_nil daemon.context.run("c-1")
      assert_nil store.find("c-1")
      assert_equal ["c-1"], File.readlines(released, chomp: true)
      refute api.requests.any? { |path, _| path.end_with?("/cancellation") }

      events.clear
      capturing_spawns(daemon) { attach(daemon) }
      restored = daemon.context.run("c-1")
      refute_same ended, restored
      refute_predicate restored, :stopped?
      restored.listen { |_event| restored.stop }
      events << event("turn_status", { "turn_public_id" => "t-restored", "status" => "running" })
      restored.follow
      assert_equal "t-restored", restored.snapshot.turn
      assert_equal "running", restored.snapshot.status
    end

    def event(type, payload)
      { "public_id" => "ev-1", "sequence" => 1, "cursor" => "c1", "type" => type,
        "resource" => { "type" => "conversation", "public_id" => "c-1" },
        "occurred_at" => "2026-09-30T00:00:00Z", "payload" => payload }
    end
end
