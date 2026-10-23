require "test_helper"

class Executors::NamedAgentTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @tools = %w[application_work application_read].map do |name|
      { "type" => "function", "function" => { "name" => name, "parameters" => { "type" => "object" } } }
    end
    declared = Users::DeclareNamedAgent.call(caller: @agent, name: "assistant", scope: "instance",
      description: "A separate answering identity.", configuration: {
        tool_definitions: @tools, approval_mode: "bypass", approval_rules: nil,
        prompt_mechanism: "default", prompt_template: nil, compaction_policy: nil,
      })
    assert_predicate declared, :accepted?
    @definition = declared.user
    announce_tools!(@agent, %w[application_work application_read publisher_only_tool])
    @address = Executor.address_for(@agent)
  end

  test "a named answerer uses its declaring application's claim and keeps its execution authority" do
    context = { "root" => "/application/work" }
    call = start_call(executor_contexts: { @address.public_id => context })
    assert_equal "dispatched", call.status
    assert_equal @address, call.addressed_executor
    assert_nil Executor.address_for(@definition)
    assert_equal @definition, call.run.execution_agent
    assert_equal @definition, call.run.answering_user
    assert_equal context, Executors::Inbox.row(call).fetch(:executor_context)

    granted = claim(call)
    assert_predicate granted, :accepted?, granted.outcome.inspect
    call = granted.value
    operation = submit(call, key: "read", name: "application_read")
    assert_predicate operation, :accepted?
    assert_nil operation.value.dig("operation", "refusal")
    child = call.run.tasks.find_by!(node_key: operation.value.dig("operation", "receipt", "task_keys").sole)
    schedule_loop!(call.run)
    assert_equal @address, child.reload.addressed_executor
    assert_equal context, Executors::Inbox.row(child).fetch(:executor_context)
    child_claim = claim(child)
    assert_predicate child_claim, :accepted?
    assert_predicate commit(child_claim.value), :applied?

    refused = submit(call, key: "undeclared", name: "publisher_only_tool")
    assert_equal "unknown_tool_name", refused.value.dig("operation", "refusal", "code")
    context = MemoryDocuments::Context.new(workspace: @workspace, conversation: call.run.conversation,
      principal: @agent, agent: call.run.execution_agent,
      configuration: call.run.memory_context, execution: true)
    assert_equal @definition.public_id, context.projection.fetch(:bindings).find { |binding| binding[:scope] == "agent" }.fetch(:agent_public_id)
    2.times do
      observed = Executors::TaskOperations::Observe.new(access: access(call),
        after: Executors::TaskOperations::Trace.position(call)).call
      assert_predicate observed, :accepted?
      assert_not_nil observed.value.fetch("observation")
    end
    assert_predicate commit(call), :applied?
  end

  test "removing a named answerer fences new claims without revoking the declaring application" do
    call = start_call
    epoch = @address.credential_epoch
    assert_equal :removed, @definition.remove
    assert_equal epoch, @address.reload.credential_epoch
    assert_equal :ready, Executor.credential_readiness_for([@address]).fetch(@address.id)
    assert_predicate @agent.reload, :active?
    assert_equal :not_eligible, claim(call.run.reload.tasks.find(call.id)).outcome
  end

  test "a named answerer's explicit context must match its application context" do
    run = start_run(executor_contexts: { @address.public_id => { "root" => "/accepted" } })
    payload = { "type" => Tasks::ToolTask.sti_name, "tool_name" => "application_read",
                "operation_context" => { "executor_context" => { "root" => "/different" } } }
    assert_equal :executor_context_mismatch, Executors::Targets.prepare(run: run, payload: payload)
  end

  test "an application address does not serve an unrelated execution principal" do
    assert_not @address.eligible_for?(users(:member))
    assert_not @address.eligible_for?(users(:curator))
  end

  test "a steward transfer ends shared serving without changing either identity's history" do
    waiting = start_call
    running = claim(start_call).value
    epoch = @address.credential_epoch
    assert_equal :changed, @definition.change_steward(to: users(:member))
    assert_equal @agent, @definition.derived_from
    assert_nil Executor.application_address_for(@definition)
    assert_equal :not_eligible, claim(waiting.run.reload.tasks.find(waiting.id)).outcome
    fresh_running = running.run.reload.tasks.find(running.id)
    assert_equal :not_eligible, submit(fresh_running, key: "after-transfer", name: "application_read").outcome
    assert_equal epoch, @address.reload.credential_epoch
  end

  test "a named answerer's approval is an application notice and keeps the member decision" do
    @definition.update!(approval_mode: "ask")
    call = start_call
    assert_equal "needs_approval", call.status
    assert_equal @address, call.addressed_executor
    assert_equal :not_claimable_kind, claim(call).outcome
    assert_predicate Runs::Tasks::Approve.call(Runs::Tasks::Approve::Command.new(
      run: call.run, task_key: call.node_key, acting_user: @agent
    )), :accepted?
    assert_equal @agent, call.reload.approved_by_user
    assert_equal @address, call.addressed_executor
    assert_predicate claim(call), :accepted?
  end

  test "a named answerer's question reaches the declaring application as a notice" do
    @definition.update!(kernel_tools: ["nexus.human.ask"])
    run = start_run
    apply_via(loop_attempt(run), sse_success("asking", tool_calls: [
      { id: "question", name: "ask", arguments: { prompt: "Which result?" }.to_json },
    ]))
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [Runs::AskJob, Runs::ScheduleJob]) do
      Runs::ScheduleReady.call(run_id: run.id)
    end
    question = run.tasks.where(type: Tasks::AwaitTask.sti_name).sole
    assert_equal "awaiting_input", question.status
    assert_equal @address, question.addressed_executor
    assert_equal :not_claimable_kind, claim(question).outcome
  end

  test "a reconnected application serves the named answerer's next dispatch" do
    call = claim(start_call).value
    operation = submit(call, key: "read", name: "application_read")
    child = call.run.tasks.find_by!(node_key: operation.value.dig("operation", "receipt", "task_keys").sole)
    original_address = @address
    assert_equal :revoked, @agent.revoke_connection
    connection = connect_agent_session(steward: @agent.steward, agent_identifier: @agent.agent_identifier)
    assert_equal :minted, connection.outcome
    @address = connection.executor_access_token.executor
    announce_tools!(@agent, %w[application_work application_read])
    @address.reload
    schedule_loop!(call.run)
    assert_equal original_address, call.reload.addressed_executor
    assert_equal @address, child.reload.addressed_executor
    assert_predicate claim(child), :accepted?
    assert_equal @definition, child.run.answering_user
  end

  test "delegated compaction uses the application transport with the named principal" do
    @definition.update!(compaction_policy: { "mode" => "delegate", "tool_name" => "application_work" })
    run = start_run
    run_loop_round!(run, sse_success("A completed answer to summarize."))
    Conversations::Turns::Converge.call
    result = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
      conversation: run.conversation, acting_user: @agent, model: "dev/mock-text"
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    summary = result.value.turn.active_variant.run
    schedule_loop!(summary)
    delegate = summary.tasks.sole
    assert_equal "application_work", delegate.tool_name
    assert_equal @address, delegate.addressed_executor
    assert_equal @definition, summary.execution_agent
    assert_predicate claim(delegate), :accepted?
  end

  test "sharing application transport does not import the publisher's skill documents" do
    @definition.update!(kernel_tools: ["nexus.skill.load"])
    assert_predicate @address.announce(services: { @address.executor_kind => { "tools" => @address.tools_for(:agent) + [{
      "name" => "skill", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
    }], "documents" => [{ "name" => "private-handbook", "description" => "Publisher-only documents." }] } }), :accepted?

    [nil, { "bindings" => [{ "name" => "conversation", "source" => { "scope" => "conversation" }, "access" => "read_write" }] }].each do |limit|
      @definition.update!(memory_context_limit: limit)
      run = start_run
      round = run.tasks.sole
      catalog = Executors::TaskOperations::Context.defaults(round).dig("environment", "skills")
      assert_empty catalog
      assert_empty Executors::Targets.skills(run, [Nexus::Tools::SKILL])
      assert_not_includes round_request_entries(round).to_json, "private-handbook"
    end
  end

  private

    def start_call(**input)
      run = start_run(**input)
      run_loop_round!(run, sse_success("working", tool_calls: [
        { id: "application_call", name: "application_work", arguments: "{}" },
      ]))
      run.tasks.find_by!(tool_call_id: "application_call")
    end

    def start_run(**input)
      conversation = Conversation.create!(workspace: @workspace, creating_user: @agent, answering_user: @definition)
      _, run = materialize_loop_reply!(conversation, agent: @agent, **input)
      schedule_loop!(run)
      run
    end

    def claim(node)
      Executors::Claim.call(Executors::Claim::Command.new(run: node.run,
        task_key: node.node_key, executor: @address))
    end

    def submit(node, key:, name:)
      Executors::TaskOperations::Submit.new(access: access(node), key: key,
        request: { "kind" => "tool", "name" => name, "input" => {} }).call
    end

    def access(node)
      Executors::TaskOperations::Access.new(run: node.run, task_key: node.node_key,
        executor: @address, claim_token: node.claim_token)
    end

    def commit(node)
      Executors::Commit.call(Executors::Commit::Command.new(run: node.run,
        task_key: node.node_key, executor: @address, claim_token: node.claim_token,
        content: "Finished", structured_content: nil, result_type: nil, outcome: "completed",
        is_error: false, title: nil, metadata: nil))
    end
end
