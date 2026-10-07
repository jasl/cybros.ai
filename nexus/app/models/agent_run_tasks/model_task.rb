module AgentRunTasks
  # One LLM turn: a ModelInvocation with purpose agent_run_task under this
  # node's execution generation. The prompt rides an owned ContentBody.
  class ModelTask < AgentRunTask
    # Persisted continuation marks, shared by the compiler and graph readers.
    ROUND = "round".freeze
    BRANCH = "branch".freeze

    self.task_kind = "model_task"

    has_one :tool_calls_body, through: :selected_model_invocation
    has_one :reasoning_trace_body, through: :selected_model_invocation
    has_one :input_body, -> { where(role: "input") }, class_name: "ContentBody", inverse_of: :agent_run_task

    # NO APPROVAL STAGE: a round is admitted by the admission plane, and
    # every reference gates tool calls only. `running => queued` is the
    # compaction repair and the interrupted-pause requeue, `failed|timed_out
    # => queued` is retry. No park word — a round waits on nobody outside
    # the kernel.
    self.transitions = {
      nil => %w[queued skipped],
      "queued" => %w[running failed canceled skipped],
      "running" => %w[completed failed timed_out canceled queued],
      "failed" => %w[queued],
      "timed_out" => %w[queued],
      "completed" => [], "canceled" => [], "skipped" => [],
    }.freeze

    # The compaction repair's mark in `compaction`: the key of the summary
    # this round reads in place of its history, and "armed once" (the arm
    # never re-arms a marked round).
    SUMMARY_SOURCE = "summary_source".freeze
    # The prune arm's mark: the key of the first round whose results this
    # round still reads verbatim — every preceding mainline round
    # composes with its results cleared — and "armed once", the same
    # fence as the summary mark. A continuation never inherits it.
    PRUNED_BEFORE = "pruned_before".freeze

    def model_task? = true

    def invocation_creation_key = "agent_run_task:#{id}:#{execution_generation}"

    # This generation's sealed request size — `content_bodies.byte_size`,
    # one column read, never the body — nil before an invocation was minted.
    def sealed_request_bytes
      return nil if selected_model_invocation_id.nil?

      ContentBody.where(model_invocation_id: selected_model_invocation_id, role: "request").pick(:byte_size)
    end

    # A running round holds the provider call it minted: the cancel sites
    # terminalize the invocation and the converger applies the terminal.
    def holds_invocation? = status == "running" && selected_model_invocation_id.present?

    validates :provider_id, :model_ref, presence: true
    validates :request_options, bounded_json: { bound: :envelope_bound, shape: Hash },
      if: -> { new_record? || will_save_change_to_request_options? }
    # Freeze the same aggregate schema set the Profile can declare. It has its
    # own bound because it may combine tools from several execution environments.
    validates :tool_definitions, bounded_json: { bound: :tool_definitions_bound, shape: Array }, allow_nil: true,
      if: -> { new_record? || will_save_change_to_tool_definitions? }
    validate :selection_changes_with_a_new_execution

    # The node's selection is the next execution's choice. A local retry
    # may change it only while advancing the generation into queued; the
    # invocation keeps the immutable selection of every previous execution.
    def selection_changes_with_a_new_execution
      return if new_record?
      return unless will_save_change_to_provider_id? || will_save_change_to_model_ref? ||
        will_save_change_to_reasoning_effort? || will_save_change_to_reasoning_enabled?
      return if status == "queued" && execution_generation == execution_generation_in_database + 1

      errors.add(:base, :model_change_requires_new_execution)
    end

    # The summary this round reads instead of its history — only when it
    # ARRIVED. The summarizer is absorb, so a mark whose summary failed
    # stands in for nothing, on every reader: composer, serializer, history.
    # A delegate that ran and errored (`completed, is_error: true` — the
    # two-axis rule) is not a summary either: its text is an error the
    # agent's log explains, never history a round may read.
    def arrived_summary
      key = compaction.to_h[SUMMARY_SOURCE].presence
      return nil if key.nil?

      summary = agent_run.agent_run_tasks.find_by(node_key: key)
      summary if summary&.usable_summary?
    end

    def pruned_before = compaction.to_h[PRUNED_BEFORE].presence

    # The summarizer's own step: the seed of a between-turn summary turn's
    # loop, or the step a repaired round reads in place of its history.
    def summary_task?
      agent_run.conversation_turn&.compaction_summary? == true ||
        expansion_parent&.compaction.to_h[SUMMARY_SOURCE] == node_key
    end

    # Repaired either way: a marked round is never armed again.
    def repaired? = compaction.to_h.values_at(SUMMARY_SOURCE, PRUNED_BEFORE).any?(&:present?)

    # The node's own input body through the one inverse of its
    # decomposition: a lone text is the authored prompt, a message list is
    # round one's assembled request, nil when it has none — never the body's
    # JSON lines riding as one prompt.
    def input_value
      body = input_body
      return nil if body.nil?

      entries = body.entry_payloads
      return nil if entries.empty?

      Nexus::InputEntries.from(entries: entries, workload: "text_generation")
    end

    # This generation's own record of the call it made — the sealed
    # request, the `tool_calls` envelope, the reasoning trace — nil before
    # an invocation was minted.
    def invocation_body(role)
      return nil if selected_model_invocation_id.nil?

      ContentBody
        .where(model_invocation_id: selected_model_invocation_id, role: role)
        .includes(content_body_entries: :content_fragment)
        .first
    end
  end
end
