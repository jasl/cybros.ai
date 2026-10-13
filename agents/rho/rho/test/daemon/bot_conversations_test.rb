require "test_helper"
require "support/nexus_doubles"
require "support/daemon_harness"
require "async/queue"

class DaemonBotConversationsTest < Minitest::Test
  include RhoTest::DaemonHarness

  # A kernel transport with durable create receipts and lifecycle state. Faults
  # happen after the remote write, reproducing the unknown response boundary.
  class LifecycleApi < NexusDoubles::FakeAgentApi
    attr_accessor :fail_after, :pause_create, :pause_input, :refuse_archive, :captured_tools
    attr_reader :rows, :actions, :archived_workspaces

    def initialize(**options)
      super
      @rows, @receipts, @actions = {}, {}, []
      @archived_workspaces = []
    end

    def call(path, method: :get, body: nil, headers: {}, **options)
      key = [path, headers["Idempotency-Key"]]
      creation = method == :post && (path.match?(%r{\A/agent_api/v1/workspaces/[^/]+/conversations\z}) || path.end_with?("/forks"))
      if creation && (receipt = @receipts[key])
        return CybrosAgent::Response.new(status: receipt.status,
          headers: receipt.headers.merge("Idempotency-Replayed" => "true"), body: receipt.body)
      end
      pause_create&.call if creation
      pause_input&.call if method == :post && path.end_with?("/inputs")
      answer = super(path, method: method, body: body, headers: headers, **options)
      if creation && answer.status == 201
        @receipts[key] = CybrosAgent::Response.new(status: 201, headers: {}, body: Marshal.load(Marshal.dump(answer.body)))
      end
      if @fail_after && path.end_with?(@fail_after) && method == :post
        @fail_after = nil
        raise CybrosAgent::TransportError, "lost response after commit"
      end
      answer
    end

    def tool_assembly_response(body)
      return super unless body["conversation_public_id"] && captured_tools

      @tool_assemblies << body
      respond(200, { "tool_definitions" => captured_tools, "environment" => {} })
    end

    def workspace_row(workspace)
      row = super
      if @archived_workspaces.include?(workspace.fetch(:public_id))
        row.merge!("state" => "archived", "archived_at" => "2026-10-12T01:00:00Z")
      end
      row
    end

    def conversation_response(method, path, credential, body, params: nil)
      if method == :get && path == "/agent_api/v1/conversations"
        rows = @rows.values.select do |row|
          row.fetch("answering_user_public_id") == params.fetch("answering_user_public_id") &&
            row.fetch("metadata", {})[params.fetch("metadata_key")] == params.fetch("metadata_value") &&
            row["parent"].nil? && !row["side"]
        end
        rows = rows.select { |row| !row["archived_at"].nil? == params["archived"] } unless params["archived"].nil?
        return respond(200, { "conversations" => rows, "pagination" => { "next_after" => nil } })
      end
      id = path[%r{/conversations/([^/]+)}, 1]
      if method == :post && (@archived_workspaces.include?(@rows.dig(id, "workspace_public_id")) || (refuse_archive && path.end_with?("/archive")))
        return respond(403, { "error" => { "code" => "not_authorized", "message" => "This workspace is not writable by the caller" } })
      end
      if id && path.match?(%r{/conversations/[^/]+(?:/archive|/unarchive)?\z}) && @rows[id]
        if method == :post
          @actions << [path, id]
          @rows[id]["archived_at"] = path.end_with?("/unarchive") ? nil : "2026-10-12T01:00:00Z"
        elsif method == :patch
          @rows[id].merge!(body.fetch("conversation"))
        end
        return respond(200, { "conversation" => @rows.fetch(id) })
      end
      if method == :post && path.end_with?("/inputs") && @rows.dig(id, "archived_at")
        return respond(409, { "error" => { "code" => "conversation_archived", "message" => "Archived" } })
      end
      answer = super
      if answer&.status == 201 && answer.body["conversation"]
        row = answer.body.fetch("conversation")
        fields = body["conversation"] || {}
        row.merge!(fields.slice("metadata", "memory_context"))
        row["side"] = false if body["fork"] && !body.dig("fork", "side")
        @rows[row.fetch("public_id")] = row
      end
      answer
    end
  end

  def setup
    super
    @config = Rho::Config.from_hash({ "default_model" => "dev/mock-text", "kernel_tools" => [] })
    @api = LifecycleApi.new(user_public_id: IDENTITY.user_public_id, tools: NexusDoubles::KERNEL_CATALOG,
      conversation_events: [], turns: [{ "public_id" => "turn-1", "position" => 0, "kind" => "direct_reply", "role" => "assistant",
        "status" => "completed", "visibility" => "visible", "created_at" => "2026-10-12T00:00:00Z",
        "answering_user_public_id" => IDENTITY.user_public_id }],
      workspaces: [{ public_id: "ws-1", name: "One", dedicated: false },
                                           { public_id: "ws-2", name: "Two", dedicated: false }])
    @daemon = member_ready(boot(config: @config, realtime_factory: ->(*) { nil }), @api)
    @bot = @daemon.context.declare_named_definition(name: "helper", description: "Help with requests")
    @id = @bot.public_id
    @api.stock_principals(@api.named_agents_listing.body.fetch("agents").map do |row|
      row.slice("public_id", "handle", "kind", "display_name", "agent_identifier", "steward_public_id")
    end)
    @daemon.context.replace_bot_settings(agent_public_id: @id, home_workspace_public_id: "ws-1")
  end

  def test_reads_never_create_and_ensure_new_and_resume_keep_one_current_across_workspaces
    detail = get("/bots/detail?agent_public_id=#{@id}")
    assert_nil detail.fetch("current")
    assert_includes detail.fetch("effective_welcome_message"), "helper"
    assert_empty get("/bots/history?agent_public_id=#{@id}").fetch("conversations")
    assert_empty @api.conversation_creates

    first = switch("current", "open-1").fetch("current")
    assert_equal first, switch("current", "open-2").fetch("current")
    assert_equal 1, @api.conversation_creates.length
    assert_equal @id, @api.rows.fetch(first.fetch("public_id")).dig("metadata", "rho_bot_public_id")
    refute @api.conversation_creates.first.dig("conversation", "memory_context", "bindings").any? { |binding| binding.key?("speaker_public_id") }
    @daemon.context.replace_bot_settings(agent_public_id: @id, home_workspace_public_id: "ws-2")
    assert_equal first, get("/bots/detail?agent_public_id=#{@id}").fetch("current")

    second = switch("new", "new-1").fetch("current")
    assert_equal "ws-2", second.fetch("workspace_public_id")
    assert @api.rows.fetch(first.fetch("public_id")).fetch("archived_at")
    assert_equal [first, second].sort_by { |row| row.fetch("public_id") }, history_locators
    resumed = switch("resume", "resume-1", conversation_public_id: first.fetch("public_id"), workspace_public_id: "ws-1")
    assert_equal first, resumed.fetch("current")
    assert_nil @api.rows.fetch(first.fetch("public_id")).fetch("archived_at")
    assert @api.rows.fetch(second.fetch("public_id")).fetch("archived_at")
    assert_equal 2, @api.conversation_creates.length
    assert_empty @api.conversation_inputs, "welcome and lifecycle commands perform no inference"
  end

  def test_bot_modes_come_from_bot_settings_for_current_new_resumed_and_forked_conversations
    response = request(@daemon, :patch, "/settings", token: bearer(@daemon), body: { subagent_default: false })
    assert_equal "200", response.code, response.body
    first = switch("current", "modes-first").fetch("current")
    modes = get("/conversations/modes?public_id=#{first.fetch("public_id")}&workspace_public_id=ws-1").fetch("modes")
    assert_equal({ "code_mode" => false, "subagent" => true, "available" => true, "code_mode_available" => false }, modes)
    response = request(@daemon, :patch, "/conversations/modes", token: bearer(@daemon),
      body: { public_id: first.fetch("public_id"), workspace_public_id: "ws-1", code_mode: true })
    assert_equal "409", response.code, response.body
    assert_equal "bot_modes_managed", JSON.parse(response.body).dig("error", "code")
    @daemon.context.replace_bot_settings(agent_public_id: @id, subagent: false)
    assert_equal false, get("/bots/detail?agent_public_id=#{@id}").dig("bot", "subagent")
    assert_equal false, get("/conversations/modes?public_id=#{first.fetch("public_id")}&workspace_public_id=ws-1").dig("modes", "subagent")
    second = switch("new", "modes-second").fetch("current")
    assert_equal false, get("/conversations/modes?public_id=#{second.fetch("public_id")}&workspace_public_id=ws-1").dig("modes", "subagent")
    switch("resume", "modes-resume", conversation_public_id: first.fetch("public_id"), workspace_public_id: "ws-1")
    child = switch("fork", "modes-fork", conversation_public_id: first.fetch("public_id"),
      workspace_public_id: "ws-1", turn_public_id: "turn-1").fetch("current")
    assert_equal modes.merge("subagent" => false), get("/conversations/modes?public_id=#{child.fetch("public_id")}&workspace_public_id=ws-1").fetch("modes")
    @daemon.context.replace_bot_settings(agent_public_id: @id, subagent: true)
    assert_equal true, get("/conversations/modes?public_id=#{child.fetch("public_id")}&workspace_public_id=ws-1").dig("modes", "subagent")
  end

  def test_bot_next_input_uses_current_mode_settings_and_rejects_conversation_overrides
    request(@daemon, :patch, "/settings", token: bearer(@daemon), body: { kernel_tools: NexusDoubles::KERNEL_TOOLS.keys })
    first = switch("current", "modes-input").fetch("current")
    Async do
      assert_equal 200, direct_say(first, "enabled").first
      enabled = @api.conversation_inputs.last.fetch("input").fetch("execution_declaration")
      assert_includes enabled.fetch("kernel_tools"), "nexus.graph.delegate_task"
      refute enabled.fetch("tool_definitions").any? { |entry| Rho::CodeMode.code?(entry) }
      @daemon.context.replace_bot_settings(agent_public_id: @id, subagent: false)
      assert_equal 200, direct_say(first, "disabled").first
      disabled = @api.conversation_inputs.last.fetch("input").fetch("execution_declaration")
      refute_includes disabled.fetch("kernel_tools"), "nexus.graph.delegate_task"
      refute disabled.fetch("tool_definitions").any? { |entry| Rho::BotPolicy::SUBAGENT_TOOLS.include?(entry["canonical"]) || Rho::CodeMode.code?(entry) }
      assert_includes disabled.dig("system_prompt", "content"), "Subagent is off"
      assert_includes enabled.fetch("kernel_tools"), "nexus.graph.delegate_task", "accepted declarations stay captured"
      refusal = direct_say(first, "override", code_mode: true, subagent: true)
      assert_equal "bot_modes_managed", refusal.code
    end.wait
    assert_equal 2, @api.conversation_inputs.length
  end

  def test_captured_child_of_a_bot_keeps_its_own_tools_when_bot_subagent_is_off
    first = switch("current", "parent").fetch("current")
    @daemon.context.replace_bot_settings(agent_public_id: @id, subagent: false)
    child = { "public_id" => "captured-child", "workspace_public_id" => "ws-1" }
    @api.rows[child.fetch("public_id")] = @api.rows.fetch(first.fetch("public_id")).merge(
      "public_id" => child.fetch("public_id"), "metadata" => {}, "execution_declaration_present" => true)
    @api.captured_tools = %w[code delegate_task].map { |name| { "type" => "function", "function" => { "name" => name } } }
    host_store(@daemon).remember(Rho::Host::Conversation.new(public_id: child.fetch("public_id")),
      workspace: "ws-1", model: "dev/mock-text", answerer: @id)
    Async do
      assert_equal 200, direct_say(child, "child-input", code_mode: true, subagent: true).first
    end.wait
    input = @api.conversation_inputs.last.fetch("input")
    assert_equal %w[code delegate_task], input.fetch("tool_names")
    refute input.key?("execution_declaration"), "the child keeps its captured role declaration"
    assert_equal child.fetch("public_id"), @api.tool_assemblies.last.fetch("conversation_public_id")
    assert_equal false, get("/bots/detail?agent_public_id=#{@id}").dig("bot", "subagent")
  end

  def test_resume_leaves_an_archived_workspace_and_accepts_input_in_the_selected_workspace
    first = switch("current", "initial").fetch("current")
    second = switch("new", "later", home_workspace_public_id: "ws-2").fetch("current")
    @api.archived_workspaces << "ws-2"

    resumed = switch("resume", "resume-old", conversation_public_id: first.fetch("public_id"), workspace_public_id: "ws-1")
    assert_equal first, resumed.fetch("current")
    assert_nil @api.rows.fetch(first.fetch("public_id")).fetch("archived_at")
    assert_nil @api.rows.fetch(second.fetch("public_id"))["archived_at"]
    refute @api.requests.any? { |path, *| path.end_with?("/conversations/#{second.fetch("public_id")}/archive") }
    Async { assert_equal 200, direct_say(first, "after-resume").first }.wait
    assert_equal 1, @api.conversation_inputs.length
    assert switch("resume", "resume-old", conversation_public_id: first.fetch("public_id"), workspace_public_id: "ws-1").fetch("replayed")
  end

  def test_restoring_the_previous_workspace_still_requires_explicit_resume
    first = switch("current", "initial").fetch("current")
    second = switch("new", "later", home_workspace_public_id: "ws-2").fetch("current")
    @api.archived_workspaces << "ws-2"
    switch("resume", "resume-old", conversation_public_id: first.fetch("public_id"), workspace_public_id: "ws-1")
    @api.archived_workspaces.clear

    Async do
      refusal = direct_say(second, "stale-input")
      assert_equal 409, refusal.status
      assert_equal "bot_resume_required", refusal.code
    end.wait
    assert_empty @api.conversation_inputs
    assert_equal first, get("/bots/detail?agent_public_id=#{@id}").fetch("current")
    assert_equal second, switch("resume", "resume-restored", conversation_public_id: second.fetch("public_id"), workspace_public_id: "ws-2").fetch("current")
    Async { assert_equal 200, direct_say(second, "after-explicit-resume").first }.wait
    assert @api.rows.fetch(first.fetch("public_id")).fetch("archived_at")
  end

  def test_archive_refusal_in_an_active_workspace_does_not_complete_the_switch
    first = switch("current", "initial").fetch("current")
    second = switch("new", "later", home_workspace_public_id: "ws-2").fetch("current")
    @api.refuse_archive = true

    failed = post("/bots/resume", agent_public_id: @id, operation_id: "refused-archive",
      conversation_public_id: first.fetch("public_id"), workspace_public_id: "ws-1")
    assert_equal "403", failed.code
    assert_equal "not_authorized", JSON.parse(failed.body).dig("error", "code")
    assert_equal second, get("/bots/detail?agent_public_id=#{@id}").fetch("current")
    state = @api.store_entries_of("profile").find { |row| row["namespace"] == "rho.bot_conversations" && row["key"] == @id }.fetch("value")
    assert_equal "refused-archive", state.dig("pending", "operation_id")
    refute state.fetch("receipts").key?("refused-archive")

    @api.refuse_archive = false
    resumed = switch("resume", "refused-archive", conversation_public_id: first.fetch("public_id"), workspace_public_id: "ws-1")
    assert_equal first, resumed.fetch("current")
    assert resumed.fetch("replayed")
    assert @api.rows.fetch(second.fetch("public_id")).fetch("archived_at")
  end

  def test_old_operation_replay_returns_actual_current_and_does_not_reapply_its_home_change
    first = switch("new", "old", home_workspace_public_id: "ws-1").fetch("current")
    second = switch("new", "later", home_workspace_public_id: "ws-2").fetch("current")
    replay = switch("new", "old", home_workspace_public_id: "ws-1")
    assert replay.fetch("replayed")
    assert_equal first, replay.fetch("selected")
    assert_equal second, replay.fetch("current")
    assert_equal "ws-2", get("/bots/detail?agent_public_id=#{@id}").dig("bot", "home_workspace_public_id")
    assert_equal 2, @api.conversation_creates.length
    response = post("/bots/new", agent_public_id: @id, operation_id: "old", home_workspace_public_id: "ws-2")
    assert_equal "409", response.code
    assert_equal "idempotency_envelope_mismatch", JSON.parse(response.body).dig("error", "code")
  end

  def test_restart_recovers_a_created_target_before_a_later_command_and_a_lost_archive_response
    first = switch("current", "initial").fetch("current")
    @api.fail_after = "/conversations"
    failed = post("/bots/new", agent_public_id: @id, operation_id: "lost-create")
    assert_equal "502", failed.code
    assert_equal 2, @api.conversation_creates.length
    @daemon.stop
    @daemon = member_ready(boot(config: @config, realtime_factory: ->(*) { nil }), @api)
    recovered = switch("new", "lost-create")
    assert recovered.fetch("replayed")
    second = recovered.fetch("current")
    assert_equal 2, @api.conversation_creates.length
    assert @api.rows.fetch(first.fetch("public_id")).fetch("archived_at")

    @api.fail_after = "/archive"
    failed = post("/bots/new", agent_public_id: @id, operation_id: "lost-archive")
    assert_equal "502", failed.code
    final = switch("current", "later-read").fetch("current")
    refute_equal second, final
    assert_equal 3, @api.conversation_creates.length
    assert @api.rows.fetch(second.fetch("public_id")).fetch("archived_at")
    assert_equal final, switch("new", "lost-archive").fetch("selected")
  end

  def test_resume_rejects_another_bot_and_spawned_or_side_conversations
    current = switch("current", "initial").fetch("current")
    row = @api.rows.fetch(current.fetch("public_id"))
    [{ "metadata" => { "rho_bot_public_id" => "another" } }, { "parent" => { "public_id" => "parent" } }, { "side" => true }].each do |changes|
      saved = row.dup
      row.merge!(changes)
      response = post("/bots/resume", agent_public_id: @id, operation_id: SecureRandom.uuid,
        conversation_public_id: current.fetch("public_id"), workspace_public_id: "ws-1")
      assert_equal "409", response.code
      assert_equal "bot_conversation_mismatch", JSON.parse(response.body).dig("error", "code")
      row.replace(saved)
    end
  end

  def test_fork_enters_the_same_switch_and_preserves_bot_history_provenance
    first = switch("current", "initial").fetch("current")
    forked = switch("fork", "branch", conversation_public_id: first.fetch("public_id"), workspace_public_id: "ws-1", turn_public_id: "turn-1")
    child = forked.fetch("current")
    refute_equal first, child
    assert_equal @id, @api.rows.fetch(child.fetch("public_id")).dig("metadata", "rho_bot_public_id")
    assert @api.rows.fetch(first.fetch("public_id")).fetch("archived_at")
    assert_equal child, switch("fork", "branch", conversation_public_id: first.fetch("public_id"), workspace_public_id: "ws-1", turn_public_id: "turn-1").fetch("selected")
    assert_equal 1, @api.forks.length
  end

  def test_two_concurrent_ensures_create_only_one_current
    Async do |task|
      entered, release = Async::Queue.new, Async::Queue.new
      @api.pause_create = -> { entered.enqueue(true); release.dequeue }
      first = task.async { direct_switch("current", "first") }
      entered.dequeue
      second = task.async { direct_switch("current", "second") }
      task.yield
      refute second.finished?
      release.enqueue(true)
      first_status, first_answer = first.wait
      second_status, second_answer = second.wait
      assert_equal [200, 200], [first_status, second_status]
      assert_equal first_answer.fetch(:current), second_answer.fetch(:current)
      assert_equal 1, @api.conversation_creates.length
    end.wait
  ensure
    @api.pause_create = nil
  end

  def test_new_waits_for_input_acceptance_and_later_old_input_cannot_enter_new_current
    first = switch("current", "initial").fetch("current")
    Async do |task|
      entered, release = Async::Queue.new, Async::Queue.new
      @api.pause_input = -> { entered.enqueue(true); release.dequeue }
      submitting = task.async { direct_say(first, "accepted-before-new") }
      entered.dequeue
      switching = task.async { direct_switch("new", "later") }
      task.yield
      assert_empty @api.actions
      refute switching.finished?
      release.enqueue(true)
      assert_equal 200, submitting.wait.first
      status, answer = switching.wait
      assert_equal 200, status
      refute_equal first, answer.fetch(:current)
      assert @api.rows.fetch(first.fetch("public_id")).fetch("archived_at")
      @api.pause_input = nil
      refusal = direct_say(first, "too-late")
      assert_equal 409, refusal.status
      assert_equal "conversation_archived", refusal.code
      assert_equal 1, @api.conversation_inputs.length
    end.wait
  ensure
    @api.pause_input = nil
  end

  def test_browser_guard_keeps_bot_history_read_only_without_an_active_plugin_binding
    first = switch("current", "initial").fetch("current")
    switch("new", "later", home_workspace_public_id: "ws-2")
    public_id = first.fetch("public_id")
    assert_empty @daemon.context.conversation_bindings(public_id)
    message = json_request({ public_id: public_id, title: "Stale editor" }, token: bearer(@daemon))
    message.headers["x-rho-viewing-conversation"] = [public_id]
    message.headers["x-rho-viewing-workspace"] = ["ws-1"]
    refusal = route(@daemon, "PATCH", "/conversations").call(message)
    assert_equal 409, refusal.status
    assert_equal "ingress_bound", refusal.code
    detail = get("/conversations/detail?public_id=#{public_id}&workspace_public_id=ws-1").fetch("conversation")
    assert_equal @id, detail.fetch("bot_public_id")
    refute_equal "Stale editor", detail["title"]
  end

  def test_generic_bot_open_cannot_create_an_untracked_root
    [nil, "hello"].each do |text|
      response = post("/conversations", agent: @id, prompt: text, model: "dev/mock-text")
      assert_equal "409", response.code
      assert_equal "bot_conversation_required", JSON.parse(response.body).dig("error", "code")
    end
    assert_empty @api.conversation_creates
  end

  def test_generic_rewind_cannot_branch_outside_the_bot_current_switch
    first = switch("current", "initial").fetch("current")
    response = post("/conversations/rewind", public_id: first.fetch("public_id"), turn: "turn-1", keep_checkpoints: true,
      workspace_public_id: first.fetch("workspace_public_id"))

    assert_equal "409", response.code, response.body
    assert_equal "bot_conversation_required", JSON.parse(response.body).dig("error", "code")
    assert_empty @api.forks
    assert_empty @api.run_creates
    assert_equal first, get("/bots/detail?agent_public_id=#{@id}").fetch("current")
  end

  def test_generic_side_cannot_branch_outside_the_bot_current_switch
    first = switch("current", "initial").fetch("current")
    [first.fetch("public_id"), nil].each do |parent|
      response = post("/side", parent_public_id: parent, tools: "write")
      assert_equal "409", response.code, response.body
      assert_equal "bot_conversation_required", JSON.parse(response.body).dig("error", "code")
    end

    assert_empty @api.forks
    assert_empty @api.conversation_inputs
    assert_equal first, get("/bots/detail?agent_public_id=#{@id}").fetch("current")
  end

  private

    def direct_switch(action, operation)
      route(@daemon, "POST", "/bots/#{action}").call(json_request(
        { agent_public_id: @id, operation_id: operation }, token: bearer(@daemon)))
    end

    def direct_say(locator, key, **fields)
      route(@daemon, "POST", "/say").call(json_request({ public_id: locator.fetch("public_id"), host_type: "conversation",
        workspace_public_id: locator.fetch("workspace_public_id"), text: "hello", delivery_mode: "queue", wait: false,
        idempotency_key: key, **fields }, token: bearer(@daemon)))
    end

    def post(path, **body) = request(@daemon, :post, path, token: bearer(@daemon), body: body)

    def get(path)
      response = request(@daemon, :get, path, token: bearer(@daemon))
      assert_equal "200", response.code, response.body
      JSON.parse(response.body)
    end

    def switch(action, operation, **fields)
      response = post("/bots/#{action}", agent_public_id: @id, operation_id: operation, **fields)
      assert_equal "200", response.code, response.body
      JSON.parse(response.body)
    end

    def history_locators
      get("/bots/history?agent_public_id=#{@id}").fetch("conversations")
        .map { |row| row.slice("public_id", "workspace_public_id") }.sort_by { |row| row.fetch("public_id") }
    end
end
