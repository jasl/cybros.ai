require "support/daemon_run_helpers"

class DaemonCapturedToolSelectionTest < Minitest::Test
  include RhoTest::DaemonRunHelpers

  class CapturedApi < NexusDoubles::FakeAgentApi
    attr_reader :job_writes

    def initialize(captured_mcp_tools: [], **options)
      super(**options)
      @job_writes = []
      @captured_mcp_tools = captured_mcp_tools
    end

    def conversation_response(method, path, credential, body, params: nil)
      return super unless %i[post patch].include?(method) && path.include?("/schedules") && credential == NexusDoubles::MEMBER_TOKEN

      @job_writes << body.fetch("schedule")
      @job = (@job || {}).merge(body.fetch("schedule"))
      respond(method == :post ? 201 : 200, { "schedule" => @job.merge("public_id" => "job-1", "workspace_public_id" => "ws-1", "status" => "active", "lock_version" => 0) })
    end

    private

      def conversation_row(public_id, side: false)
        super.merge("agent_configuration_present" => true)
      end

      def tool_assembly_response(body)
        return super unless body.key?("conversation_public_id")

        @tool_assemblies << body
        tools = %w[read role_write].map do |name|
          { "type" => "function", "function" => { "name" => name, "description" => "Captured role tool",
            "parameters" => { "type" => "object", "properties" => {} } } }
        end
        respond(200, { "tool_definitions" => tools + @captured_mcp_tools, "environment" => {} })
      end
  end

  def test_a_side_uses_its_captured_tools_and_model_instead_of_live_main_defaults
    page = Queue.new
    api = CapturedApi.new(user_public_id: IDENTITY.user_public_id, tools: NexusDoubles::KERNEL_CATALOG,
      trace: NexusDoubles::RUNNING_TRACE, events: page,
      captured_mcp_tools: [{ "type" => "function", "function" => { "name" => "account_read" },
        "route" => { "kind" => "mcp", "tool_name" => "read", "connection_public_id" => SecureRandom.uuid_v7 } }])
    now = Time.utc(2026, 10, 12)
    daemon = member_ready(boot(config: catalog_config("default_model" => "main/current"), realtime_factory: ->(*) { nil },
      clock: -> { page.empty? ? now : (now += Rho::Daemon::HostFollowers::MATERIALIZATION_POLL) },
      sleeper: ->(_seconds) { sleep 0.001 }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", run_public_id: "al-1", model: "main/stale")

    asking = Thread.new do
      request(daemon, :post, "/side", token: bearer(daemon), body: {
        parent_public_id: "c-1", text: "Read the role task's files", tools: "read",
      })
    end
    wait_for { api.inputs.any? }
    page << true
    response = asking.value
    assert_equal "201", response.code, response.body
    input = api.inputs.last.fetch("input")
    assert_equal ["read"], input.fetch("tool_names")
    refute input.key?("model"), "the fork owns its captured selection"
    refute input.key?("agent_configuration")
    assert_equal "c-1-side", api.tool_assemblies.last.fetch("conversation_public_id")
    refute api.tool_assemblies.last.key?("configuration")
    refute api.tool_assemblies.last.key?("agent_public_id"), "the conversation keeps its captured answering principal"
  end

  def test_a_human_schedule_on_a_child_selects_its_captured_tools
    api = CapturedApi.new(user_public_id: IDENTITY.user_public_id, tools: NexusDoubles::KERNEL_CATALOG)
    daemon = member_ready(boot(config: catalog_config("default_model" => "main/current"), realtime_factory: ->(*) { nil }), api)
    response = request(daemon, :post, "/conversations/schedules/create", token: bearer(daemon), body: {
      public_id: "child-1", prompt: "Continue the role task", idempotency_key: "captured-child-job", model: "role/model",
      rule: { kind: "once", run_at: "2026-10-13T09:00:00Z" }, tool_names: %w[read role_write memory_read],
    })

    assert_equal "201", response.code, response.body
    assert_equal %w[read role_write], api.job_writes.last.fetch("tool_names")
    assert_equal "child-1", api.tool_assemblies.last.fetch("conversation_public_id")
    refute api.tool_assemblies.last.key?("configuration")
  end

  def test_a_human_schedule_leaves_a_captured_default_model_with_the_kernel
    api = CapturedApi.new(user_public_id: IDENTITY.user_public_id, tools: NexusDoubles::KERNEL_CATALOG)
    daemon = member_ready(boot(config: catalog_config("default_model" => "main/current"), realtime_factory: ->(*) { nil }), api)
    response = request(daemon, :post, "/conversations/schedules/create", token: bearer(daemon), body: {
      public_id: "child-1", prompt: "Continue the role task", idempotency_key: "captured-child-job-default",
      rule: { kind: "once", run_at: "2026-10-13T09:00:00Z" },
    })

    assert_equal "201", response.code, response.body
    refute api.job_writes.last.key?("model"), "a Main default cannot override the child selection"
  end

  def test_schedule_create_and_update_preserve_explicit_selection_and_empty_or_reset_recovery
    api = CapturedApi.new(user_public_id: IDENTITY.user_public_id, tools: NexusDoubles::KERNEL_CATALOG)
    daemon = member_ready(boot(config: catalog_config("default_model" => "main/current"), realtime_factory: ->(*) { nil }), api)
    response = request(daemon, :post, "/conversations/schedules/create", token: bearer(daemon), body: {
      public_id: "child-1", prompt: "Continue", idempotency_key: "captured-child-job-explicit", model: "chosen/task",
      model_selection: allowed_selection, fallback_models: [], rule: { kind: "once", run_at: "2026-10-13T09:00:00Z" },
    })
    assert_equal "201", response.code, response.body
    assert_equal allowed_selection, api.job_writes.last.fetch("model_selection")
    assert_empty api.job_writes.last.fetch("fallback_models")

    [[], nil].each do |fallbacks|
      response = request(daemon, :post, "/conversations/schedules/update", token: bearer(daemon), body: {
        public_id: "child-1", job_public_id: "job-1", expected_lock_version: 0, fallback_models: fallbacks,
      })
      assert_equal "200", response.code, response.body
      assert api.job_writes.last.key?("fallback_models")
      if fallbacks.nil?
        assert_nil api.job_writes.last["fallback_models"]
      else
        assert_empty api.job_writes.last["fallback_models"]
      end
      refute api.job_writes.last.key?("model_selection")
      refute api.job_writes.last.key?("model")
    end
  end

  def test_child_say_preserves_omission_and_explicit_route_intent
    api = CapturedApi.new(user_public_id: IDENTITY.user_public_id, tools: NexusDoubles::KERNEL_CATALOG,
      trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot(config: catalog_config("default_model" => "main/current"), realtime_factory: ->(*) { nil }), api)
    store.remember(conversation_host("child-1"), workspace: "ws-1", model: "main/stale")

    [{ "fallback_models" => [] }, { "model" => "chosen/task" },
     { "model" => "chosen/task", "model_selection" => allowed_selection }].each do |selection|
      response = request(daemon, :post, "/say", token: bearer(daemon), body: {
        "public_id" => "child-1", "text" => "Continue", "wait" => false,
      }.merge(selection))
      assert_equal "200", response.code, response.body
      assert_selection(api.inputs.last.fetch("input"), selection)
    end
  end

  def test_child_preview_preserves_omission_and_explicit_route_intent
    estimate = { "context_estimate" => {
      "input_tokens" => 0, "tokenizer_exact" => true, "message_count" => 0,
      "history" => { "selected" => 0, "skipped" => 0 }, "mechanism" => "assembly", "entries" => [],
      "storage" => { "bytes" => 0, "bound" => 1_048_576, "within_bound" => true },
      "blocks" => [], "memory" => { "included" => 0, "omitted" => 0 }, "slots" => {},
    } }
    api = CapturedApi.new(user_public_id: IDENTITY.user_public_id, tools: NexusDoubles::KERNEL_CATALOG, context_estimate: estimate)
    daemon = member_ready(boot(config: catalog_config("default_model" => "main/current"), realtime_factory: ->(*) { nil }), api)

    [{ "fallback_models" => [] }, { "model" => "chosen/task" },
     { "model" => "chosen/task", "model_selection" => allowed_selection }].each do |selection|
      response = request(daemon, :post, "/conversations/prompt_preview", token: bearer(daemon), body: {
        "public_id" => "child-1", "prompt" => "Continue",
      }.merge(selection))
      assert_equal "200", response.code, response.body
      fields = api.context_estimates.last.fetch(:body).fetch("context_estimate")
      assert_selection(fields, selection, preview: true)
    end
  end

  def test_regeneration_preserves_captured_defaults_and_user_selection_intent
    turn = { "public_id" => "t0", "position" => 0, "kind" => "direct_reply", "role" => "assistant",
      "status" => "completed", "visibility" => "visible", "inherited" => false, "created_at" => "2026-10-12T00:00:00Z",
      "answering_user_public_id" => IDENTITY.user_public_id }
    variants = { "turn" => { "public_id" => "t0" }, "variants" => [
      { "public_id" => "v0", "source" => "run", "status" => "completed", "active" => true, "run_public_id" => "al0",
        "runner_effects" => { "status" => "untouched", "runners" => [] } },
    ] }
    api = CapturedApi.new(user_public_id: IDENTITY.user_public_id, turns: [turn], variants: variants)
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)

    [{ "fallback_models" => [] }, { "model" => "chosen/task" },
     { "model" => "chosen/task", "model_selection" => allowed_selection }].each_with_index do |selection, index|
      response = request(daemon, :post, "/conversations/regenerate", token: bearer(daemon), body: {
        "public_id" => "child-1", "turn" => "t0", "idempotency_key" => "captured-regenerate-#{index}",
      }.merge(selection))
      assert_equal "200", response.code, response.body
      assert_selection(api.regenerations.last.last.fetch("regeneration"), selection)
    end
  end

  private

    def allowed_selection
      { "source" => "explicit", "model" => "chosen/task", "constraint" => "model", "alternatives" => ["allowed/alternate"] }
    end

    def assert_selection(fields, selection, preview: false)
      if selection.key?("model")
        assert_equal({ "model" => "chosen/task" }, fields.fetch("model"))
        intent = selection["model_selection"] || { "source" => "explicit", "model" => "chosen/task", "constraint" => "route", "alternatives" => [] }
        assert_equal intent, fields["model_selection"]
      else
        if preview
          assert_equal({}, fields.fetch("model"))
        else
          refute fields.key?("model")
        end
        refute fields.key?("model_selection")
      end
      if selection.key?("fallback_models")
        assert_empty fields.fetch("fallback_models")
      else
        refute fields.key?("fallback_models")
      end
      refute fields.key?("agent_configuration")
    end
end
