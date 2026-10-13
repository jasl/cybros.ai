module Conversations
  # THE PRINCIPALS A CALLER MAY NAME on a conversation's access carrier,
  # resolved ONCE for the create envelope and the later change alike: each
  # entry names ONE member User of the account — by `user_public_id` or by
  # `handle` (`@lark` or `lark`), through the one resolver
  # `User.addressed_by` — never the system user, not full by derivation on
  # this row (the creator, the answerer: a row for either would lie), and
  # no principal named twice by either spelling (the unique index would
  # answer a second row with a 500). Anything else conceals as ONE code,
  # `principal_not_eligible`, with no detail: every name given is the
  # caller's own account's, and a client can print the listing it just
  # read.
  class AccessPrincipals
    Entry = Data.define(:user, :level)
    SPELLINGS = %w[user_public_id handle].freeze

    class << self
      # `entries` are the wire rows (`{"user_public_id" | "handle",
      # "level"}`), in the request's order — array order is the request's
      # identity. The levels are not judged here: the record's enum answers
      # an unknown word as `invalid`, never as ineligibility.
      def resolve(account_id:, derived_user_ids:, entries:)
        users = lookup(account_id: account_id, entries: entries)
        return nil if users.any?(&:nil?) || repeated?(users)
        return nil if users.any? { |user| derived_user_ids.include?(user.id) }

        entries.zip(users).map { |entry, user| Entry.new(user: user, level: entry["level"]) }
      end

      # The create door's pre-digest question: does the envelope name
      # one principal twice, by either spelling? Unknown names are not
      # repeats; the service refuses those inside.
      def repeated_principal?(account_id:, entries:)
        repeated?(lookup(account_id: account_id, entries: entries).compact)
      end

      private

        # One member per entry, nil where the entry spells its principal
        # two ways, no way, or names nobody of this account.
        def lookup(account_id:, entries:)
          entries.map do |entry|
            spellings = SPELLINGS.select { |key| entry[key].present? }
            next nil unless spellings.length == 1

            User.members.addressed_by(account_id, entry[spellings.first]).first
          end
        end

        def repeated?(users) = users.map(&:id).uniq.length != users.length
    end
  end
end
