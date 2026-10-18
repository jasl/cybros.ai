class ModelInvocation::Cancellation
  def self.call(...) = new(...).call

  def initialize(scope:, reason:, source_user_authority_generation: nil,
                 steward_shutdown_generation: nil)
    @scope = scope
    @reason = reason.to_s
    @source_user_authority_generation = source_user_authority_generation
    @steward_shutdown_generation = steward_shutdown_generation
  end

  # Called inside the transaction that commits the owner's fence; provider
  # start serializes on the same rows, so one guarded set update is the whole
  # synchronous cut. Cleanup and event projection are level-triggered.
  def call
    unless ModelInvocation::CANCELLATION_REASONS.include?(@reason)
      raise ArgumentError, "unknown cancellation reason: #{@reason}"
    end

    now = Time.current
    @scope.nonterminal.update_all(
      status: "canceled",
      cancellation_reason: @reason,
      canceled_at: now,
      terminal_at: now,
      source_user_authority_generation: @source_user_authority_generation,
      steward_shutdown_generation: @steward_shutdown_generation,
      updated_at: now
    )
  end
end
