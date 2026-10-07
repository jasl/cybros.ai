# THE MACHINE'S OWN INVARIANTS: edge legality against the type's declared
# transitions, and the CONJUNCTION INVARIANTS — every column beside
# `status` is meaningful in some statuses only, and each such conjunction
# is a validation over the row's own columns: pure, so a writer that
# drifts is refused at the write, never discovered by a reader.
module AgentRunTask::MachineValidations
  extend ActiveSupport::Concern

  included do
    validate :status_change_is_a_declared_transition
    # (7) An executor never rides without its role; (8) a row resting with a
    # holder outside the kernel is always on the park clock.
    validates :addressed_role, presence: true, if: -> { addressed_executor_id.present? }
    validates :await_started_at, presence: true, if: :clocked_rest_state?
    # A model validation, never a CHECK: a runner- or agent-addressed row
    # names its executor; only a tool_provider row may be a pool.
    validate :addressed_rows_name_an_executor
    validate :uncertain_is_a_claimed_call
    validate :an_awaits_word_follows_its_token
    validate :result_delivery_stamps_a_detached_settlement
    validate :the_resolution_names_its_status
    validate :the_claim_moves_as_one
    validate :the_stamps_follow_the_status
    validate :the_address_is_a_generations_fact
    validate :the_clock_sits_on_a_clocked_type
    validate :the_kind_bound_columns_follow_the_kind
    validate :the_fact_moves_as_one
    validate :the_hold_sits_on_the_stage
  end

  # Edge legality is the same kind of fact as inclusion, so it is one
  # validation; it also covers the append door's `update!` on a newborn join,
  # which never passes the narration funnel.
  def status_change_is_a_declared_transition
    return unless status_changed?

    from = new_record? ? nil : status_was
    return if self.class.transitions.fetch(from, []).include?(status)

    errors.add(:status, :undeclared_transition,
      kind: self.class.task_kind, from: from.inspect, to: status.inspect)
  end

  private

    def addressed_rows_name_an_executor
      return if addressed_role.nil? || addressed_role == "tool_provider"
      return if addressed_executor_id.present?

      errors.add(:addressed_executor, :blank)
    end

    # (1) `uncertain` is the sweep's word for a CLAIMED call that expired
    # with no result; an unclaimed row expires `timed_out`, whatever its profile.
    def uncertain_is_a_claimed_call
      errors.add(:claimed_at, :required_for_uncertain) if status == "uncertain" && claimed_at.blank?
    end

    # (2) An await's park word is a function of its token: `awaiting_input`
    # is the tokenless ask, `dispatched` the rendezvous whose token rode out.
    def an_awaits_word_follows_its_token
      return unless await?

      contradicts = (status == "awaiting_input" && resolution_token.present?) ||
        (status == "dispatched" && resolution_token.blank?)
      errors.add(:resolution_token, :contradicts_status) if contradicts
    end

    # (3) Mail is the kernel delivering a DETACHED answer after the reply
    # was final: never on a foreground row, never on one still live.
    def result_delivery_stamps_a_detached_settlement
      errors.add(:result_delivered_at, :unmailable) if result_delivered_at.present? && !(detached && terminal?)
    end

    # (4) The stamp names the status it resolved: `abandoned` a failure,
    # `canceled` the person's cancel.
    def the_resolution_names_its_status
      case failure_resolution
      when "abandoned" then errors.add(:failure_resolution, :contradicts_status) unless failure?
      when "canceled" then errors.add(:failure_resolution, :contradicts_status) unless status == "canceled"
      else nil
      end
    end

    # (5) The claim is one fact in three columns — the token, when, the
    # claimant's public-id snapshot (which survives its reap) — and only a
    # tool call is ever claimed: an await's proof is its own token.
    def the_claim_moves_as_one
      parts = [claim_token, claimed_at, claimed_by_executor_public_id]
      return if parts.all?(&:blank?)

      errors.add(:claimed_at, :partial_claim) unless parts.all?(&:present?) && tool_call?
    end

    # (6) Nothing spent has no `started_at`; started work has one and no
    # `completed_at`; a settled row has its `completed_at`.
    def the_stamps_follow_the_status
      if AgentRunTask::PRE_DISPATCH_STATUSES.include?(status)
        errors.add(:started_at, :contradicts_status) if started_at.present?
        errors.add(:completed_at, :contradicts_status) if completed_at.present?
      elsif started?
        errors.add(:started_at, :contradicts_status) if started_at.blank?
        errors.add(:completed_at, :contradicts_status) if completed_at.present?
      elsif terminal?
        errors.add(:completed_at, :contradicts_status) if completed_at.blank?
      end
    end

    # (7) The address is a generation's fact, written at the start and
    # cleared by a person's retry: a `queued` row names nobody, and an
    # executor never rides without its role.
    def the_address_is_a_generations_fact
      if status == "queued" && (addressed_role.present? || addressed_executor_id.present?)
        errors.add(:addressed_role, :contradicts_status)
      end
    end

    # (8) The park clock is a clocked type's alone — the sweep's frontier
    # reads exactly this pair with the presence declared above.
    def the_clock_sits_on_a_clocked_type
      errors.add(:await_started_at, :unclocked) if await_started_at.present? && !clocked?
    end

    # The rest states a holder outside the kernel occupies: on the clock.
    def clocked_rest_state? = clocked? && %w[dispatched awaiting_input needs_approval].include?(status)

    # (9) An error key rides a failure or a cancel, an invocation rides a
    # round, a resolution token rides an await.
    def the_kind_bound_columns_follow_the_kind
      if error_key.present? && !(failure? || status == "canceled")
        errors.add(:error_key, :contradicts_status)
      end
      errors.add(:selected_model_invocation, :not_a_round) if selected_model_invocation_id.present? && !model_task?
      errors.add(:resolution_token, :not_an_await) if resolution_token.present? && !await?
    end

    # (10) The approval fact is one fact in three columns: the origin and
    # the time together or not at all, and a named approver only under a
    # `human|agent` grant — a mode, rule, author or kernel grant names
    # nobody.
    def the_fact_moves_as_one
      if approval_origin.present? != approval_decided_at.present?
        errors.add(:approval_origin, :partial_fact)
      end
      return if approved_by_user_id.blank? || %w[human agent].include?(approval_origin)

      errors.add(:approved_by_user, :not_a_principals_grant)
    end

    # (11) A held row is always on the clock, and a decided row never
    # rests: `needs_approval` carries `await_started_at` and no fact.
    def the_hold_sits_on_the_stage
      return unless held?

      errors.add(:approval_origin, :contradicts_status) if approval_origin.present?
    end
end
