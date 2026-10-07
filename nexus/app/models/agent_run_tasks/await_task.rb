module AgentRunTasks
  # A rendezvous parks until its deadline or its answer. An authored ask gives
  # its caller a resolution token; a model's ask answers to write standing.
  # An existing-task observation keeps its token inside the kernel, whose
  # ordinary scheduler reads the target without owning or changing its work.
  class AwaitTask < AgentRunTask
    attr_readonly :provider_id, :model_ref, :reasoning_effort, :reasoning_enabled
    attr_readonly :awaited_run_public_id, :awaited_task_key

    include Parked

    DEFAULT_TIMEOUT_MS = 1.hour.in_milliseconds
    # The park's name in the settle's error keys: `await_failed`, `await_timeout`.
    PARK_KIND = "await".freeze

    self.task_kind = "await_task"

    # No approval stage — a park is already waiting on somebody. `dispatched`
    # when a resolution_token has a holder, `awaiting_input` for
    # the tokenless ask only a person can answer.
    self.transitions = {
      nil => %w[queued skipped],
      "queued" => %w[dispatched awaiting_input canceled skipped],
      "dispatched" => %w[completed failed timed_out canceled],
      "awaiting_input" => %w[completed failed timed_out canceled],
      "failed" => %w[queued],
      "timed_out" => %w[queued],
      "completed" => [], "canceled" => [], "skipped" => [],
    }.freeze

    # NO APPROVAL STAGE: a park is already waiting on somebody, and
    # whatever effect follows is its holder's rather than ours.
    def await? = true
    def observing_task? = awaited_task_key.present?

    validates :awaited_task_key, format: { with: NODE_KEY_FORMAT }, allow_nil: true
    validates :awaited_run_public_id, :resolution_token, presence: true, if: :observing_task?

    # The question with nobody assigned to it — answered by the token, the
    # same fact `awaiting_input` is a function of (the row validates the two agree).
    def asking? = answers_to_write_standing?

    def park_kind = PARK_KIND

    # A tokenless ask is the agent application's inbox row; a tokened
    # `dispatched` await has a holder and is never listed on that inbox.
    def inbox_kind = ("ask" if status == "awaiting_input")

    before_validation on: :create do
      self.await_timeout_ms ||= DEFAULT_TIMEOUT_MS
    end

    validates :await_timeout_ms, numericality: { only_integer: true, greater_than: 0 }
    # THE CHOICES: an ask may carry its options as DATA beside the
    # question — `ask_options`, one string each, and `ask_multi` when more
    # than one may be taken — stored on the row so every reader of the
    # question (the inbox row, the task detail) shows them; nil when the
    # asker gave none. The answer is the person's text.
    validate :ask_options_are_strings

    def ask_options_are_strings
      return if ask_options.nil? || Array.try_convert(ask_options)&.all?(String)

      errors.add(:ask_options, :invalid)
    end

    # The park's authored intent; Parked derives the deadline from it and
    # TimeoutSweep restates that in SQL — a mirror test pins the two equal.
    def authored_timeout_ms = await_timeout_ms

    # An ask announces nothing: the person's clock is the authored one.
    def announced_timeout_ms = nil

    def effective_timeout_ms = super.clamp(..MAX_HOLD_MS)

    def settlement_claim_token = resolution_token

    # The question a person answers: the await's authored input body — the
    # inbox row and the member task detail read the same text.
    def prompt = content_bodies.find { |body| body.role == "input" }&.effective_text

    # Asked of the node: a tool task's absent token means "not yet claimed",
    # so this is a question only an await answers.
    def answers_to_write_standing? = resolution_token.blank?
  end
end
