module BillingSubjects
  # Submit-time attribution: runs at acceptance, never from settlement;
  # the unique index settles the creation race. Ownership is the only
  # policy — BillingSubject is never a third cost-control layer.
  class CreateOrVerify
    Result = Data.define(:outcome, :billing_subject) do
      def verified? = outcome == :verified
      def invalid? = outcome == :invalid
      def not_owner? = outcome == :not_owner
    end

    class << self
      def call(account:, acting_user:, key:)
        normalized = BillingSubject.normalize_key(key)
        return refuse(:invalid) if normalized.nil?
        return refuse(:invalid) unless BillingSubject.key_within_bounds?(normalized)
        return refuse(:invalid) if acting_user.account_id != account.id

        existing = BillingSubject.find_by(account_id: account.id, key: normalized)
        return verify(existing, acting_user) if existing

        create(account: account, acting_user: acting_user, key: normalized)
      end

      private

        def refuse(outcome) = Result.new(outcome: outcome, billing_subject: nil)

        # The same owner may reuse the key; a different owner receives the
        # STABLE ownership refusal — stable because it is derived from the
        # frozen row, so a retry says the same thing.
        def verify(subject, acting_user)
          return refuse(:not_owner) if subject.owning_user_id != acting_user.id

          Result.new(outcome: :verified, billing_subject: subject)
        end

        def create(account:, acting_user:, key:)
          subject = BillingSubject.create!(
            account: account, owning_user: acting_user, key: key
          )
          Result.new(outcome: :verified, billing_subject: subject)
        rescue ActiveRecord::RecordNotUnique
          # A concurrent first creation won; converge on it rather than
          # inventing a second identity for one key.
          winner = BillingSubject.find_by(account_id: account.id, key: key)
          raise unless winner

          verify(winner, acting_user)
        rescue ActiveRecord::RecordInvalid
          refuse(:invalid)
        end
    end
  end
end
