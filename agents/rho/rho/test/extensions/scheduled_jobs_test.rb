require "test_helper"

class ScheduledJobsExtensionTest < Minitest::Test
  Extension = Rho::Extensions::ScheduledJobs
  Rule = { "kind" => "once", "run_at" => "2026-10-03T09:00:00Z" }.freeze

  class Jobs
    attr_reader :calls, :row
    attr_accessor :failure

    def initialize
      @calls = []
      @row = CybrosAgent::Api::ScheduledJob.new(public_id: "job-1", prompt: "Check the inbox",
        rule: CybrosAgent::Api::ScheduledJobRule.new(kind: "once", run_at: Rule.fetch("run_at")),
        status: "active", lock_version: 3)
    end

    def create(**fields)
      record(:create, fields)
      CybrosAgent::Api::ScheduledJobsContext::Created.new(scheduled_job: row, replayed: false)
    end

    def update(id, **fields)
      record(:update, id, fields)
      row
    end

    def fetch(id)
      record(:fetch, id)
      row
    end

    def list(**fields)
      record(:list, fields)
      CybrosAgent::Api::Page.new(items: [row], next_after: "next-page")
    end

    def executions(id, **fields)
      record(:executions, id, fields)
      CybrosAgent::Api::ScheduledJobExecutionPage.new(items: [], next_after: nil, last_cursor: "last-seen")
    end

    def pause(id)
      record(:pause, id)
      row
    end

    private

      def record(*call)
        calls << call
        raise failure if failure
      end
  end

  class LoopDoor
    attr_reader :tasks
    attr_accessor :declaring_task_key, :approval_mode, :tool_definitions, :answering_user_public_id

    def initialize
      @tasks = []
      @declaring_task_key = "delegated-round"
      @approval_mode = "default"
      @answering_user_public_id = "selected-group-answerer"
      @tool_definitions = [{ "type" => "function", "function" => { "name" => "read" } }]
    end

    def fetch
      turn = Struct.new(:answering_user_public_id).new(answering_user_public_id)
      Struct.new(:approval_mode, :turn).new(approval_mode, turn)
    end

    def task(key)
      tasks << key
      return Struct.new(:declaring_task_key).new(declaring_task_key) if key == "delegated-call"

      raise "wrong model round: #{key}" unless key == declaring_task_key

      task = Struct.new(:model).new({ "model" => "dev/mock-text", "reasoning_effort" => "low" })
      Struct.new(:task, :tool_definitions).new(task, tool_definitions)
    end
  end

  def setup
    @jobs = Jobs.new
    @loop = LoopDoor.new
    @seen = []
  end

  def bind(available: true)
    jobs, loop_door, seen = @jobs, @loop, @seen
    client = Object.new
    client.define_singleton_method(:workspace) do |id|
      seen << [:workspace, id]
      workspace = Object.new
      workspace.define_singleton_method(:conversation) do |conversation|
        seen << [:conversation, conversation]
        Struct.new(:scheduled_jobs).new(jobs)
      end
      workspace.define_singleton_method(:agent_loops) do
        loops = Object.new
        loops.define_singleton_method(:agent_loop) do |loop|
          seen << [:loop, loop]
          loop_door
        end
        loops
      end
      workspace
    end
    host = RhoTest.host.with(member_plane: ->(host_public_id: nil, workspace_public_id: nil) do
      seen << [:plane, host_public_id, workspace_public_id]
      Rho::Extensions::MemberPlane.new(client: client, workspace_public_id: workspace_public_id) if available
    end)
    api = Rho::Extensions::Api.new(host: host, extension_name: Extension::NAME, source: "<test>")
    Extension.register(api)
    api
  end

  def context(**fields)
    Rho::Runner::ExecutionContext.new(**{
      agent_loop_public_id: "loop-1", conversation_public_id: "conversation-1",
      workspace_public_id: "workspace-1", task_key: "delegated-call",
    }.merge(fields))
  end

  def call(klass, args, ctx: context)
    Rho::Runner::ExecutionContext.with(ctx) { klass.new(env: nil).call(args) }
  end

  def create_args = { "action" => "create", "prompt" => "Check the inbox", "rule" => Rule }

  def test_only_the_read_tool_is_in_the_read_only_policy
    api = bind
    assert_equal %w[read_scheduled_jobs manage_scheduled_job], api.tools.map { |tool| tool.klass::NAME }
    assert api.tools.all? { |tool| tool.serves == :agent }
    assert_includes Rho::Extensions::DEFAULT_EXTENSIONS, Extension
    assert_includes Rho::Extensions::RUNNER_MODE_EXCLUDES, Extension
    assert_includes Rho::LoopRequest::READ_ONLY_TOOLS, Extension::Read::NAME
    refute_includes Rho::LoopRequest::READ_ONLY_TOOLS, Extension::Manage::NAME
    [Extension::Read, Extension::Manage].each do |klass|
      Rho::Runner::Extensions::Tool.validate!(klass, extension: Extension::NAME)
    end
  end

  def test_create_uses_the_executing_conversation_and_the_actual_declaring_round
    bind
    result = call(Extension::Manage, create_args)
    refute result.is_error
    assert_equal "job-1", JSON.parse(result.content).fetch("public_id")
    assert_equal [[:plane, "conversation-1", "workspace-1"], [:workspace, "workspace-1"],
      [:conversation, "conversation-1"], [:loop, "loop-1"]], @seen
    assert_equal %w[delegated-call delegated-round], @loop.tasks
    fields = @jobs.calls.fetch(0).fetch(1)
    assert_equal ["read"], fields.fetch(:tool_names)
    assert_equal "default", fields.fetch(:approval_mode)
    assert_equal "selected-group-answerer", fields.fetch(:to)
    assert_equal "dev/mock-text", fields.fetch(:model)
    assert_equal "low", fields.fetch(:reasoning_effort)
    assert_equal "loop-1", fields.fetch(:source_agent_loop_public_id)
    assert_equal "delegated-call", fields.fetch(:source_task_key)
    assert_equal Rule, fields.fetch(:rule)
  end

  def test_retried_creation_keeps_one_idempotency_key_and_an_empty_tool_set_stays_empty
    bind
    @loop.tool_definitions = []
    2.times { refute call(Extension::Manage, create_args).is_error }
    assert_equal ["scheduled_job:loop-1:delegated-call"], @jobs.calls.map { |call| call.last.fetch(:idempotency_key) }.uniq
    assert_equal [], @jobs.calls.last.last.fetch(:tool_names)
  end

  def test_missing_declaring_round_or_policy_refuses_creation
    bind
    @loop.declaring_task_key = nil
    assert call(Extension::Manage, create_args).is_error
    assert_empty @jobs.calls
    @loop.declaring_task_key = "delegated-round"
    @loop.approval_mode = nil
    assert call(Extension::Manage, create_args).is_error
    assert_empty @jobs.calls
    @loop.approval_mode = "default"
    @loop.answering_user_public_id = nil
    assert call(Extension::Manage, create_args).is_error
    assert_empty @jobs.calls
  end

  def test_update_submits_the_observed_version_once_without_reading_a_new_version
    bind
    @jobs.failure = CybrosAgent::Api::Conflict.new("changed", code: "stale_scheduled_job")
    result = call(Extension::Manage, { "action" => "update", "job_id" => "job-1",
      "prompt" => "Check a different folder", "expected_lock_version" => 3 })
    assert result.is_error
    assert_equal [[:update, "job-1", { prompt: "Check a different folder", expected_lock_version: 3 }]], @jobs.calls
    assert_empty @loop.tasks
  end

  def test_reads_keep_pagination_and_history_cursor
    bind
    result = call(Extension::Read, { "action" => "list", "after" => "prior", "limit" => 7 })
    document = JSON.parse(result.content)
    assert_equal "next-page", document.fetch("next_after")
    assert_equal Rule, document.fetch("scheduled_jobs").first.fetch("rule")
    assert_equal [[:list, { after: "prior", limit: 7 }]], @jobs.calls
    result = call(Extension::Read, { "action" => "history", "job_id" => "job-1", "after" => "prior" })
    assert_equal({ "executions" => [], "next_after" => nil, "last_cursor" => "last-seen" }, JSON.parse(result.content))
    assert_empty @loop.tasks
  end

  def test_read_and_pause_need_no_current_model_round
    bind
    owner = context(agent_loop_public_id: nil, task_key: nil)
    refute call(Extension::Read, { "action" => "show", "job_id" => "job-1" }, ctx: owner).is_error
    refute call(Extension::Manage, { "action" => "pause", "job_id" => "job-1" }, ctx: owner).is_error
    assert_empty @loop.tasks
  end

  def test_no_conversation_or_connection_is_a_readable_refusal
    bind(available: false)
    assert call(Extension::Read, { "action" => "list" }).is_error
    assert call(Extension::Manage, create_args, ctx: context(conversation_public_id: nil)).is_error
    assert_empty @jobs.calls
  end

  def test_cancellation_propagates_before_any_connection_or_mutation
    bind
    owner = context
    owner.cancel(:canceled)
    assert_raises(Rho::Runner::ExecutionContext::Cancelled) { call(Extension::Manage, create_args, ctx: owner) }
    assert_empty @seen
    assert_empty @jobs.calls
  end

  def test_schema_requires_each_actions_arguments
    validator = Rho::Runner::InputSchema.compile(Extension::Manage::SCHEMA)
    assert_nil Rho::Runner::InputSchema.refusal(validator, create_args)
    [{ "action" => "create", "prompt" => "x", "rule" => { "kind" => "once" } },
      { "action" => "update", "job_id" => "job-1", "prompt" => "x" },
      { "action" => "pause" }].each do |arguments|
      assert Rho::Runner::InputSchema.refusal(validator, arguments)
    end
  end
end
