module Actors
  # Lazy per-input speaker resolution on the natural key, converging on
  # the unique-index winner; resolves only the acting user's own member Actor.
  class Resolve
    MEMBER_CHANNEL = "member"
    # The kernel's own voice, one per account: a compaction summary must
    # not be attributed to the member whose message triggered it.
    SYSTEM_CHANNEL = "system"
    SYSTEM_EXTERNAL_ID = "kernel"
    SYSTEM_DISPLAY_NAME = "System"

    class << self
      def member(account:, user:)
        find(account, user) || create(account, user)
      end

      def system(account:)
        find_system(account) || create_system(account)
      end

      private

        def find(account, user)
          Actor.find_by(
            account_id: account.id,
            channel_key: MEMBER_CHANNEL,
            external_id: user.public_id
          )
        end

        def find_system(account)
          Actor.find_by(
            account_id: account.id,
            channel_key: SYSTEM_CHANNEL,
            external_id: SYSTEM_EXTERNAL_ID
          )
        end

        # The same savepoint the member lane needs, for the same reason:
        # a lost first-contact race inside a caller's open transaction
        # would otherwise leave that transaction aborted.
        def create_system(account)
          Actor.transaction(requires_new: true) do
            Actor.create!(
              account: account, kind: "system",
              channel_key: SYSTEM_CHANNEL, external_id: SYSTEM_EXTERNAL_ID,
              display_name: SYSTEM_DISPLAY_NAME
            )
          end
        rescue ActiveRecord::RecordNotUnique
          find_system(account) || raise
        end

        # The savepoint is load-bearing: a lost race inside a caller's open
        # transaction would abort it before the recovery SELECT.
        def create(account, user)
          Actor.transaction(requires_new: true) do
            Actor.create!(
              account: account, kind: "member", user: user,
              channel_key: MEMBER_CHANNEL, external_id: user.public_id,
              display_name: user.display_name
            )
          end
        rescue ActiveRecord::RecordNotUnique
          find(account, user) || raise
        end
    end
  end
end
