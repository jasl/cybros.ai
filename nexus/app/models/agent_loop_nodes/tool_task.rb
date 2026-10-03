module AgentLoopNodes
  # One tool call: the authored intent (name, input, an optional timeout)
  # and, once started, the inbox row itself — who it is addressed to, the
  # effect profile frozen at dispatch, the rotating claim.
  class ToolTask < AgentLoopNode
    attr_readonly :provider_id, :model_ref, :reasoning_effort

    # Either holder parks identically: `dispatched` for a runner through the
    # inbox, `running` for a kernel tool in one of our own jobs.
    include Parked

    DEFAULT_TIMEOUT_MS = 10.minutes.in_milliseconds
    # The park's name in the settle's error keys: `tool_failed`, `tool_timeout`.
    PARK_KIND = "tool".freeze
    # The head of a call's input a model-facing reader carries: enough to
    # tell the call apart, bounded so a large write never rides along.
    ARGUMENTS_BYTES = 200

    self.task_kind = "tool_task"

    # THE ONE MACHINE WITH THE APPROVAL STAGE: this node's effect reaches
    # the person's own files and shell. The stage leaves forward (approve —
    # the one grant site, the release), by a denial (`failed
    # approval_denied`, the row's own `on_failure` deciding the cascade), by
    # the park clock (`timed_out approval_expired`, the ask's `MAX_HOLD`),
    # or by a cancel — never to `skipped`, which a row past its sources'
    # settlement can no longer reach. `uncertain` is the sweep's word for a
    # claimed non-replayable call that expired with no result — adjudicable,
    # never replayed blind; a kernel row (`running`) is never claimed, so it
    # never reaches the word.
    self.transitions = {
      nil => %w[queued skipped],
      "queued" => %w[needs_approval failed canceled skipped],
      "needs_approval" => %w[running dispatched failed timed_out canceled],
      "running" => %w[completed failed timed_out canceled],
      "dispatched" => %w[completed failed timed_out uncertain canceled],
      "failed" => %w[queued],
      "timed_out" => %w[queued],
      "uncertain" => %w[queued],
      "completed" => [], "canceled" => [], "skipped" => [],
    }.freeze

    # The node whose effect reaches the person's own files and shell,
    # which is why it has the approval stage. Bypass automatically grants
    # model-authored calls unless a deny rule matches.
    def tool_call? = true

    # `tool_call` while an executor is asked for it, `approval` while a
    # person is; a kernel job (`running`) is nobody's inbox row.
    def inbox_kind
      case status
      when "dispatched" then "tool_call"
      when "needs_approval" then "approval"
      else nil
      end
    end

    # No create-time default: "authored none" stays observable so the
    # announced timeout frozen at dispatch can be the deadline's second source.
    def authored_timeout_ms = timeout_ms

    def announced_timeout_ms = effect_profile&.dig("timeout_ms")

    # Read off the profile FROZEN at dispatch, never the registry or the
    # announcement of the day: the row's own document is what the sweep
    # adjudicates. Absent reads write-capable.
    def replayable? = Nexus::ToolRegistry.replayable?(effect_profile)

    def settlement_claim_token = claim_token

    def park_kind = PARK_KIND

    # THE CALL AS A MODEL READS IT, one spelling for the delivered
    # envelope's `<call>` line and the summary's pointer: the name the
    # model called — an alias by its alias, never the kernel's wire name —
    # and the stored input (an aliased call's parameters already in the
    # kernel's spelling). `JSON.generate` keeps `&&` and `<` as written:
    # the narrow escaper guards the envelope, and HTML-safe JSON would hand
    # the model `\u0026\u0026` for a command it wrote.
    def called_name = tool_alias || tool_name

    def call_head = "#{called_name} #{arguments_head}"

    def arguments_head = arguments_json.truncate_bytes(ARGUMENTS_BYTES, omission: "…")

    def arguments_json = JSON.generate(tool_input)

    validates :tool_name, presence: true, length: { maximum: 128 }
    validates :timeout_ms, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
    validates :tool_input, bounded_json: { bound: :envelope_bound, shape: Hash },
      if: -> { new_record? || will_save_change_to_tool_input? }
  end
end
