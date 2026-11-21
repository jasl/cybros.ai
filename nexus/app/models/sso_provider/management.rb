module SsoProvider::Management
  extend ActiveSupport::Concern

  class_methods do
    # Scope both sides at the installation. An operator-issued temporary
    # password, a recovery fence or a disabled/stale binding never counts.
    def uncovered_users(account, sso_only:, except_provider: nil, statuses: [:active])
      members = account.users.where(status: statuses, kind: :human).joins(:identity)
      eligible = members.where(identities: { password_change_required: false, local_recovery_pending_at: nil })
      connections = SsoConnection.available.where(sso_providers: { account_id: account.id })
      connections = connections.where.not(sso_provider_id: except_provider.id) if except_provider
      covered = eligible.where(identity_id: connections.select(:identity_id))
      covered = covered.or(eligible.where.not(identities: { password_digest: nil })) unless sso_only
      members.where.not(id: covered.select(:id))
    end

    def set_policy(account, sso_only:)
      account.with_lock do
        if sso_only && (account.sso_providers.where(enabled: true).where.not(tested_at: nil).none? ||
            uncovered_users(account, sso_only: true).exists?)
          account.errors.add(:base, :sso_not_ready)
          false
        else
          account.update!(sso_only: sso_only)
        end
      end
    end
  end

  def uncovered_users_if_disabled(statuses: [:active])
    self.class.uncovered_users(account, sso_only: account.sso_only?, except_provider: self, statuses: statuses)
      .where(identity_id: sso_connections.select(:identity_id))
  end

  def test_candidate
    pending_configuration ? self.class.find(id).tap { |record| record.assign_attributes(pending_configuration.attributes) } : self
  end

  def save_settings(attributes, expected_version:)
    account.with_lock do
      reload
      next refused(:stale_configuration) unless lock_version == expected_version

      settings = attributes.stringify_keys
      new_name = settings.delete("name") || name
      settings.delete("client_secret") if settings["client_secret"].blank?
      candidate = test_candidate
      candidate = self.class.find(id) if candidate.equal?(self)
      candidate.assign_attributes(settings.merge("name" => new_name))
      established = !draft_authority_editable?
      if !candidate.valid?
        errors.merge!(candidate.errors)
        false
      elsif established && candidate.attributes.slice(*self.class::CONFIG_FIELDS) == attributes_for_publication
        update(name: new_name, pending_configuration: nil)
      elsif established
        update(name: new_name, pending_configuration: self.class::Configuration.new(candidate.attributes.slice(*self.class::CONFIG_FIELDS)))
      else
        update(candidate.attributes.slice("issuer", "protocol", *self.class::CONFIG_FIELDS).merge(name: new_name))
      end
    end
  end

  # Final publication shares the Account lock held by the callback while it
  # verifies the actual operator, browser Session and candidate revision.
  def accept_test(expected_version:)
    reload
    return refused(:stale_configuration) unless lock_version == expected_version
    return refused(:incomplete_configuration) unless test_candidate.ready_for_test?

    if pending_configuration
      candidate = pending_configuration.attributes
      if candidate["required_group"] != required_group && candidate["required_group"].present?
        return refused(:last_login_method) if uncovered_users_if_disabled.exists?
        self.admission_version += 1
      end
      assign_attributes(candidate)
      self.pending_configuration = nil
    end
    # Version zero belongs to an unpublished draft. The first successful
    # test fixes its identity authority, even after it is disabled later.
    self.admission_version = 1 if draft_authority_editable?
    update(tested_at: Time.current)
  end

  def set_enabled(value, expected_version:)
    account.with_lock do
      reload
      if lock_version != expected_version
        refused(:stale_configuration)
      elsif enabled? == value
        true
      elsif value && (!tested_at? || pending_configuration)
        refused(:test_required)
      elsif !value && account.sso_only? && account.sso_providers.where(enabled: true).where.not(id: id).none?
        refused(:last_provider)
      elsif !value && uncovered_users_if_disabled.exists?
        refused(:last_login_method)
      else
        update(enabled: value, tested_at: value ? tested_at : nil)
      end
    end
  end

  def retire(confirmation:, expected_version:)
    account.with_lock do
      reload
      if account.sso_only?
        refused(:deletion_forbidden)
      elsif lock_version != expected_version
        refused(:stale_configuration)
      elsif enabled?
        refused(:disable_first)
      elsif sso_connections.exists? && confirmation != name
        refused(:confirmation_required)
      elsif uncovered_users_if_disabled.exists?
        refused(:last_login_method)
      else
        destroy!
        true
      end
    end
  end

  private

    def attributes_for_publication
      attributes.slice(*self.class::CONFIG_FIELDS)
    end

    def refused(reason)
      errors.add(:base, reason)
      false
    end
end
