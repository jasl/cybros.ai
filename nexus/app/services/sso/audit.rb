module Sso
  module Audit
    def self.record(account:, actor:, target:, action:, result:, reason: nil, connections: nil)
      entry = { event: "sso_settings", account_public_id: account.public_id,
        actor_public_id: actor.public_id, target_public_id: target, action: action,
        result: result, reason: reason, connection_count: connections }.compact
      ActiveRecord.after_all_transactions_commit { Rails.logger.info(entry.to_json) }
    end
  end
end
