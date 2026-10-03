module AgentLoopNodes
  # A short pure computation. Its output or generated graph is published once;
  # the ordinary park clock closes work lost with its worker.
  class ScriptTask < AgentLoopNode
    include Parked

    PARK_KIND = "script".freeze
    DEFAULT_TIMEOUT_MS = ToolTask::DEFAULT_TIMEOUT_MS
    has_one :input_body, -> { where(role: "input") }, class_name: "ContentBody", inverse_of: :agent_loop_node
    self.task_kind = "script_task"
    self.transitions = {
      nil => %w[queued skipped],
      "queued" => %w[running failed canceled skipped],
      "running" => %w[completed failed timed_out canceled],
      "failed" => %w[queued],
      "timed_out" => %w[queued],
      "completed" => [], "canceled" => [], "skipped" => [],
    }.freeze

    def script? = true
    def park_kind = PARK_KIND
    def authored_timeout_ms = timeout_ms
    def announced_timeout_ms = nil

    def definition
      input_body.content_body_entries.first.content_fragment.payload.fetch("structured_content")
    end
  end
end
