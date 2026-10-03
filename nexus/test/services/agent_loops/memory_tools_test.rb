require "test_helper"

# THE SIX VERBS, through the real chain: a loop declares them, the
# scheduler parks the task and dispatches it to the kernel executor, and
# the answer settles onto the node the model will read next round.
class AgentLoops::MemoryToolsTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
  end

  # THE REAL PATH, and there is no shortcut: a client may not author a task naming a kernel tool
  # (`reserved_tool_name`), so a memory task exists only because a MODEL declared the tool and
  # called it, and the round driver fanned it. One loop per call, reused across calls so a test can
  # write and then read. The six memory verbs and the `skill` load: the kernel-row branch of the
  # load runs through this same executor.
  def memory_round
    model("ask", "prompt" => "use memory",
      "tools" => Nexus::ToolRegistry::LIVE.filter_map do |canonical, tool|
        next unless canonical.start_with?("nexus.memory.") || canonical == "nexus.skill.load"

        { "type" => "function", "function" => tool.wire_schema }
      end)
  end

  # The same round behind a loop-backed turn (the seam fixture): the loop is born running, so its
  # seed is appended and scheduled. `acting_user` is the TURN's principal — `creating_user` on the
  # loop — and may differ from the conversation's creator (the Human-B case).
  def loop_backed!(creating_user: @human, acting_user: creating_user, conversation: nil)
    conversation ||= Conversation.create!(workspace: @workspace, creating_user: creating_user)
    seam = create_loop_backed_turn(conversation: conversation, acting_user: acting_user)
    appended = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.authored(
      agent_loop: seam.agent_loop, steps: [memory_round]
    ))
    assert_predicate appended, :applied?
    schedule!(seam.agent_loop)
    @agent_loop = seam.agent_loop
    conversation
  end

  # A standalone loop for a given principal; switching loops restarts the
  # round key, since each loop's seed round is its own "ask".
  def standalone!(creating_user: @human)
    loop_record = seed(memory_round, creating_user: creating_user)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(
      agent_loop: loop_record, acting_user: creating_user
    ))
    schedule!(loop_record)
    @round = nil
    @agent_loop = loop_record
  end

  def run_tool!(name, input)
    @agent_loop ||= standalone!
    @round = @round ? next_round_key : "ask"
    apply_via(step_attempt(@agent_loop, @round), sse_success("calling", tool_calls: [
      { id: "call_#{@calls = @calls.to_i + 1}", name: name, arguments: JSON.generate(input) },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(@agent_loop)

    node = @agent_loop.agent_loop_nodes.where(tool_name: name).order(:id).last
    # A KERNEL TOOL STAYS `running`: nexus is executing it in its own job,
    # so nobody outside the kernel is being waited on. Only a call
    # advertised to a runner becomes `dispatched`. This is the executor arm
    # of that discriminator, and the only pin it has.
    assert_equal "running", node.status, "a kernel tool is the kernel doing it"
    # A hook between the fan and the kernel's run, for a pin that must
    # change the loop's row after the scheduler has already admitted the round.
    yield if block_given?
    AgentLoops::Memory::Run.call(node: node)
    # What MemoryJob does after the executor settles: the fan is answered,
    # so the continuation is ready and the next call has a round to make.
    schedule!(@agent_loop)
    node.reload
  end

  def next_round_key
    @agent_loop.agent_loop_nodes.where("node_key LIKE 'r%' AND node_key NOT LIKE '%t%'")
      .order(:id).last.node_key
  end

  def schedule!(agent_loop) = AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)

  def step_attempt(agent_loop, key)
    invocation_id = agent_loop.agent_loop_nodes.find_by!(node_key: key)
      .selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  def output(node) = node.content_bodies.find_by(role: "output")&.effective_text.to_s
  def errored?(node) = node.output_summary["is_error"] == true

  test "write then read round-trips through the kernel executor" do
    written = run_tool!("memory_write",
      { "path" => "workspace/notes.md", "content" => "the plan" })
    refute errored?(written), output(written)
    assert_equal "Wrote workspace/notes.md (8 bytes).", output(written)

    read = run_tool!("memory_read", { "path" => "workspace/notes.md" })
    refute errored?(read)
    assert_equal "the plan", output(read)
    listed = run_tool!("memory_ls", { "path" => "workspace/" })
    assert_match(/\Aworkspace\/notes\.md  8 bytes  \d{4}-/, output(listed))
    refute_match(/public_id|lock_version/, output(listed))
  end

  test "memory mutation schemas use ordinary document arguments" do
    {
      "nexus.memory.write" => %w[path content],
      "nexus.memory.edit" => %w[path old_text new_text],
      "nexus.memory.delete" => ["path"],
    }.each do |canonical, arguments|
      parameters = Nexus::ToolRegistry::LIVE.fetch(canonical).wire_schema.fetch("parameters")
      assert_equal arguments, parameters.fetch("required")
      assert_equal arguments, parameters.fetch("properties").keys
    end
  end

  # A LOOP HAS NO CONVERSATION, and the refusal is DATA the model reads —
  # the task completes so the round continues and the model can retry
  # against the scope it does have.
  test "conversation scope refuses as data, and the task still completes" do
    node = run_tool!("memory_write",
      { "path" => "conversation/plan.md", "content" => "x" })

    assert_equal "completed", node.status, "a refusal must not kill the round"
    assert errored?(node)
    assert_includes output(node), "memory_scope_unavailable"
  end

  # A LOOP-BACKED LOOP HAS A CONVERSATION: its rung is reachable through the seam, and a write owes
  # the fence every assembly-changing write owes, whichever scope it lands in.
  test "a loop-backed loop reaches its conversation's scope, and each write bumps context_revision once" do
    conversation = loop_backed!
    before = conversation.context_revision

    written = run_tool!("memory_write",
      { "path" => "conversation/plan.md", "content" => "the plan" })
    refute errored?(written), output(written)
    assert_includes output(written), "conversation/plan.md"
    assert MemoryDocument.for_conversation(conversation.id).exists?(name: "plan.md")
    assert_equal before + 1, conversation.reload.context_revision

    listed = run_tool!("memory_ls", { "path" => "conversation/" })
    refute errored?(listed), output(listed)
    assert_includes output(listed), "conversation/plan.md"

    read = run_tool!("memory_read", { "path" => "conversation/plan.md" })
    refute errored?(read)
    assert_equal "the plan", output(read)

    shared = run_tool!("memory_write", { "path" => "workspace/shared.md", "content" => "x" })
    refute errored?(shared), output(shared)
    assert_equal before + 2, conversation.reload.context_revision,
      "a workspace note changes this conversation's next block too"
    assert_equal before + 2, conversation.reload.context_revision, "reads bump nothing"

    deleted = run_tool!("memory_delete", { "path" => "conversation/plan.md" })
    refute errored?(deleted), output(deleted)
    assert_equal before + 3, conversation.reload.context_revision
    refused = run_tool!("memory_delete", { "path" => "conversation/plan.md" })
    assert errored?(refused)
    assert_equal before + 3, conversation.reload.context_revision, "a refusal bumps nothing"
  end

  test "a bare name is refused rather than defaulted into a scope" do
    node = run_tool!("memory_write", { "path" => "notes.md", "content" => "x" })

    assert errored?(node)
    assert_includes output(node), "memory_path_invalid"
  end

  test "ls answers paths, sizes and when the CONTENT was written" do
    run_tool!("memory_write", { "path" => "workspace/a.md", "content" => "alpha" })
    run_tool!("memory_write", { "path" => "workspace/b.md", "content" => "beta" })

    node = run_tool!("memory_ls", {})
    refute errored?(node)
    assert_includes output(node), "workspace/a.md"
    assert_includes output(node), "5 bytes"
    assert_includes output(node), "workspace/b.md"
  end

  test "an empty memory says so rather than answering nothing" do
    node = run_tool!("memory_ls", {})
    refute errored?(node)
    assert_equal "No memory documents.", output(node)
  end

  test "grep answers path:line: text in path order" do
    run_tool!("memory_write",
      { "path" => "workspace/a.md", "content" => "alpha\nbeta\n" })
    run_tool!("memory_write", { "path" => "workspace/b.md", "content" => "beta too\n" })

    node = run_tool!("memory_grep", { "pattern" => "beta" })
    refute errored?(node)
    assert_equal ["workspace/a.md:2: beta", "workspace/b.md:1: beta too"],
      output(node).lines.map(&:chomp)
  end

  test "a pattern grep cannot compile refuses instead of raising" do
    node = run_tool!("memory_grep", { "pattern" => "[" })

    assert_equal "completed", node.status
    assert errored?(node)
    assert_includes output(node), "memory_pattern_invalid"
  end

  # The uniqueness requirement IS the safety: a passage appearing twice
  # cannot be edited without guessing which one was meant.
  test "edit replaces exactly one passage and refuses an ambiguous one" do
    run_tool!("memory_write",
      { "path" => "workspace/n.md", "content" => "one\ntwo\nthree" })

    edited = run_tool!("memory_edit",
      { "path" => "workspace/n.md", "old_text" => "two", "new_text" => "TWO" })
    refute errored?(edited), output(edited)
    assert_equal "Edited workspace/n.md.", output(edited)
    assert_equal "one\nTWO\nthree",
      output(run_tool!("memory_read", { "path" => "workspace/n.md" }))

    run_tool!("memory_write",
      { "path" => "workspace/dup.md", "content" => "same\nsame" })
    ambiguous = run_tool!("memory_edit",
      { "path" => "workspace/dup.md", "old_text" => "same", "new_text" => "x" })
    assert errored?(ambiguous)
    assert_includes output(ambiguous), "memory_edit_ambiguous"

    missing = run_tool!("memory_edit",
      { "path" => "workspace/n.md", "old_text" => "absent", "new_text" => "x" })
    assert errored?(missing)
    assert_includes output(missing), "memory_edit_not_found"
  end

  { "ASCII" => ["ababa", "aba"], "multibyte" => ["雪あいあいあ", "あいあ"] }.each do |kind, (content, old_text)|
    test "edit refuses overlapping #{kind} passages without changing the document" do
      run_tool!("memory_write", { "path" => "workspace/overlap.md", "content" => content })
      document = MemoryDocument.for_workspace(@workspace.id).find_by!(name: "overlap.md")

      assert_no_changes -> { [document.reload.memory_document_version_id, document.lock_version, document.content] } do
        edited = run_tool!("memory_edit",
          { "path" => "workspace/overlap.md", "old_text" => old_text, "new_text" => "changed" })
        assert errored?(edited), output(edited)
        assert_includes output(edited), "memory_edit_ambiguous"
      end
    end
  end

  test "delete removes it, and saying so twice is not a crash" do
    run_tool!("memory_write", { "path" => "workspace/gone.md", "content" => "x" })

    deleted = run_tool!("memory_delete", { "path" => "workspace/gone.md" })
    refute errored?(deleted)

    again = run_tool!("memory_delete", { "path" => "workspace/gone.md" })
    assert errored?(again)
    assert_includes output(again), "memory_not_found"
  end

  # THE `user/` RUNG belongs to the controlling Human of the loop's creating principal: the steward
  # for an agent, the person for a Human. So a person and every agent they steward share one scope,
  # from any workspace, in either direction.
  test "user/ is the steward's: the agent writes it, the Human reads it, and the reverse" do
    standalone!(creating_user: users(:agent))
    written = run_tool!("memory_write", { "path" => "user/notes.md", "content" => "from the agent" })
    refute errored?(written), output(written)
    assert_includes output(written), "Wrote user/notes.md"
    assert MemoryDocument.for_user(users(:owner).id).exists?(name: "notes.md"),
      "an agent's user/ lands under its steward"
    assert_not MemoryDocument.for_user(users(:agent).id).exists?

    standalone!(creating_user: users(:owner))
    read = run_tool!("memory_read", { "path" => "user/notes.md" })
    refute errored?(read), output(read)
    assert_equal "from the agent", output(read)
    run_tool!("memory_write", { "path" => "user/from-owner.md", "content" => "from the person" })

    standalone!(creating_user: users(:agent))
    back = run_tool!("memory_read", { "path" => "user/from-owner.md" })
    refute errored?(back), output(back)
    assert_equal "from the person", output(back)
  end

  # A SPAWNED CHILD's `user/` is its ANSWERER's steward's, whoever posted the turn: a person's `rho
  # say CHILD` writes the child agent's notes, not the person's own.
  test "user/ on a spawned child is the answerer's steward's, not the poster's" do
    parent = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: users(:agent))
    node = seed(memory_round, creating_user: @human).agent_loop_nodes.first
    child = Conversation.create!(workspace: @workspace, creating_user: users(:agent), answering_user: users(:agent),
      parent_conversation: parent, parent_conversation_public_id: parent.public_id, spawn_node: node)
    loop_backed!(conversation: child, creating_user: @human)
    assert_equal @human, @agent_loop.creating_user, "the person posted the turn"

    written = run_tool!("memory_write", { "path" => "user/notes.md", "content" => "on the child" })
    refute errored?(written), output(written)
    assert MemoryDocument.for_user(users(:owner).id).exists?(name: "notes.md"),
      "the child agent's steward holds the note"
    assert_not MemoryDocument.for_user(@human.id).exists?, "not the poster"
    # The inbox's `scope` stamp names the SAME Human the kernel's memory resolved `user/` to (the
    # memory principal, never the poster).
    assert_equal users(:owner).public_id, Executors::Inbox.scope_of(written).fetch(:bindings).find { |binding| binding[:name] == "user" }.fetch(:user_public_id)
  end

  # A path names no Human. Another steward's agent resolves ITS steward's
  # scope, where this note does not exist — not found, never a refusal
  # that would reveal the note is there.
  test "another steward's agent does not find a foreign user/ note" do
    standalone!(creating_user: users(:owner))
    run_tool!("memory_write", { "path" => "user/notes.md", "content" => "owner's" })

    foreign_agent = accounts(:cybros).users.create!(
      kind: :agent, role: :member, display_name: "Member's Agent",
      steward: users(:member), agent_identifier: "member-agent"
    )
    standalone!(creating_user: foreign_agent)
    read = run_tool!("memory_read", { "path" => "user/notes.md" })
    assert errored?(read)
    assert_includes output(read), "memory_not_found"
    refute_includes output(read), "memory_scope_unavailable"
    listed = run_tool!("memory_ls", { "path" => "user/" })
    assert_equal "No memory documents.", output(listed)
  end

  # THE EMPTY-PATH UNION lists the three scopes the loop can see, and the
  # user rung of it is the loop's controlling Human's ONLY: a foreign
  # steward's user/ rows never appear, in a shared workspace or anywhere.
  test "empty-path ls and grep answer the union of three scopes, filtered to the loop's Human" do
    foreign = Scopes::Anchor.call(path: "user/theirs.md", user: users(:member))
    MemoryDocuments::Write.call(anchor: foreign, expected: memory_expectation_at(foreign), content: "a foreign steward's note")

    loop_backed!(creating_user: users(:owner))
    run_tool!("memory_write", { "path" => "conversation/c.md", "content" => "conversation note" })
    run_tool!("memory_write", { "path" => "workspace/w.md", "content" => "workspace note" })
    run_tool!("memory_write", { "path" => "user/u.md", "content" => "user note" })

    listed = run_tool!("memory_ls", {})
    refute errored?(listed), output(listed)
    paths = output(listed).lines.map { |line| line.split.first }
    assert_equal %w[conversation/c.md user/u.md workspace/w.md], paths,
      "the three scopes, grouped by scope in path order"
    refute_includes output(listed), "theirs.md"

    scoped = run_tool!("memory_ls", { "path" => "user/" })
    assert_equal ["user/u.md"], output(scoped).lines.map { |line| line.split.first }

    found = run_tool!("memory_grep", { "pattern" => "note" })
    refute errored?(found), output(found)
    assert_equal ["conversation/c.md:1: conversation note", "user/u.md:1: user note",
                  "workspace/w.md:1: workspace note"], output(found).lines.map(&:chomp)
    refute_includes output(found), "foreign"

    narrowed = run_tool!("memory_grep", { "pattern" => "note", "path" => "user/" })
    assert_equal ["user/u.md:1: user note"], output(narrowed).lines.map(&:chomp)
  end

  # No loop is created by the system user today; if one ever is, the nil
  # controlling Human meets a refusal, never a nil dereference.
  test "a loop whose principal answers to no Human is refused user/ as data" do
    # Creation-frozen and the scheduler admits no round for the system
    # user, so the column flips AFTER the fan and before the kernel runs —
    # one fresh loop per verb, the row bypassing the model.
    as_system = -> do
      AgentLoop.where(id: @agent_loop.id).update_all(creating_user_id: users(:system).id)
      @agent_loop.reload
    end

    standalone!(creating_user: users(:owner))
    node = run_tool!("memory_read", { "path" => "user/notes.md" }, &as_system)
    assert_equal "completed", node.status
    assert errored?(node)
    assert_includes output(node), "memory_scope_unavailable"

    standalone!(creating_user: users(:owner))
    listed = run_tool!("memory_ls", { "path" => "user/" }, &as_system)
    assert errored?(listed)
    assert_includes output(listed), "memory_scope_unavailable"

    standalone!(creating_user: users(:owner))
    union = run_tool!("memory_ls", {}, &as_system)
    refute errored?(union), "the empty-path union simply has no user rung"
  end

  # THE HUMAN-B CASE: a turn's user/ is the TURN's principal's, never the conversation creator's. B
  # posting into A's conversation reads and writes B's scope; A's next turn sees none of it.
  test "a turn another Human posts into a conversation uses THAT Human's user/" do
    owner_anchor = Scopes::Anchor.call(path: "user/owners.md", user: users(:owner))
    MemoryDocuments::Write.call(anchor: owner_anchor, expected: memory_expectation_at(owner_anchor), content: "the owner's note")

    conversation = loop_backed!(creating_user: users(:owner), acting_user: users(:member))
    listed = run_tool!("memory_ls", {})
    assert_equal "No memory documents.", output(listed), "the owner's user/ is not this turn's"

    run_tool!("memory_write", { "path" => "user/members.md", "content" => "the member's note" })
    assert MemoryDocument.for_user(users(:member).id).exists?(name: "members.md")
    assert_not MemoryDocument.for_user(users(:owner).id).exists?(name: "members.md")

    # The BLOCK, not the history: the history echoes B's tool call arguments.
    as_owner = Conversations::ContextAssembly.assemble(
      conversation: conversation.reload, principal: users(:owner), prompt: "next"
    ).memory.segments.sole.text
    assert_includes as_owner, "## user/owners.md\nthe owner's note"
    refute_includes as_owner, "user/members.md", "B's write is invisible to A's next turn"
  end

  # THE REGISTRY IS THE POINTER: nothing injects memory into a prompt, so
  # the descriptions are what tell a model this store exists and outlives
  # the machine. Pinned because that is the whole of the injection
  # decision, and a description edit that dropped it would be silent.
  test "every memory description says the store outlives the machine" do
    memory = Nexus::ToolRegistry::LIVE.select { |name, _| name.start_with?("nexus.memory.") }
    assert_equal 6, memory.length

    memory.each_value do |tool|
      assert_match(/durable|DURABLE|outlives|survives/i, tool.description,
        "#{tool.name} must say the store is not this machine's disk")
    end
    # The needle spans a wrap in the heredoc, so it matches across
    # whitespace rather than pinning where the line happens to break.
    assert_match(/shared with\s+everyone/i,
      memory.fetch("nexus.memory.write").description,
      "the write verb must say who else can read a workspace document")
  end

  # AN AGENT NEVER AUTHORS ITS OWN INSTRUCTIONS (evolution by incubation): the three writing verbs
  # refuse a `skills/` path as data; `read`, `ls` and `grep` see the row as any document — the
  # recorded overlap (`ls` shows the storage, the catalog shows the merge).
  test "memory_write, memory_edit and memory_delete refuse skills/ paths; read and ls see the rows" do
    anchor = Scopes::Anchor.call(path: "workspace/skills/commit-style", workspace: @workspace)
    MemoryDocument.transaction do
      anchor.lockable.lock!
      assert_predicate MemoryDocuments::Write.call(anchor: anchor, expected: memory_expectation_at(anchor), content: "# Commits\n",
        description: "How this team writes commits."), :written?
    end

    %w[memory_write memory_edit memory_delete].each do |verb|
      input = { "path" => "workspace/skills/commit-style", "content" => "x", "old_text" => "a", "new_text" => "b" }
      node = run_tool!(verb, input)
      assert_equal "completed", node.status, verb
      assert errored?(node), verb
      assert_includes output(node), "memory_reserved_prefix", verb
    end
    assert_equal "# Commits\n", MemoryDocument.for_workspace(@workspace.id).find_by!(name: "skills/commit-style").content

    written = run_tool!("memory_write", { "path" => "user/skills/mine", "content" => "x" })
    assert errored?(written)
    assert_includes output(written), "memory_reserved_prefix: user/skills/mine"
    assert_not MemoryDocument.skills.exists?(name: "skills/mine")

    read = run_tool!("memory_read", { "path" => "workspace/skills/commit-style" })
    refute errored?(read), output(read)
    assert_equal "# Commits\n", output(read)

    listed = run_tool!("memory_ls", { "path" => "workspace/" })
    refute errored?(listed), output(listed)
    assert_includes output(listed), "workspace/skills/commit-style"
  end

  # THE KERNEL-ROW LOAD: `skill {name}` for a name nobody announced runs in-process and IS `read` in
  # anchor order — `workspace/skills/<name>` before `user/skills/<name>` — answering exactly what
  # `read` answers; a name in neither rung is the one error word `skill_unknown`, an error result
  # the model reads on its next round.
  def skill_row!(path, content, description: "A description.", user: nil)
    anchor = Scopes::Anchor.call(path: path, workspace: @workspace, user: user)
    MemoryDocument.transaction do
      anchor.lockable.lock!
      result = MemoryDocuments::Write.call(anchor: anchor, expected: memory_expectation_at(anchor), content: content, description: description)
      assert_predicate result, :written?, result.outcome.to_s
    end
  end

  test "skill loads the workspace row before the user row, and answers what read answers" do
    skill_row!("user/skills/commit-style", "# Mine\n", user: users(:owner))
    standalone!(creating_user: users(:agent))

    loaded = run_tool!("skill", { "name" => "commit-style" })
    assert_equal "completed", loaded.status
    refute errored?(loaded), output(loaded)
    assert_equal "# Mine\n", output(loaded), "the steward's user/ rung"
    assert_equal "read user/skills/commit-style", loaded.result_title

    skill_row!("workspace/skills/commit-style", "# Theirs\n")
    loaded = run_tool!("skill", { "name" => "commit-style" })
    assert_equal "# Theirs\n", output(loaded), "workspace/ precedes user/"
    assert_equal "read workspace/skills/commit-style", loaded.result_title
    read = run_tool!("memory_read", { "path" => "workspace/skills/commit-style" })
    assert_equal output(read), output(loaded), "the load is literally read"

    long = (1..(AgentLoops::Memory::Run::MAX_READ_LINES + 5)).map { |line| "line #{line}\n" }.join
    skill_row!("workspace/skills/long-one", long)
    loaded = run_tool!("skill", { "name" => "long-one" })
    assert_includes output(loaded), "[Showing #{AgentLoops::Memory::Run::MAX_READ_LINES} of", "read's own window"
  end

  test "skill answers skill_unknown for a name in neither rung, a malformed name, and a Human-less loop's user rung" do
    standalone!(creating_user: users(:agent))
    missing = run_tool!("skill", { "name" => "nobody-wrote-this" })
    assert_equal "completed", missing.status, "an error envelope, never a dead task"
    assert errored?(missing)
    assert_equal "skill_unknown: nobody-wrote-this", output(missing)
    assert_equal "skill refused", missing.result_title

    [{ "name" => "skills/PDF" }, { "name" => ["x"] }, {}].each do |input|
      malformed = run_tool!("skill", input)
      assert errored?(malformed), input.inspect
      assert_includes output(malformed), "skill_unknown", input.inspect
    end

    skill_row!("user/skills/only-mine", "# Mine\n", user: users(:owner))
    loaded = run_tool!("skill", { "name" => "only-mine" })
    refute errored?(loaded), output(loaded)

    as_system = -> do
      AgentLoop.where(id: @agent_loop.id).update_all(creating_user_id: users(:system).id)
      @agent_loop.reload
    end
    standalone!(creating_user: users(:owner))
    unreachable = run_tool!("skill", { "name" => "only-mine" }, &as_system)
    assert errored?(unreachable)
    assert_equal "skill_unknown: only-mine", output(unreachable), "no controlling Human: no user rung, the same word"
  end
end
