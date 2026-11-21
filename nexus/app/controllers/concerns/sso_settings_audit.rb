module SsoSettingsAudit
  private

    def audit_sso_setting(action, target, result, reason: nil, connections: nil)
      Sso::Audit.record(account: Current.account, actor: Current.user, target: target,
        action: action, result: result, reason: reason, connections: connections)
    end

    def current_sso_administrator?
      # The Account policy lock precedes this User lock; a concurrent role
      # change, suspension or removal is serialized with the configuration write.
      actor = Current.account.users.lock.find(Current.user.id)
      actor.active_human_member? && actor.admin? && Session.find_usable(Current.session.public_id)
    end

    def require_sso_admin_write
      Current.account.with_lock do
        if current_sso_administrator?
          yield
        else
          audit_sso_setting(action_name, Current.account.public_id, :refused, reason: :administrator_required)
          head :forbidden
        end
      end
    end
end
