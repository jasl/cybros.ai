require "test_helper"
require_relative "../../test_helpers/lock_order_test_helper"
require_relative "../../test_helpers/memory_collection_execution_test_helper"

class MemoryCollectionExecutionTest < ActiveJob::TestCase
  include LockOrderTestHelper
  include MemoryCollectionExecutionTestHelper

  test "ownership and a deleted default retain one stable identity" do
    first = Speakers::Resolve.member(account: @account, user: @human)
    second = Speakers::Resolve.member(account: @account, user: users(:owner))
    other = @account.users.create!(kind: "agent", display_name: "Other", handle: "memory-other", agent_identifier: "memory-other", steward: @human)
    collections = [MemoryCollection.default_for(@agent, speaker: first),
      MemoryCollection.default_for(@agent, speaker: second), MemoryCollection.default_for(other, speaker: first)]
    assert_equal 3, collections.map(&:id).uniq.size
    assert_equal [:speaker], collections.map(&:natural_scope).uniq
    invalid = @human.memory_collections.build(speaker: first)
    refute_predicate invalid, :valid?
    assert invalid.errors.of_kind?(:speaker, :invalid)
    invalid = @workspace.memory_collections.build(user: @human)
    refute_predicate invalid, :valid?
    assert invalid.errors.of_kind?(:base, :exactly_one_anchor)
    collection = MemoryCollection.default_for(@conversation)
    collection.update!(name: "private title", description: "private description")
    collection.tombstone
    same = MemoryCollection.default_for(@conversation)
    assert_equal collection.public_id, same.public_id
    assert_predicate same, :deleted?
    assert_nil same.name
    assert_nil same.description
  end
  test "accepted execution fixes a collection while the next input selects the replacement" do
    first = @workspace.memory_collections.create!(name: "First")
    second = @workspace.memory_collections.create!(name: "Second")
    write_collection(first, "first collection")
    write_collection(second, "second collection")
    bind(first)
    turn, run = open_turn
    assert_equal first.public_id, run.memory_context.fetch("bindings").first.fetch("capture").fetch("collection_public_id")
    assert_includes seed_text(run), "first collection"
    bind(second)
    call = memory_call(run, "memory_read", { path: "notes/fact.md" })
    assert_equal "first collection", call.output_body.effective_text
    settle(turn, run)
    _next_turn, next_run = open_turn
    assert_includes seed_text(next_run), "second collection"
    assert_equal second.public_id, next_run.memory_context.fetch("bindings").first.fetch("capture").fetch("collection_public_id")
  end

  test "deletion preserves sealed input and completion mail can create a new run with the deleted capture" do
    collection = @workspace.memory_collections.create!(name: "Shared")
    write_collection(collection, "already sealed fact")
    bind(collection)
    turn, run = open_turn
    captured = run.memory_context
    sealed = seed_text(run)
    collection.tombstone
    assert_nil run.reload.stopped_at
    assert_equal "running", run.status
    assert_equal sealed, seed_text(run)
    call = memory_call(run, "memory_read", { path: "notes/fact.md" })
    assert call.output_summary["is_error"]
    assert_includes call.output_body.effective_text, "memory_scope_unavailable"
    settle(turn, run)
    mailed = deliver_result(run)
    refute_equal run.public_id, mailed.public_id
    assert_equal captured, mailed.memory_context
    refute_includes seed_text(mailed), "## notes/fact.md"
    assert_includes seed_text(mailed), "background result"
    assert_nil mailed.stopped_at
    refute MemoryDocuments::Context.new(workspace: @workspace, conversation: @conversation,
      principal: @human, configuration: captured, agent: @agent, execution: true).documents.exists?
    selected = Conversations::SetMemoryContext.call(conversation: @conversation, acting_user: @human,
      memory_context: configuration(collection, name: "unavailable"))
    assert_equal :memory_scope_unavailable, selected.outcome
  end

  test "ordinary regeneration keeps a deleted capture but a new declaration reselects and refuses" do
    collection = @workspace.memory_collections.create!(name: "Shared")
    write_collection(collection, "source fact")
    bind(collection)
    turn, run = open_turn
    captured = run.memory_context
    settle(turn, run)
    collection.tombstone
    command = Conversations::Turns::Regenerate::Command.new(conversation: @conversation,
      turn_public_id: turn.public_id, acting_user: @human, provider_id: "dev", model_ref: "mock-priced",
      reasoning_effort: nil, request_options: nil)
    result = Conversations::Turns::Regenerate.call(command)
    assert_predicate result, :accepted?, result.outcome.to_s
    assert_equal captured, result.value.run.memory_context
    refute_includes seed_text(result.value.run), "## notes/fact.md"
    settle(turn, result.value.run)
    rejected = Conversations::Turns::Regenerate.call(command.with(agent_configuration: AgentConfiguration.capture(@agent)))
    assert_equal :memory_scope_unavailable, rejected.outcome
  end

  test "default deletion omits kernel memory without preventing a new ordinary input" do
    collection = MemoryCollection.default_for(@workspace)
    write_collection(collection, "deleted default")
    collection.tombstone
    _turn, run = open_turn
    refute_includes seed_text(run), "deleted default"
    workspace = run.memory_context.fetch("bindings").find { |binding| binding.fetch("name") == "workspace" }
    assert_equal collection.public_id, workspace.fetch("capture").fetch("collection_public_id")
    assert_equal 1, @workspace.memory_collections.where(is_default: true).count
  end

  test "archive and restore change live writability without rewriting captured access" do
    collection = @workspace.memory_collections.create!(name: "Shared")
    write_collection(collection, "original")
    collection.archive
    bind(collection)
    _turn, run = open_turn
    assert_equal "read_write", run.memory_context.fetch("bindings").first.fetch("access")
    call = memory_call(run, "memory_write", { path: "notes/fact.md", content: "forbidden" })
    assert call.output_summary["is_error"]
    assert_includes call.output_body.effective_text, "memory_read_only"
    collection.restore
    context = MemoryDocuments::Context.new(workspace: @workspace, conversation: @conversation,
      principal: @human, configuration: run.memory_context, agent: @agent, execution: true)
    assert_predicate context.resolve("notes/fact.md", authoring: true), :resolved?
    readonly = MemoryContext.from_h(run.memory_context)
    readonly = readonly.with(bindings: readonly.bindings.map { |binding| binding.with(access: :read) })
    context = MemoryDocuments::Context.new(workspace: @workspace, conversation: @conversation,
      principal: @human, configuration: readonly.to_h, agent: @agent, execution: true)
    assert_equal :memory_read_only, context.resolve("notes/fact.md", authoring: true).refusal
  end

  test "fork copies four lifecycle states and rewrites own selectors without widening access" do
    default = MemoryCollection.default_for(@conversation)
    active = @conversation.memory_collections.create!(name: "Active")
    archived = @conversation.memory_collections.create!(name: "Archived")
    deleted = @conversation.memory_collections.create!(name: "Deleted")
    shared = @workspace.memory_collections.create!(name: "Shared")
    [default, active, archived, deleted, shared].each { |collection| write_collection(collection, collection.name || "default") }
    archived.archive
    default.tombstone
    deleted.tombstone
    bindings = [active, archived, deleted, shared].each_with_index.map do |collection, index|
      configuration(collection, name: "root#{index}").fetch("bindings").first
    end
    bindings << configuration(archived, name: "readonly", access: "read").fetch("bindings").first
    bindings << { "name" => "self_alias", "access" => "read_write", "source" => { "scope" => "conversation", "conversation_public_id" => @conversation.public_id } }
    @conversation.update!(memory_context: { "bindings" => bindings })
    child = fork_side
    assert_equal 3, child.memory_collections.count
    assert_predicate child.memory_collections.find_by!(is_default: true), :deleted?
    assert_equal 2, child.memory_documents.count
    copied = child.memory_collections.find_by!(name: "Archived")
    assert_predicate copied, :archived?
    refute_equal archived.public_id, copied.public_id
    assert_equal archived.memory_documents.sole.memory_document_version_id, copied.memory_documents.sole.memory_document_version_id
    selected = child.memory_context.fetch("bindings")
    assert_equal copied.public_id, selected[1].fetch("source").fetch("collection_public_id")
    assert_equal "read_write", selected[1].fetch("access")
    assert_equal "read", selected[4].fetch("access")
    assert_equal deleted.public_id, selected[2].fetch("source").fetch("collection_public_id")
    assert_equal shared.public_id, selected[3].fetch("source").fetch("collection_public_id")
    assert_equal child.public_id, selected[5].fetch("source").fetch("conversation_public_id")
    copied.restore
    context = MemoryDocuments::Context.new(workspace: @workspace, conversation: child, principal: @human,
      configuration: child.memory_context, agent: @agent)
    assert_predicate context.resolve("root1/fact.md", authoring: true), :resolved?
    assert_equal :memory_read_only, context.resolve("readonly/fact.md", authoring: true).refusal
    active.tombstone
    assert_equal "Active", child.memory_collections.find_by!(name: "Active").memory_documents.sole.content
  end

  test "provider scope survives kernel deletion and already dispatched tasks keep their address across override changes" do
    first = memory_provider("first")
    second = memory_provider("second")
    collection = MemoryCollection.default_for(@workspace)
    write_collection(collection, "kernel fact")
    _turn, run = open_turn
    captured = run.memory_context
    collection.archive
    collection.tombstone
    override(first)
    call = memory_call(run, "memory_write", { path: "workspace/fact.md", content: "external fact" })
    assert_equal "dispatched", call.status
    assert_equal first.id, call.addressed_executor_id
    stamp = Executors::Inbox.scope_of(call).fetch(:bindings).find { |entry| entry.fetch(:name) == "workspace" }
    assert_equal @workspace.public_id, stamp.fetch(:workspace_public_id)
    assert_equal "read_write", stamp.fetch(:access)
    refute stamp.key?(:collection_public_id)
    override(second)
    assert_equal first.id, call.reload.addressed_executor_id
    claimed = Executors::Claim.call(Executors::Claim::Command.new(run: run, task_key: call.node_key, executor: first))
    assert_predicate claimed, :accepted?, claimed.outcome.to_s
    commit_provider(call, first, claimed.value.claim_token, "first provider result")
    schedule_loop!(run)
    next_call = memory_call(run, "memory_read", { path: "workspace/fact.md" })
    assert_equal second.id, next_call.addressed_executor_id
    claimed = Executors::Claim.call(Executors::Claim::Command.new(run: run, task_key: next_call.node_key, executor: second))
    assert_predicate claimed, :accepted?, claimed.outcome.to_s
    commit_provider(next_call, second, claimed.value.claim_token, "second provider result")
    override(nil)
    schedule_loop!(run)
    kernel = memory_call(run, "memory_read", { path: "workspace/fact.md" })
    assert kernel.output_summary["is_error"]
    assert_includes kernel.output_body.effective_text, "memory_scope_unavailable"
    assert_equal captured, run.reload.memory_context
    assert_equal 1, @workspace.memory_collections.where(is_default: true).count
  end

  test "precise sources reject all six provider verbs while completion mail still creates its reply" do
    collection = @workspace.memory_collections.create!(name: "Exact")
    write_collection(collection, "exact fact")
    bind(collection)
    turn, run = open_turn
    captured = run.memory_context
    override(memory_provider("precise"))
    calls = Nexus::ToolRegistry.wire_names_in("nexus.memory").map do |name|
      { id: "call_#{name}", name: name, arguments: { path: "notes/fact.md", content: "x", pattern: "x" }.to_json }
    end
    calls.find { |call| call.fetch(:name) == "memory_ls" }[:arguments] = "{}"
    run_loop_round!(run, sse_success("memory calls", tool_calls: calls))
    rows = run.tasks.where(tool_call_id: calls.map { |call| call.fetch(:id) })
    assert_equal 6, rows.count
    rows.each do |call|
      assert_equal "failed", call.status
      assert_equal "memory_collection_provider_unsupported", call.error_key
      assert_nil call.addressed_executor_id
    end
    settle(turn, run)
    mailed = deliver_result(run)
    assert_equal captured, mailed.memory_context
    refute_includes seed_text(mailed), "## notes/fact.md"
    assert_includes seed_text(mailed), "background result"
    result = Conversations::SetMemoryContext.call(conversation: @conversation, acting_user: @human,
      memory_context: configuration(collection, name: "renamed"))
    assert_equal :memory_collection_provider_unsupported, result.outcome
  end

  test "conversation archive permits accepted work but collection archive still refuses writes" do
    collection = MemoryCollection.default_for(@conversation)
    write_collection(collection, "before")
    turn, run = open_turn
    refused = Conversations::Tombstone.call(conversation: @conversation)
    assert_equal :conversation_busy, refused.outcome
    archived = Conversations::Archive.call(conversation: @conversation)
    assert_predicate archived, :accepted?
    assert_equal "running", run.reload.status
    call = memory_call(run, "memory_write", { path: "conversation/fact.md", content: "after archive" })
    refute call.output_summary["is_error"], call.output_body.effective_text
    assert_equal "after archive", collection.memory_documents.sole.content
    collection.archive
    schedule_loop!(run)
    denied = memory_call(run, "memory_write", { path: "conversation/fact.md", content: "forbidden" })
    assert denied.output_summary["is_error"]
    assert_includes denied.output_body.effective_text, "memory_read_only"
    collection.tombstone
    assert_nil run.reload.stopped_at
    settle(turn, run)
    mailed = deliver_result(run)
    assert_predicate mailed, :persisted?
    assert_nil mailed.stopped_at
  end

  test "collection deletion does not wait for a paused run" do
    collection = @workspace.memory_collections.create!(name: "Paused")
    bind(collection)
    _turn, run = open_turn
    result = Runs::Pause.call(Runs::Pause::Command.graceful(run: run, acting_user: @human))
    assert_predicate result, :accepted?
    collection.tombstone
    assert_equal "paused", run.reload.status
    assert_nil run.stopped_at
    assert_predicate collection.reload, :deleted?
  end

  test "collection deletion leaves a failed run on its existing attention hold" do
    collection = @workspace.memory_collections.create!(name: "Held")
    bind(collection)
    _turn, run = open_turn
    run_loop_round!(run, json_response(400, { "error" => "model refused" }))
    assert_equal "needs_attention", run.reload.status
    reason = run.attention_reason
    collection.tombstone
    assert_equal "needs_attention", run.reload.status
    assert_equal reason, run.attention_reason
    assert_nil run.stopped_at
    assert_predicate collection.reload, :deleted?
  end

  test "collection deletion leaves an existing approval request intact" do
    declare_tools!(@agent, tools: [Nexus::ToolRegistry.function_definition("memory_write")], approval_mode: "ask")
    collection = @workspace.memory_collections.create!(name: "Approval")
    bind(collection)
    _turn, run = open_turn
    call = memory_call(run, "memory_write", { path: "notes/fact.md", content: "needs approval" })
    assert_equal "needs_approval", call.status
    collection.tombstone
    assert_equal "needs_approval", call.reload.status
    assert_nil call.approval_decided_at
    assert_nil run.reload.stopped_at
    assert_predicate collection.reload, :deleted?
  end

  test "same collection aliases keep independent write ceilings and injection is deduplicated" do
    collection = @workspace.memory_collections.create!(name: "Aliases")
    write_collection(collection, "one injected fact")
    bindings = configuration(collection, name: "readonly", access: "read").fetch("bindings") +
      configuration(collection, name: "writable").fetch("bindings")
    @conversation.update!(memory_context: { "bindings" => bindings })
    _turn, run = open_turn
    assert_equal 1, seed_text(run).scan("one injected fact").length
    context = MemoryDocuments::Context.new(workspace: @workspace, conversation: @conversation,
      principal: @human, configuration: run.memory_context, agent: @agent, execution: true)
    assert_equal :memory_read_only, context.resolve("readonly/fact.md", authoring: true).refusal
    assert_predicate context.resolve("writable/fact.md", authoring: true), :resolved?
    limit = { "bindings" => [{ "name" => "conversation", "source" => { "scope" => "conversation" }, "access" => "read_write" }] }
    narrowed = MemoryContext.constrain(configuration: run.memory_context, limit: limit, conversation_public_id: @conversation.public_id)
    assert_empty narrowed.fetch("bindings")
  end

  test "precise UUIDs and reserved roots cannot grant a different owner authority" do
    other_agent = @account.users.create!(kind: "agent", display_name: "Other", handle: "memory-other", agent_identifier: "memory-other", steward: @human)
    private_collections = [MemoryCollection.default_for(other_agent), MemoryCollection.default_for(users(:owner)),
      MemoryCollection.default_for(workspaces(:personal))]
    private_collections.each do |collection|
      result = Conversations::SetMemoryContext.call(conversation: @conversation.reload, acting_user: @human,
        memory_context: configuration(collection))
      assert_equal :memory_scope_unavailable, result.outcome
    end
    result = Conversations::SetMemoryContext.call(conversation: @conversation.reload, acting_user: @human,
      memory_context: configuration(MemoryCollection.default_for(@workspace), name: "conversation"))
    assert_equal :memory_scope_unavailable, result.outcome
    assert_nil @conversation.reload.memory_context
  end

  test "owner lifecycle makes an external source unavailable without canceling the consumer" do
    owner = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    collection = MemoryCollection.default_for(owner)
    write_collection(collection, "source owner fact")
    bind(collection)
    _turn, run = open_turn
    deleted = Conversations::Tombstone.call(conversation: owner)
    assert_predicate deleted, :accepted?
    call = memory_call(run, "memory_read", { path: "notes/fact.md" })
    assert call.output_summary["is_error"]
    assert_includes call.output_body.effective_text, "memory_scope_unavailable"
    assert_nil run.reload.stopped_at
    assert_equal "running", run.status
  end

  test "kernel skill capture survives override but never retargets a replaced document" do
    tools = Nexus::ToolRegistry.wire_names_in("nexus.memory").map { |name| Nexus::ToolRegistry.function_definition(name) }
    declare_tools!(@agent, tools: tools + [Nexus::ToolRegistry.function_definition("skill")])
    collection = @workspace.memory_collections.create!(name: "Skills")
    document = write_collection(collection, "captured skill", name: "skills/checks", description: "Run checks")
    bind(collection)
    turn, run = open_turn
    captured = run.memory_context
    catalog = run.tasks.find_by!(node_key: "r1").operation_context.fetch("environment").fetch("skills")
    assert_equal collection.public_id, catalog.sole.fetch("collection_public_id")
    assert_equal document.public_id, catalog.sole.fetch("document_public_id")
    override(memory_provider("skills"))
    settle(turn, run)
    mailed = deliver_result(run)
    assert_equal captured, mailed.memory_context
    schedule_loop!(mailed)
    call = memory_call(mailed, "skill", { name: "checks" })
    Runs::Memory::Run.call(node: call) if call.status == "running"
    assert_equal "captured skill", call.reload.output_body.effective_text
    document.destroy!
    write_collection(collection, "replacement skill", name: "skills/checks", description: "Run checks")
    schedule_loop!(mailed)
    replaced = memory_call(mailed, "skill", { name: "checks" })
    Runs::Memory::Run.call(node: replaced) if replaced.status == "running"
    assert replaced.reload.output_summary["is_error"]
    assert_includes replaced.output_body.effective_text, "skill_unknown"
  end

  test "model writes collection lifecycle and fork follow the lock ladder" do
    collection = @workspace.memory_collections.create!(name: "Lock order")
    bind(collection)
    _turn, run = open_turn
    call = memory_call(run, "memory_write", { path: "notes/fact.md", content: "new fact" }, execute: false)
    assert_ladder_order("model memory collection write") { Runs::MemoryJob.perform_now(call.id) }
    refute call.reload.output_summary["is_error"], call.output_body.effective_text
    assert_ladder_order("collection tombstone") { collection.tombstone }
    assert_ladder_order("collection fork") { fork_side }
  end

  test "group materialization captures each answerer and subject independently" do
    other = @account.users.create!(kind: "agent", display_name: "Other", handle: "memory-other", agent_identifier: "memory-other", steward: @human)
    MemoryCollection.default_for(other)
    declare_tools!(other, tools: [Nexus::ToolRegistry.function_definition("memory_read")])
    second_human = users(:owner)
    first = Speakers::Resolve.member(account: @account, user: @human)
    second = Speakers::Resolve.member(account: @account, user: second_human)
    cases = [[@agent, @human, first, "A S1"], [@agent, second_human, second, "A S2"], [other, @human, first, "B S1"]]
    cases.each do |agent, _human, speaker, content|
      write_collection(MemoryCollection.default_for(agent, speaker: speaker), content)
    end
    captured = []
    cases.each do |agent, human, speaker, content|
      turn, run = materialize_loop_reply!(@conversation, agent: human, answering_user_public_id: agent.public_id)
      schedule_loop!(run)
      binding = run.memory_context.fetch("bindings").find { |entry| entry.fetch("name") == "speaker" }
      assert_equal agent.public_id, binding.fetch("capture").fetch("owner_public_id")
      assert_equal speaker.public_id, binding.fetch("capture").fetch("speaker_public_id")
      assert_includes seed_text(run), content
      (cases.map(&:last) - [content]).each { |text| refute_includes seed_text(run), text }
      captured << binding.fetch("capture").fetch("collection_public_id")
      settle(turn, run)
    end
    assert_equal 3, captured.uniq.size
  end

  test "queued new selection refuses a deleted explicit source without minting a run" do
    collection = @workspace.memory_collections.create!(name: "Queued")
    bind(collection)
    input = post_input!(@conversation, acting_user: @human, kind: "direct_reply", text: "later",
      provider_id: "dev", model_ref: "mock-text")
    collection.tombstone
    assert_no_difference("Run.count") { Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id) }
    assert_equal "blocked", input.reload.state
    assert_empty @conversation.turns
  end

  test "the same deleted default works through provider scope but its exact UUID cannot be newly selected" do
    collection = MemoryCollection.default_for(@workspace)
    collection.tombstone
    provider = memory_provider("scope-default")
    override(provider)
    selected = Conversations::SetMemoryContext.call(conversation: @conversation, acting_user: @human,
      memory_context: { "bindings" => [{ "name" => "workspace", "access" => "read_write", "source" => { "scope" => "workspace" } }] })
    assert_predicate selected, :accepted?, selected.outcome.to_s
    _turn, run = open_turn
    assert_equal collection.public_id, run.memory_context.fetch("bindings").sole.fetch("capture").fetch("collection_public_id")
    call = memory_call(run, "memory_read", { path: "workspace/fact.md" })
    assert_equal provider.id, call.addressed_executor_id
    rejected = Conversations::SetMemoryContext.call(conversation: @conversation, acting_user: @human,
      memory_context: configuration(collection))
    assert_equal :memory_collection_provider_unsupported, rejected.outcome
  end

  test "a withdrawn provider fails its next tool without falling back to kernel content" do
    collection = MemoryCollection.default_for(@workspace)
    write_collection(collection, "must not fall back")
    provider = memory_provider("withdrawn")
    override(provider)
    _turn, run = open_turn
    provider.revoke
    call = memory_call(run, "memory_read", { path: "workspace/fact.md" })
    assert_equal "failed", call.status
    assert_equal "tool_not_served", call.error_key
    assert_nil call.addressed_executor_id
  end

  test "fork counts collections before allocation and refuses an oversized copy atomically" do
    rows = Array.new(Conversations::Fork::MAX_OVERLAY_SEED) { { account_id: @account.id, conversation_id: @conversation.id } }
    MemoryCollection.insert_all!(rows)
    assert_no_difference("Conversation.count") do
      result = Conversations::Fork.call(Conversations::Fork::Command.new(conversation: @conversation,
        acting_user: @human, turn_public_id: nil, variant_public_id: nil, title: "Too large", side: true))
      assert_equal :fork_too_large, result.outcome
    end
  end

  test "read projection does not allocate an absent speaker default" do
    subject = Speakers::Resolve.member(account: @account, user: @human)
    configuration = MemoryContext.capture(configuration: nil, speaker: subject)
    assert_no_difference("MemoryCollection.count") do
      context = MemoryDocuments::Context.new(workspace: @workspace, conversation: @conversation,
        principal: @human, configuration: configuration, agent: @agent)
      assert_equal :memory_scope_unavailable, context.resolve("speaker/fact.md").refusal
      context.listing
    end
  end

  test "an absent default remains absent in an accepted capture even if it is allocated later" do
    MemoryCollection.default_for(@workspace).destroy!
    turn, run = open_turn
    captured = run.memory_context
    entry = captured.fetch("bindings").find { |binding| binding.fetch("name") == "workspace" }
    assert_nil entry.fetch("capture").fetch("collection_public_id")
    collection = MemoryCollection.default_for(@workspace)
    write_collection(collection, "allocated after capture")
    call = memory_call(run, "memory_read", { path: "workspace/fact.md" })
    assert call.output_summary["is_error"]
    assert_includes call.output_body.effective_text, "memory_scope_unavailable"
    assert_equal captured, run.reload.memory_context
    settle(turn, run)
    _next_turn, next_run = open_turn
    assert_includes seed_text(next_run), "allocated after capture"
  end

  test "standalone creation captures workspace memory without a conversation source" do
    collection = MemoryCollection.default_for(@workspace)
    write_collection(collection, "standalone fact")
    result = Runs::Create.call(Runs::Create::Command.new(workspace: @workspace, creating_user: @human,
      steps: [model("r1", "prompt" => "use memory", "tools" => [Nexus::ToolRegistry.function_definition("memory_read")])],
      billing_subject: nil, idempotency_key: nil, prompt_mechanism: "default", approval_mode: "bypass"))
    assert_predicate result, :created?, result.outcome.to_s
    run = result.run
    assert_predicate run, :standalone?
    assert_equal ["workspace"], run.memory_context.fetch("bindings").map { |binding| binding.fetch("name") }
    assert_equal collection.public_id, run.memory_context.fetch("bindings").sole.fetch("capture").fetch("collection_public_id")
    assert_includes seed_text(run), "standalone fact"
    started = Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human))
    assert_predicate started, :accepted?, started.outcome.to_s
    schedule_loop!(run)
    call = memory_call(run, "memory_read", { path: "workspace/fact.md" })
    assert_equal "standalone fact", call.output_body.effective_text
  end

  test "standalone explicit collections are captured and create replay cannot change the selection" do
    first = @workspace.memory_collections.create!(name: "First")
    second = @workspace.memory_collections.create!(name: "Second")
    write_collection(first, "selected standalone")
    command = Runs::Create::Command.new(workspace: @workspace, creating_user: @human,
      steps: [model("r1", "prompt" => "read selected")], billing_subject: nil, idempotency_key: "memory-choice",
      prompt_mechanism: "default", approval_mode: "bypass", memory_context: configuration(first))
    created = Runs::Create.call(command)
    assert_predicate created, :created?, created.outcome.to_s
    assert_includes seed_text(created.run), "selected standalone"
    first.tombstone
    assert_predicate Runs::Create.call(command), :replayed?
    assert_equal :idempotency_envelope_mismatch, Runs::Create.call(command.with(memory_context: configuration(second))).outcome
    assert_equal :memory_scope_unavailable, Runs::Create.call(command.with(idempotency_key: nil)).outcome
  end

  test "preview reads the same selection without creating a Speaker default and direct replies capture it" do
    declare_tools!(@agent, tools: [])
    subject = Speakers::Resolve.member(account: @account, user: @human)
    write_collection(MemoryCollection.default_for(@workspace), "preview fact")
    command = Conversations::ContextEstimate::Command.new(conversation: @conversation,
      acting_user: @human, provider_id: "dev", model_ref: "mock-text", reasoning_effort: nil,
      request_options: nil, prompt: "use memory", history_max_entries: nil, history_token_budget_share: nil,
      reasoning_replay_mode: nil, inline: nil, render: true)
    assert_no_difference("MemoryCollection.count") do
      estimate = Conversations::ContextEstimate.call(command)
      assert_predicate estimate, :accepted?, estimate.outcome.to_s
      assert_includes estimate.value.rendered.entries.to_json, "preview fact"
    end
    refute @agent.memory_collections.exists?(speaker: subject)
    post_input!(@conversation, acting_user: @human, text: "use memory", kind: "direct_reply",
      provider_id: "dev", model_ref: "mock-text")
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    variant = @conversation.turns.order(:id).last.active_variant
    assert_nil variant.run
    capture = variant.memory_context.fetch("bindings").find { |binding| binding.fetch("name") == "speaker" }.fetch("capture")
    assert_equal MemoryCollection.default_for(@agent, speaker: subject).public_id, capture.fetch("collection_public_id")

    exact = @workspace.memory_collections.create!(name: "Exact")
    @conversation.reload.update!(memory_context: configuration(exact))
    exact.tombstone
    assert_equal :memory_scope_unavailable, Conversations::ContextEstimate.call(command).outcome
    exact = @workspace.memory_collections.create!(name: "Provider unsupported")
    @conversation.reload.update!(memory_context: configuration(exact))
    override(memory_provider("preview"))
    assert_equal :memory_collection_provider_unsupported, Conversations::ContextEstimate.call(command).outcome
  end

  test "actual spawn and send rebind relative owners but keep the originating Speaker" do
    memory_tools = Nexus::ToolRegistry.wire_names_in("nexus.memory").map { |name| Nexus::ToolRegistry.function_definition(name) }
    declare_tools!(@agent, tools: memory_tools + %w[spawn send].map { |name| Nexus::ToolRegistry.function_definition(name) })
    receiver = create_agent_member(display_name: "Receiver")
    MemoryCollection.default_for(receiver)
    declare_tools!(receiver, tools: memory_tools)
    _turn, source = open_turn
    subject = source.memory_context.fetch("bindings").find { |entry| entry.fetch("name") == "speaker" }.dig("source", "speaker_public_id")
    call = memory_call(source, "spawn", { prompt: "remember", agent: receiver.public_id }, execute: false)
    Runs::ConversationToolJob.perform_now(call.id)
    refute call.reload.output_summary["is_error"], call.output_body&.effective_text
    child = call.spawned_conversation
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    child_run = child.turns.order(:id).last.active_variant.run
    captures = child_run.memory_context.fetch("bindings").index_by { |entry| entry.fetch("name") }
    assert_equal child.public_id, captures.fetch("conversation").dig("capture", "owner_public_id")
    assert_equal receiver.public_id, captures.fetch("agent").dig("capture", "owner_public_id")
    assert_equal receiver.public_id, captures.fetch("speaker").dig("capture", "owner_public_id")
    assert_equal subject, captures.fetch("speaker").dig("capture", "speaker_public_id")
    assert_equal 1, child.memory_collections.count

    target = Conversations::Create.call(Conversations::Create::Command.new(workspace: @workspace,
      creating_user: @human, answering_user_public_id: receiver.public_id,
      title: nil, metadata: nil, billing_subject: nil)).value
    schedule_loop!(source)
    sent = memory_call(source, "send", { to: target.public_id, message: "remember again" }, execute: false)
    Runs::ConversationToolJob.perform_now(sent.id)
    refute sent.reload.output_summary["is_error"], sent.output_body&.effective_text
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: target.id)
    target_run = target.turns.order(:id).last.active_variant.run
    selected = target_run.memory_context.fetch("bindings").find { |entry| entry.fetch("name") == "speaker" }
    assert_equal captures.fetch("speaker").fetch("capture"), selected.fetch("capture")
    schedule_loop!(target_run)
    wrote = memory_call(target_run, "memory_write", { path: "speaker/fact.md", content: "receiver notes" })
    refute wrote.output_summary["is_error"], wrote.output_body.effective_text
    assert_equal "receiver notes", MemoryCollection.find_by!(public_id: selected.dig("capture", "collection_public_id")).memory_documents.sole.content
  end

  test "spawn keeps an exact shared collection and cannot recreate an unavailable relative source" do
    tools = %w[memory_read spawn].map { |name| Nexus::ToolRegistry.function_definition(name) }
    declare_tools!(@agent, tools: tools)
    shared = @workspace.memory_collections.create!(name: "Shared")
    write_collection(shared, "shared across spawn")
    bindings = MemoryContext::DEFAULT.to_h
    bindings.fetch("bindings") << configuration(shared).fetch("bindings").sole
    @conversation.update!(memory_context: bindings)
    _turn, source = open_turn
    MemoryCollection.default_for(@conversation).tombstone
    call = memory_call(source, "spawn", { prompt: "read shared" }, execute: false)
    Runs::ConversationToolJob.perform_now(call.id)
    refute call.reload.output_summary["is_error"], call.output_body&.effective_text
    child = call.spawned_conversation
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    child_run = child.turns.order(:id).last.active_variant.run
    refute child_run.memory_context.fetch("bindings").any? { |binding| binding.fetch("name") == "conversation" }
    exact = child_run.memory_context.fetch("bindings").find { |binding| binding.fetch("name") == "notes" }
    assert_equal shared.public_id, exact.dig("capture", "collection_public_id")
    assert_includes seed_text(child_run), "shared across spawn"
  end

  test "schedules copy the current parent choice at dispatch and capture at first materialization" do
    first = @workspace.memory_collections.create!(name: "First")
    second = @workspace.memory_collections.create!(name: "Second")
    write_collection(first, "first scheduled choice")
    write_collection(second, "second scheduled choice")
    bind(first)
    at = DatabaseClock.now + 60
    created = Schedules::Create.call(conversation: @conversation, creating_user: @human, attributes: {
      prompt: "scheduled", provider_id: "dev", model_ref: "mock-text",
      rule: { "kind" => "once", "run_at" => at.iso8601(6) },
    })
    assert_predicate created, :accepted?
    job = created.value
    assert_equal :dispatched, Schedules::Dispatch.call(id: job.id, by: @human, cutoff: at)
    child = job.reload.last_execution_conversation
    bind(second)
    assert_equal first.public_id, child.memory_context.dig("bindings", 0, "source", "collection_public_id")
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    first_run = child.turns.order(:id).last.active_variant.run
    assert_equal first.public_id, first_run.memory_context.dig("bindings", 0, "capture", "collection_public_id")
    assert_includes seed_text(first_run), "first scheduled choice"
    first.tombstone
    settle(child.turns.order(:id).last, first_run)
    assert_equal :dispatched, Schedules::Dispatch.call(id: job.id, by: @human, cutoff: at + 60)
    next_child = job.reload.last_execution_conversation
    assert_equal second.public_id, next_child.memory_context.dig("bindings", 0, "source", "collection_public_id")
    second.tombstone
    assert_equal 0, Conversations::Inputs::ApplyNext.drain(conversation_id: next_child.id)
    assert_equal "memory_scope_unavailable", next_child.inputs.sole.blocked_reason
    assert_empty next_child.turns
    assert_nil first_run.reload.stopped_at
  end

  test "kernel mail without a retained memory capture never selects current defaults" do
    collection = @workspace.memory_collections.create!(name: "Current")
    write_collection(collection, "must not be added to mail")
    bind(collection)
    turn, source = open_turn
    source.variant.update!(memory_context: nil)
    settle(turn, source)
    mailed = deliver_result(source)
    assert_equal({ "bindings" => [] }, mailed.memory_context)
    refute_includes seed_text(mailed), "## notes/fact.md"
  end

  test "physical source owner collection neither waits for nor stops an external active consumer" do
    owner = Conversations::Create.call(Conversations::Create::Command.new(workspace: @workspace,
      creating_user: @human, title: nil, metadata: nil, billing_subject: nil)).value
    collection = MemoryCollection.default_for(owner)
    write_collection(collection, "external owner's fact")
    bind(collection)
    _turn, run = open_turn
    sealed = seed_text(run)
    assert_predicate Conversations::Tombstone.call(conversation: owner), :accepted?
    owner.reload.update!(tombstoned_at: (Conversation::RETENTION_PERIOD + 1.day).ago)
    result = Conversations::Reap.call(batch: 2).value
    assert_equal [1, 2], [result[:reaped], result[:memory_processed]]
    refute Conversation.exists?(owner.id)
    refute MemoryCollection.exists?(collection.id)
    assert_equal "running", run.reload.status
    assert_nil run.stopped_at
    assert_equal sealed, seed_text(run)
    call = memory_call(run, "memory_read", { path: "notes/fact.md" })
    assert call.output_summary["is_error"]
    assert_includes call.output_body.effective_text, "memory_scope_unavailable"
  end

  test "first-use default preparation follows the lock ladder and captures the rechecked head" do
    post_input!(@conversation, acting_user: @human, text: "first subject", kind: "direct_reply",
      provider_id: "dev", model_ref: "mock-text")
    result = nil
    sequences = assert_ladder_order("first-use Speaker default") do
      result = Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
    end
    assert_predicate result, :accepted?, result.outcome.to_s
    assert_includes sequences.flatten, "users"
    assert_includes sequences.flatten, "conversations"
    subject = result.value.speaker
    selected = result.value.active_variant.memory_context.fetch("bindings").find { |entry| entry.fetch("name") == "speaker" }
    assert_equal subject.public_id, selected.dig("capture", "speaker_public_id")
    assert_equal 1, @agent.memory_collections.where(speaker: subject).count
  end

  private

    def fork_side
      result = Conversations::Fork.call(Conversations::Fork::Command.new(conversation: @conversation,
        acting_user: @human, turn_public_id: nil, variant_public_id: nil, title: "Copied", side: true))
      assert_predicate result, :accepted?, result.outcome.to_s
      result.value
    end

    def memory_provider(identifier)
      connect_provider(identifier: identifier, tools: Nexus::ToolRegistry.wire_names_in("nexus.memory").map do |name|
        { "name" => name, "effect_profile" => Nexus::ToolRegistry.effect_profile_for(name), "timeout_ms" => 20_000 }
      end)
    end

    def override(provider)
      result = Workspaces::SetToolProviderOverrides.call(workspace: @workspace, by: users(:owner),
        lock_version: @workspace.reload.lock_version, overrides: provider ? { "nexus.memory" => provider.public_id } : {})
      assert_equal :updated, result.outcome
    end

    def commit_provider(call, provider, token, content)
      result = Executors::Commit.call(Executors::Commit::Command.new(run: call.run, task_key: call.node_key,
        executor: provider, claim_token: token, content: content, result_type: nil, outcome: "completed",
        is_error: false, title: nil, metadata: nil))
      assert_equal :applied, result.outcome
    end
end
