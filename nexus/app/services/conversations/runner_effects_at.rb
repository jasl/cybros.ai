module Conversations
  # Effects after a fork point include every variant in the source reach,
  # including hidden turns and inactive variants. The earliest claimed write
  # on each Runner describes that environment before successor work began.
  class RunnerEffectsAt
    def self.call(conversation:, position:)
      reach = Conversation::Timeline.new(conversation).reach
      expired = Run.joins(variant: :turn)
        .where(reach).where("turns.position > ?", position).where.not(details_pruned_at: nil)
      return Runs::RunnerEffects.unavailable if expired.exists?

      scope = Task.joins(run: { variant: :turn })
        .where(reach).where("turns.position > ?", position)
      Runs::RunnerEffects.fact(Runs::RunnerEffects.first_rows(scope))
    end
  end
end
