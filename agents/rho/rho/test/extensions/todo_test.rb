require "test_helper"

# THE TODO TRACKER AS AN EXTENSION: one agent-address tool, `todo_write`,
# that writes the model's list WHOLE as the conversation's memory document
# `conversation/todo.md` through the member plane's conversation door —
# the kernel's own memory family, the block the model reads on its next
# turn — and answers a receipt of counts, never the list. Loaded alone on
# a fresh handle, with a fake member plane that records the door's calls.
class TodoExtensionTest < Minitest::Test
  Todo = Rho::Extensions::Todo
  Write = Todo::Write
  List = Todo::List
  Result = Rho::Runner::Result

  THREE = [
    { "content" => "Add the CLI entry", "status" => "completed" },
    { "content" => "Parse the input file", "status" => "in_progress" },
    { "content" => "Write the tests", "status" => "pending" },
  ].freeze
  PUBLIC_ID = "019a0000-0000-7000-8000-000000000001".freeze
  RENDERED = "- [x] Add the CLI entry\n- [>] Parse the input file\n- [ ] Write the tests".freeze

  # The conversation door a tool reaches: records every read, write and delete,
  # answers what it was told to (a kernel refusal, the absent document).
  class Door
    attr_reader :reads, :writes, :deletes

    def initialize(read: nil, write: nil, delete: nil)
      @read = read
      @write = write
      @delete = delete
      @reads = []
      @writes = []
      @deletes = []
    end

    def read(path)
      @reads << path
      raise @read if @read

      CybrosAgent::Api::MemoryDocument.new(public_id: PUBLIC_ID, lock_version: 4, path: path, content: "old list",
        description: nil, bytesize: 8, written_at: "2026-09-29T00:00:00Z")
    end

    def write(path, content, expected_public_id:, expected_lock_version:, description: nil)
      @writes << [path, content, description, expected_public_id, expected_lock_version]
      raise @write if @write

      CybrosAgent::Api::MemoryDocument.new(public_id: expected_public_id || PUBLIC_ID,
        lock_version: expected_lock_version ? expected_lock_version + 1 : 0, path: path, content: content,
        description: description, bytesize: content.bytesize, written_at: "2026-09-29T00:00:00Z")
    end

    def delete(path, expected_public_id:, expected_lock_version:)
      @deletes << [path, expected_public_id, expected_lock_version]
      raise @delete if @delete

      nil
    end
  end

  Client = Struct.new(:door, :seen) do
    def workspace(public_id)
      seen << [:workspace, public_id]
      client = self
      Struct.new(:id).new(public_id).tap do |workspace|
        workspace.define_singleton_method(:conversation) do |conversation_public_id|
          client.seen << [:conversation, conversation_public_id]
          Struct.new(:memory).new(client.door)
        end
      end
    end
  end

  Log = Struct.new(:lines) do
    def info(event, **fields) = lines << [event, fields]
  end

  def setup
    super
    @door = nil
    @seen = []
    @log = Log.new([])
  end

  def bound(door: Door.new, plane: :present, default_workspace: "ws-1")
    @door = door
    client = Client.new(door, @seen)
    host = Rho::Extensions::Host.new(
      home: RhoTest.host.home, log: @log, clock: -> { Time.now }, config: Rho::Config.from_hash({}), processes: nil,
      member_plane: ->(host_public_id: nil, workspace_public_id: nil) do
        if plane == :present
          Rho::Extensions::MemberPlane.new(client: client,
            workspace_public_id: workspace_public_id || (host_public_id == "conv-1" ? "ws-1" : default_workspace))
        end
      end
    )
    api = Rho::Extensions::Api.new(host: host, extension_name: Todo::NAME, source: "<test>")
    Todo.register(api)
    assert_equal 1, api.tools.length, "exactly one tool"
    registration = api.tools.first
    assert_equal :agent, registration.serves, "the agent's own tool, never the runner's"
    registration.klass.new(env: nil)
  end

  def context(conversation: "conv-1", run_public_id: "al-1", task: "r1t0", workspace: nil)
    Rho::Runner::ExecutionContext.new(run_public_id: run_public_id, conversation_public_id: conversation, task_key: task,
      workspace_public_id: workspace)
  end

  def call(tool, todos = THREE, ctx: context)
    Rho::Runner::ExecutionContext.with(ctx) { tool.call({ "todos" => todos }) }
  end

  def test_changing_the_default_workspace_keeps_todos_in_the_original_conversation
    [context, context(conversation: "unfollowed-child", workspace: "ws-1")].each do |owner|
      @seen.clear
      tool = bound(default_workspace: "ws-2")

      result = call(tool, ctx: owner)

      refute result.is_error
      assert_equal [[:workspace, "ws-1"], [:conversation, owner.conversation_public_id]], @seen
      assert_equal "conversation/todo.md", @door.writes.fetch(0).fetch(0)
    end
  end

  # ---- the list ----

  # The three markers are hermes' (the one reference that renders a list a
  # model re-reads as text); one item per line, so a newline inside a
  # content becomes a space.
  def test_the_list_renders_one_line_per_item_with_the_three_markers
    list = List.of(THREE)
    assert_equal RENDERED, list.render
    assert_equal({ "items" => 3, "completed" => 1 }, list.counts)
    refute_predicate list, :finished?
    refute_predicate list, :empty?

    folded = List.of([{ "content" => "first line\nsecond\r\nthird\rfourth", "status" => "pending" }])
    assert_equal "- [ ] first line second third fourth", folded.render
  end

  def test_finished_is_non_empty_and_every_item_completed
    assert_predicate List.of([{ "content" => "a", "status" => "completed" },
                              { "content" => "b", "status" => "completed" }]), :finished?
    refute_predicate List.of([]), :finished?
    assert_predicate List.of([]), :empty?
    refute_predicate List.of([{ "content" => "a", "status" => "completed" },
                              { "content" => "b", "status" => "pending" }]), :finished?
  end

  # ---- the tool's shape ----

  # Registered `serves: :agent` with the kernel's MEMORY_WRITE profile and
  # a thirty-second park; described to the model, with no PROMPT_SNIPPET —
  # the description is the ONE model-facing home.
  def test_the_extension_ships_one_agent_tool_described_once
    assert_includes Rho::Extensions::DEFAULT_EXTENSIONS, Todo
    assert_includes Rho::Extensions::RUNNER_MODE_EXCLUDES, Todo, "a runner holds no member plane"
    registry = Rho::Extensions.load(host: RhoTest.host, extensions: [Todo]).registry
    entry = registry.entries.find { |candidate| candidate.name == "todo_write" }
    assert_equal Write::NAME, entry.name
    assert_equal({ "kind" => "write", "destructive" => true, "effect_scope" => "closed",
                   "idempotency" => "intrinsic", "reconciliation" => "lookup" }, entry.effect_profile)
    assert_equal 30_000, entry.timeout_ms
    assert_equal %w[todos], entry.schema.fetch("required")
    assert_nil Rho::Runner::Extensions::Tool.prompt_snippet(Write)
    assert_empty Rho::Runner::Extensions::Tool.prompt_guidelines(Write)
    assert_equal "conversation/todo.md", Todo::DOCUMENT
    Rho::Runner::Extensions::Tool.validate(Write, extension: Todo::NAME)
  end

  # THE MODEL-FACING TEXT, pinned byte for byte: the references' agreed
  # sentences, one example, and rho's two facts — where
  # the list is shown again and that this tool is its door.
  def test_the_description_is_the_designs_text_byte_for_byte
    assert_equal <<~TEXT.strip, Write::DESCRIPTION
      Track the steps of a multi-step task as a todo list the person can see. Send the WHOLE list each time; it replaces the previous one. Each item has a content (the step, specific and actionable) and a status: pending, in_progress or completed. Keep exactly one item in_progress while work remains: set a step in_progress before you start it, and mark it completed immediately when the work is verified done — never on intent, never batched later. If a step is blocked or only partly done, keep it in_progress and add an item for what blocks it. When the plan changes, rewrite the list before continuing. Use it when the work has three or more steps, when the person asked for several things at once, or when they ask for a plan or todos; do not use it for a single step you can just do. The list is kept with this conversation and shown to you again on later turns in your memory block, under conversation/todo.md; change it only through this tool, never with memory_write. An empty list, or a list with every item completed, clears it.

      Example: {"todos": [{"content": "Add the CLI entry", "status": "completed"}, {"content": "Parse the input file", "status": "in_progress"}, {"content": "Write the tests", "status": "pending"}]}
    TEXT
  end

  # THE RUNNER IS THE ONE VALIDATOR: the schema refuses the stranger status, a missing
  # key, an empty content and a stranger key before the handler runs — the runner's own
  # sentence, so `call` never judges a shape.
  def test_the_schema_refuses_every_shape_fault_before_the_handler
    validator = Rho::Runner::InputSchema.compile(Write::SCHEMA)
    assert_nil Rho::Runner::InputSchema.refusal(validator, { "todos" => THREE })
    assert_nil Rho::Runner::InputSchema.refusal(validator, { "todos" => [] })

    later = Rho::Runner::InputSchema.refusal(validator, { "todos" => [{ "content" => "x", "status" => "later" }] })
    assert_equal "value at `/todos/0/status` is not one of: [\"pending\", \"in_progress\", \"completed\"]", later,
      "json_schemer's own sentence, the one the model reads under `invalid_tool_arguments:`"
    assert_match(/\S/, Rho::Runner::InputSchema.refusal(validator, { "todos" => [{ "content" => "x" }] }))
    assert_match(/\S/, Rho::Runner::InputSchema.refusal(validator, { "todos" => [{ "content" => "", "status" => "pending" }] }))
    assert_match(/\S/, Rho::Runner::InputSchema.refusal(validator, { "todos" => [{ "content" => "x", "status" => "pending", "priority" => "high" }] }))
    assert_match(/\S/, Rho::Runner::InputSchema.refusal(validator, { "todos" => THREE, "extra" => 1 }))
    assert_match(/\S/, Rho::Runner::InputSchema.refusal(validator, {}))
    assert_match(/\S/, Rho::Runner::InputSchema.refusal(validator,
      { "todos" => THREE, "expected_public_id" => nil, "expected_lock_version" => nil }))
  end

  # ---- the handler ----

  # One whole-document write through the conversation's door — the path,
  # the rendered bytes — and a receipt of counts, never the list; the log
  # line carries the conversation, the counts and the bytes, no content.
  def test_the_handler_writes_the_document_whole_and_answers_counts
    tool = bound
    result = call(tool)

    assert_equal Result.ok("Todo list updated: 3 items, 1 completed."), result
    assert_equal ["conversation/todo.md"], @door.reads
    assert_equal [["conversation/todo.md", RENDERED, nil, PUBLIC_ID, 4]], @door.writes
    assert_empty @door.deletes
    assert_equal [[:workspace, "ws-1"], [:conversation, "conv-1"]], @seen
    assert_equal [["todo.written", { conversation: "conv-1", items: 3, completed: 1, bytes: RENDERED.bytesize }]],
      @log.lines
    refute_match(/Add the CLI entry/, @log.lines.inspect, "no content in the log")
  end

  def test_creating_an_absent_list_uses_null_conditions
    tool = bound(door: Door.new(read: CybrosAgent::Api::NotFound.new("absent", code: "memory_not_found")))
    result = call(tool)

    assert_equal Result.ok("Todo list updated: 3 items, 1 completed."), result
    assert_equal ["conversation/todo.md"], @door.reads
    assert_equal [["conversation/todo.md", RENDERED, nil, nil, nil]], @door.writes
  end

  def test_the_receipt_counts_one_item_in_the_singular
    tool = bound
    assert_equal Result.ok("Todo list updated: 1 item, 0 completed."),
      call(tool, [{ "content" => "only", "status" => "in_progress" }])
  end

  # An empty list, or one with every item completed, DELETES the document
  # (claude-code clears on all-completed; hermes never re-shows a finished
  # list): both carry the identity/version observed during execution.
  def test_an_empty_or_all_completed_list_clears_the_document
    tool = bound
    assert_equal Result.ok("Todo list cleared."), call(tool, [])
    assert_equal Result.ok("Todo list cleared."),
      call(tool, [{ "content" => "a", "status" => "completed" }, { "content" => "b", "status" => "completed" }])
    assert_equal ["conversation/todo.md"] * 2, @door.reads
    assert_equal [["conversation/todo.md", PUBLIC_ID, 4]] * 2, @door.deletes
    assert_empty @door.writes
    assert_equal [["todo.cleared", { conversation: "conv-1" }]] * 2, @log.lines
  end

  def test_clearing_an_absent_list_succeeds_without_a_delete
    tool = bound(door: Door.new(read: CybrosAgent::Api::NotFound.new("absent", code: "memory_not_found")))

    assert_equal Result.ok("Todo list cleared."), call(tool, [])
    assert_equal Result.ok("Todo list cleared."), call(tool, [{ "content" => "done", "status" => "completed" }])
    assert_equal ["conversation/todo.md"] * 2, @door.reads
    assert_empty @door.deletes
    assert_empty @door.writes
    assert_equal [["todo.cleared", { conversation: "conv-1" }]] * 2, @log.lines
  end

  def test_read_failures_other_than_an_absent_document_never_write_or_delete
    [CybrosAgent::Api::NotFound.new("hidden", code: "not_found"),
     CybrosAgent::Api::Forbidden.new("no", code: "memory_overridden"),
     CybrosAgent::Error.new("connection lost")].each do |error|
      tool = bound(door: Door.new(read: error))

      [THREE, []].each do |todos|
        assert_equal Result.error("the todo list could not be written: #{error.code || error.message}"), call(tool, todos)
      end
      assert_equal ["conversation/todo.md"] * 2, @door.reads
      assert_empty @door.writes
      assert_empty @door.deletes
      assert_empty @log.lines
    end
  end

  def test_a_read_to_commit_conflict_is_returned_without_a_fresh_read_or_retry
    conflict = CybrosAgent::Api::Conflict.new("changed", code: "stale_object")
    tool = bound(door: Door.new(write: conflict))
    assert_equal Result.error("the todo list could not be written: stale_object"), call(tool)
    assert_equal ["conversation/todo.md"], @door.reads
    assert_equal [["conversation/todo.md", RENDERED, nil, PUBLIC_ID, 4]], @door.writes
    assert_empty @log.lines

    tool = bound(door: Door.new(delete: conflict))
    assert_equal Result.error("the todo list could not be written: stale_object"), call(tool, [])
    assert_equal ["conversation/todo.md"], @door.reads
    assert_equal [["conversation/todo.md", PUBLIC_ID, 4]], @door.deletes
    assert_empty @log.lines
  end

  # A standalone run has no conversation, so no document: the model reads
  # why, and its list stays in the call's arguments.
  def test_a_run_with_no_conversation_is_an_error_the_model_reads
    tool = bound
    result = call(tool, ctx: context(conversation: nil))

    assert_predicate result, :is_error
    assert_equal "this run has no conversation, so it keeps no todo list; the list you sent stays in this " \
                 "call's arguments", result.content
    assert_empty @door.reads
    assert_empty @door.writes
  end

  def test_no_member_plane_is_an_error_the_model_reads
    tool = bound(plane: :absent)
    result = call(tool)

    assert_predicate result, :is_error
    assert_equal "no member plane: this rho holds no adopted workspace, so it cannot write the todo list", result.content
    assert_empty @door.reads
  end

  # EVERY KERNEL REFUSAL RELAYS AS TEXT under the kernel's own code — the
  # door's 409 under a workspace override included — as
  # `completed, is_error`, never a failed row.
  def test_a_kernel_refusal_relays_its_code_as_the_tools_error
    %w[memory_full memory_document_too_large memory_content_invalid memory_scope_unavailable memory_overridden
       conversation_archived not_found stale_object].each do |code|
      tool = bound(door: Door.new(write: CybrosAgent::Api::InvalidRequest.new("refused", code: code)))
      result = call(tool)

      assert_predicate result, :is_error, code
      assert_equal "the todo list could not be written: #{code}", result.content
    end
    tool = bound(door: Door.new(delete: CybrosAgent::Api::Forbidden.new("no", code: "memory_overridden")))
    assert_equal Result.error("the todo list could not be written: memory_overridden"), call(tool, [])
  end

  # A refusal with no code (a transport failure) still names itself.
  def test_a_codeless_failure_relays_its_message
    tool = bound(door: Door.new(write: CybrosAgent::Error.new("connection lost")))
    assert_equal Result.error("the todo list could not be written: connection lost"), call(tool)
  end
end
