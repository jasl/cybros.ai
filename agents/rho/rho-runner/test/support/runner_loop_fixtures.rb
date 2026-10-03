require "test_helper"

# Shared executor-plane fixture for the runner delivery and execution tests.
module RunnerLoopFixtures
  Task = CybrosAgent::Api::InboxTask
  Claimed = CybrosAgent::Api::ClaimedTask
  Page = Data.define(:items, :next_after)

  # Stands in for the SDK's `ExecutorClient` — the executor plane's inbox,
  # claim and commit — recording what was asked of it.
  class Lane
    attr_reader :claims, :commits, :lists, :list_cursors, :extends, :frames, :uploaded

    def initialize(rows: [], grant: :ok, on_commit: nil, on_list: nil, deadline_at: nil, on_extend: nil,
                   on_progress: nil, on_upload: nil, pages: nil)
      @rows = rows
      @pages = pages || { nil => Page.new(items: rows, next_after: nil) }
      @grant = grant
      @on_commit = on_commit
      @on_list = on_list
      @deadline_at = deadline_at
      @on_extend = on_extend
      @on_progress = on_progress
      @on_upload = on_upload
      @claims = []
      @commits = []
      @extends = []
      @frames = []
      @uploaded = []
      @lists = 0
      @list_cursors = []
    end

    # The progress door (executor.md "Progress"): the frame recorded whole,
    # a case's refusal raised as the kernel would.
    def report_progress(frame)
      @on_progress&.call(frame)
      @frames << frame
      nil
    end

    def inbox = Inbox.new(self)

    # THE CAPTURE DOOR: the executor plane's upload, answering
    # the staged descriptor as the kernel would — the type from the bytes'
    # extension here, the size from the file.
    def uploads = Uploads.new(self)

    def record_upload(path)
      @on_upload&.call(path)
      @uploaded << path
      CybrosAgent::Api::Upload.new(public_id: "up-#{@uploaded.length}", filename: File.basename(path),
        content_type: Rho::Runner::Files.classify(path), byte_size: File.size(path),
        created_at: "2026-09-13T00:00:00Z")
    end

    Uploads = Data.define(:lane) do
      def create(path) = lane.record_upload(path)
    end

    def inbox_task(agent_loop_public_id:, task_key:)
      Door.new(self, agent_loop_public_id, task_key)
    end

    def record_list(after:)
      @lists += 1
      @list_cursors << after
      @on_list&.call
      @pages.fetch(after)
    end

    def record_claim(key, agent_loop_public_id:)
      @claims << key
      raise CybrosAgent::Api::Conflict.new("taken", code: "already_claimed") if @grant == :taken

      row = @rows.find { |candidate| candidate.task_key == key && candidate.agent_loop_public_id == agent_loop_public_id }
      # A callable mints the park's deadline AT THE CLAIM, as the kernel does.
      at = @deadline_at.respond_to?(:call) ? @deadline_at.call : @deadline_at
      Claimed.new(task: row, claim_token: "tok-#{key}", deadline_at: at)
    end

    def record_commit(fields)
      @on_commit&.call(fields)
      @commits << fields
      { "task" => {} }
    end

    # The extension's answer: the kernel's new deadline, minted like the
    # claim's — the park asked for, from now — unless the case refuses.
    def record_extend(key, fields)
      @extends << fields.merge(task_key: key)
      @on_extend&.call(fields)
      row = @rows.find { |candidate| candidate.task_key == key }
      Claimed.new(task: row, claim_token: fields.fetch(:claim_token),
        deadline_at: (Time.now + (fields.fetch(:timeout_ms) / 1000.0)).iso8601(3))
    end

    Inbox = Data.define(:lane) do
      def list(after: nil, limit: nil) = lane.record_list(after: after)
    end

    Door = Data.define(:lane, :agent_loop_public_id, :task_key) do
      def claim = lane.record_claim(task_key, agent_loop_public_id: agent_loop_public_id)
      def commit(**fields) = lane.record_commit(fields)
      def extend(**fields) = lane.record_extend(task_key, fields)
    end
  end

  class Silent
    def warn(*, **) = nil
    def info(*, **) = nil
  end

  # A log that keeps what it was told, for the cases whose evidence is a line.
  class Kept
    attr_reader :warned, :told

    def initialize
      @warned = []
      @told = []
    end

    def warn(event, **fields) = @warned << [event, fields]
    def info(event, **fields) = @told << [event, fields]
  end

  # `sole` is ActiveSupport's; this gem has no Rails.
  def only(list)
    assert_equal 1, list.length, "expected exactly one submission, got #{list.length}"
    list.first
  end

  def row(key, tool: "echo", input: { "text" => "hi" }, claimed: false, scope: nil, conversation: nil,
          timeout_ms: nil, workspace: "ws-1")
    Task.new(workspace_public_id: workspace, kind: "tool_call", agent_loop_public_id: "loop-1", conversation_public_id: conversation,
      task_key: key, tool_name: tool,
      tool_input: input, tool_call_id: "call-#{key}", started_at: nil,
      deadline_at: nil, timeout_ms: timeout_ms, claimed: claimed,
      addressed_to: CybrosAgent::Api::AddressedTo.new(role: "runner", executor_public_id: "ex-1"),
      scope: scope)
  end

  def toolset(internal_clamp: false, timeout_ms: nil, &handler)
    body = handler || ->(args, _ctx) { Rho::Runner::Result.ok("echo: #{args["text"]}") }
    Rho::Runner::Toolset.new(
      "echo" => Rho::Runner::Toolset::Tool.new(
        name: "echo", description: "echo", parameters: { "type" => "object" },
        handler: body, internal_clamp: internal_clamp, timeout_ms: timeout_ms
      )
    )
  end

  # ONE PLACEMENT FOR EVERY ROW: the standalone runner's shape (a hand-built
  # toolset, no env), which every case here that is not about placements uses.
  def fixed(tools) = Rho::Runner::Toolsets.fixed(toolset: tools)

  def runner(lane, tools = toolset)
    Rho::Runner.new(executor: lane, toolsets: fixed(tools), log: Silent.new,
      pool: Rho::Runner::Pool.new(worker_threads: 2), sleeper: ->(_) { nil })
  end
end
