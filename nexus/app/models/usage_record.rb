# The permanently retained usage/cost receipt, one per started Attempt. Its one live association is
# Account: it freezes every other owner's public id and outlives them. Only spend-settlement and
# rollup markers, with their update timestamp, change after insert.
class UsageRecord < ApplicationRecord
  # `discarded` is a result that lost the terminal race; `abandoned` closes
  # the evidence window without an observed result. `failed` records an error
  # and may still carry provider usage and a known charge.
  ABANDONED = "abandoned".freeze
  STATUSES = %w[succeeded failed discarded abandoned].freeze
  # These dispositions need known money for complete statistics; failures
  # count as complete without it. Settlement charges any known positive cost,
  # including one recorded on a failed attempt.
  BILLABLE_STATUSES = %w[succeeded discarded].freeze
  COST_EVIDENCE_STATUSES = (BILLABLE_STATUSES + [ABANDONED]).freeze
  ROLLUP_COUNTER_COLUMNS = %i[
    request_count
    input_tokens
    cache_read_tokens
    cache_creation_tokens
    output_tokens
    reasoning_tokens
    total_tokens
    cost_amount
    cost_known_request_count
  ].freeze

  attr_readonly(*%i[
    account_id public_id idempotency_key
    model_invocation_public_id attempt_ordinal
    consumer_user_public_id payer_user_public_id workspace_public_id inference_request_public_id conversation_public_id
    provider_id catalog_model_ref wire_model_id provider_request_id
    workload purpose service_class admission_shape
    status error_code recorded_at
    provider_usage input_tokens output_tokens reasoning_tokens
    cache_read_tokens cache_creation_tokens total_tokens
    duration_ms time_to_first_token_ms
    unit_pricing cost_amount cost_unit
    billing_subject_key billing_subject_public_id
  ])

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account

  enum :status, STATUSES.index_by(&:itself), validate: true, scopes: false
  validates :attempt_ordinal, numericality: { only_integer: true, greater_than: 0 }
  validates :cost_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  # No wire reports a negative count honestly; the row-level backstop behind
  # the writer's own absent-on-negative read.
  validates :input_tokens, :output_tokens, :reasoning_tokens, :cache_read_tokens,
    :cache_creation_tokens, :total_tokens,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  # The receipt's money shapes: `priced` may carry an amount or none,
  # `admitted_free` exact zero, `unmetered` never any — blank is the
  # declaration.
  validate :money_matches_the_admission_shape

  scope :unsettled, -> { where(spend_settled_at: nil) }

  class << self
    def for_latest_attempt(invocation)
      latest_ordinal = invocation.attempts.order(ordinal: :desc).limit(1).select(:ordinal)
      find_by(
        account_id: invocation.account_id,
        model_invocation_public_id: invocation.public_id,
        attempt_ordinal: latest_ordinal
      )
    end

    def cache_hit_rate(input, cache_read)
      if input.zero?
        nil
      else
        (cache_read.to_f / input).round(6)
      end
    end
  end

  # One receipt contributes the same counters to both rebuildable rollup
  # planes. Non-billable failures count as cost-known vacuously. A billed
  # answer or an abandonment is known only when settlement recorded an amount.
  def rollup_counters
    {
      request_count: 1,
      input_tokens: input_tokens.to_i,
      cache_read_tokens: cache_read_tokens.to_i,
      cache_creation_tokens: cache_creation_tokens.to_i,
      output_tokens: output_tokens.to_i,
      reasoning_tokens: reasoning_tokens.to_i,
      total_tokens: total_tokens.to_i,
      cost_amount: cost_amount || 0,
      cost_known_request_count: cost_known_for_rollup? ? 1 : 0,
    }
  end

  private

    def cost_known_for_rollup?
      if COST_EVIDENCE_STATUSES.include?(status)
        !cost_amount.nil?
      else
        true
      end
    end

    def money_matches_the_admission_shape
      case admission_shape
      when "unmetered"
        errors.add(:cost_amount, :unmetered_carries_money) unless
          cost_amount.nil? && cost_unit.nil? && unit_pricing.nil?
      when "admitted_free"
        errors.add(:cost_amount, :free_not_zero) unless
          cost_amount&.zero?
      else
        nil
      end
    end
end
