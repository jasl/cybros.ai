require "support/daemon_run_helpers"

class DaemonConversationTitlesTest < Minitest::Test
  include RhoTest::DaemonRunHelpers

  class TitleApi < NexusDoubles::FakeAgentApi
    attr_reader :titles, :title_requests, :title_sides, :workspace_title_requests
    attr_accessor :title_ready

    def initialize(**options)
      super
      @titles, @title_requests, @title_sides, @workspace_title_requests = {}, [], [], []
      @title_ready = true
    end

    def call(path, method: :get, body: nil, **options)
      if method == :post && path.end_with?("/inference_requests")
        @workspace_title_requests << body.fetch("inference_request")
        return respond(422, { "error" => { "code" => "validation_failed", "message" => "Use the conversation's access" } })
      end
      super
    end

    def conversation_response(method, path, credential, body, params: nil)
      if method == :post && path.end_with?("/forks") && body.dig("fork", "title") == "Conversation title"
        parent = path[%r{/conversations/([^/]+)/forks\z}, 1]
        side = "#{parent}-title"
        @title_sides << side
        stock_conversation(side, side: true)
        return respond(201, { "conversation" => conversation_row(side, side: true),
          "runner_effects" => { "status" => "untouched", "runners" => [] } })
      end
      side = path[%r{/conversations/([^/]+)/}, 1]
      if @title_sides.include?(side)
        if method == :post && path.end_with?("/inputs")
          @title_requests << body.fetch("input")
          return respond(202, { "input" => NexusDoubles.input_row("title-input", "pending") })
        end
        if method == :get && path.end_with?("/inputs/title-input/materialization")
          return respond(200, { "materialization" => { "input_public_id" => "title-input", "turn_public_id" => "title-turn",
            "variant_public_id" => "title-variant", "run_public_id" => "title-run" } })
        end
        if method == :get && path.end_with?("/turns/title-turn")
          status = title_ready ? "completed" : "running"
          return respond(200, { "turn" => { "public_id" => "title-turn", "position" => 1, "kind" => "direct_reply",
            "role" => "assistant", "status" => status, "visibility" => "excluded_from_context", "inherited" => false,
            "answering_user_public_id" => @user_public_id, "created_at" => "2026-09-30T00:00:00Z",
            "active_variant" => { "public_id" => "title-variant", "source" => "run", "status" => status,
              "run_public_id" => "title-run", "active" => true, "content" => "项目计划" } } })
        end
      end
      if method == :patch && (id = path[%r{/conversations/([^/]+)\z}, 1])
        fields = body.fetch("conversation")
        return respond(409, { "error" => { "code" => "stale_object", "message" => "Changed" } }) unless fields.fetch("lock_version") == 0

        @titles[id] = fields.fetch("title")
        return respond(200, { "conversation" => conversation_row(id).merge("title" => @titles[id], "lock_version" => 1) })
      end
      super
    end
  end

  def test_prompted_new_conversation_generates_using_the_submitted_model
    daemon, api = title_daemon
    status, opened = open(daemon, prompt: "帮我规划项目", model: "dev/current")
    assert_equal "201", status, opened.inspect
    id = opened.dig("conversation", "public_id")
    wait_for { api.titles[id] }
    assert_equal "项目计划", api.titles[id]
    assert_equal "dev/current", api.title_requests.first.dig("model", "model")
    assert_equal "帮我规划项目", api.title_requests.first.dig("entries", 0, "parts", 0, "text")
    assert_equal "raw", api.title_requests.first.fetch("context_mode")
    assert_empty api.title_requests.first.fetch("tool_names")
    assert_empty api.workspace_title_requests
    wait_for { api.conversation_deletes.include?(api.title_sides.first) }
    refute_includes followed(daemon).map { |row| row.fetch("public_id") }, api.title_sides.first
  end

  def test_promptless_new_conversation_waits_for_its_first_input_and_does_not_title_again
    daemon, api = title_daemon
    status, opened = open(daemon, {})
    assert_equal "201", status
    assert_empty api.title_requests
    id = opened.dig("conversation", "public_id")
    response = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: id, text: "first", model: "dev/current", wait: false })
    assert_equal "200", response.code, response.body
    wait_for { api.titles[id] }
    response = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: id, text: "later", model: "dev/current", wait: false })
    assert_equal "200", response.code, response.body
    assert_equal 1, api.title_requests.length
  end

  def test_title_work_preserves_the_existing_reusable_side_and_leaves_no_extra_follower
    daemon, api = title_daemon
    api.title_ready = false
    _, opened = open(daemon, {})
    id = opened.dig("conversation", "public_id")
    response = request(daemon, :post, "/side", token: bearer(daemon), body: { parent_public_id: id, tools: "write" })
    assert_equal "201", response.code, response.body
    reusable = JSON.parse(response.body).dig("side", "public_id")

    response = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: id, text: "first", model: "dev/current", wait: false })
    assert_equal "200", response.code, response.body
    wait_for { api.title_requests.any? }
    title_side = api.title_sides.fetch(0)
    sides = JSON.parse(request(daemon, :get, "/followers?side=1", token: bearer(daemon)).body).fetch("followers")
    assert_equal [reusable], sides.map { |row| row.fetch("public_id") }
    refute_includes followed(daemon).map { |row| row.fetch("public_id") }, title_side

    api.title_ready = true
    wait_for { api.conversation_deletes.include?(title_side) }
    assert_equal [title_side], api.conversation_deletes
    response = request(daemon, :post, "/side", token: bearer(daemon), body: { parent_public_id: id, tools: "write" })
    assert_equal "200", response.code, response.body
    assert_equal reusable, JSON.parse(response.body).dig("side", "public_id")
    assert_equal "项目计划", api.titles[id]
  ensure
    api.title_ready = true if api
  end

  def test_none_keeps_submission_successful_without_a_title_request
    daemon, api = title_daemon(conversation_title_model: nil)
    status, opened = open(daemon, prompt: "work", model: "dev/current")
    assert_equal "201", status, opened.inspect
    assert_empty api.title_requests
    assert_empty api.titles
  end

  def test_a_waiting_first_input_keeps_the_title_when_a_later_input_does_not_wait
    materialized = Queue.new
    daemon, api = title_daemon(conversation_events: materialized)
    _, opened = open(daemon, {})
    id = opened.dig("conversation", "public_id")
    first = Thread.new do
      request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: id, text: "first", model: "dev/current", delivery_mode: "queue", wait: true })
    end
    wait_for { api.conversation_inputs.any? }
    later = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: id, text: "later", model: "dev/current", wait: false })
    assert_equal "200", later.code, later.body
    wait_for { api.title_requests.any? }
    assert first.alive?, "the first input is still waiting for materialization"
    assert_equal 1, api.title_requests.length
    assert_equal "first", api.title_requests.first.dig("entries", 0, "parts", 0, "text")
  ensure
    materialized << true
    first&.join
  end

  def test_title_is_forwarded_with_and_without_the_first_prompt
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)

    [{ "title" => "An empty conversation" },
     { "title" => "A first prompt", "prompt" => "hello", "model" => "dev/mock-text" }].each do |body|
      code, answer = open(daemon, body)
      assert_equal "201", code, answer.inspect
      assert_equal body.fetch("title"), api.conversation_creates.last.dig("conversation", "title")
      assert_equal Rho::Speakers.memory_context,
        api.conversation_creates.last.dig("conversation", "memory_context")
    end
    assert_equal 1, api.conversation_inputs.length
    assert_equal "speaker-owner", api.conversation_inputs.last.dig("input", "speaker_public_id")
  end

  private

    def title_daemon(conversation_events: :materialized, **settings)
      api = TitleApi.new(user_public_id: IDENTITY.user_public_id, tools: NexusDoubles::KERNEL_CATALOG, conversation_events: conversation_events)
      daemon = member_ready(boot(config: catalog_config(settings.transform_keys(&:to_s)), realtime_factory: ->(*) { nil }), api,
        conversation_titles: true)
      [daemon, api]
    end
end
