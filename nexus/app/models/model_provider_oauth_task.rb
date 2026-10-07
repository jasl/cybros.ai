# One outbound OAuth request, written before the bytes go out so a dead
# worker's successor can tell "may be in flight" from "finished". It stores
# the result, never the request; whether a step is sent again is the flow's
# rule (Claim), read from the session's state, not from this row.
class ModelProviderOAuthTask < ApplicationRecord
  EXCHANGE_KINDS = %w[user_code_request device_token_poll code_exchange token_refresh].freeze

  # The terminals are named for what the wire said. A dispatching row is a
  # request that may still be in the air; a sealed one is finished.
  DISPATCHING = "dispatching".freeze
  # A response came back and was acted on, so the session moved on from this
  # step. Says nothing about whether it was good news: a 403 pending poll and
  # a terminal provider refusal both land here.
  ANSWERED = "answered".freeze
  # The step did NOT advance — the client reported no answer, the worker
  # vanished past its deadline, or a response arrived late and was refused.
  # `normalized_status` carries the client's own word for which.
  SPENT = "spent".freeze
  STATES = [DISPATCHING, ANSWERED, SPENT].freeze

  # The column's width; a client error class name is never longer.
  NORMALIZED_STATUS_LIMIT = 32

  # The result moves as one unit with the terminal state: a half-written
  # result is a request whose fate is partly recorded.
  RESULT_FIELDS = %i[settled_at normalized_status result_kind].freeze

  belongs_to :account
  belongs_to :oauth_session,
    class_name: "ModelProviderOAuthSession",
    foreign_key: :model_provider_oauth_session_id,
    inverse_of: :oauth_tasks

  # Every binding and deadline fact is frozen at claim time. Only the state
  # and its result may ever be written, and only once.
  attr_readonly :account_id, :model_provider_oauth_session_id, :exchange_kind,
    :claimed_at, :deadline_at

  validates :exchange_kind, inclusion: { in: EXCHANGE_KINDS }
  enum :state, STATES.index_by(&:itself), default: :dispatching, validate: true, scopes: false
  validates :claimed_at, :deadline_at, presence: true

  validate :result_moves_with_the_state

  scope :dispatching, -> { where(state: DISPATCHING) }

  # Write-once by guard, not by callback: the UPDATE only matches a row that
  # is still dispatching, so two workers settling the same request cannot both
  # win and the loser learns it did.
  def settle(state:, normalized_status:, result_kind:, now: Time.current)
    won = self.class.where(id: id, state: DISPATCHING).update_all(
      state: state, settled_at: now, normalized_status: normalized_status,
      result_kind: result_kind, updated_at: now
    )
    return nil if won.zero?

    reload
  end

  private

    def result_moves_with_the_state
      settled = state != DISPATCHING
      recorded = RESULT_FIELDS.map { |field| !public_send(field).nil? }.uniq
      return if recorded == [settled]

      errors.add(:base, :torn_result)
    end
end
