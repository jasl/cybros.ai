# The nightly floor starts both indexed frontiers; each hop yields after a
# bounded source window. Retained dependencies are reconsidered next night.
class Conversations::PruneExecutionDetailsJob < ApplicationJob
  BATCH = 25

  def perform(account_id = nil, kind = "loops", after_at = nil, after_id = 0, cutoff_at = nil)
    unless account_id
      Account.where.not(execution_details_retention_days: nil).find_each do |account|
        %w[loops invocations].each { |source| self.class.perform_later(account.id, source) }
      end
      return
    end

    account = Account.find_by(id: account_id)
    return unless account

    result = Conversations::ExecutionDetails::Prune.call(account: account, batch: BATCH,
      kind: kind, after_at: after_at, after_id: after_id, cutoff_at: cutoff_at)
    self.class.perform_later(account_id, kind, *result.cursor) if result.more?
  end
end
