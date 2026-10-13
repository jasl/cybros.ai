class User
  # THE HANDLE: a NAME beside the identity —
  # `agent_identifier` stays the program's registration identity, the
  # handle is what a person or a model addresses. Lowercase
  # `[a-z0-9][a-z0-9_-]{1,31}`, normalized like an email, UNIQUE PER ACCOUNT (the unique
  # index is the arbiter). A Human's default is
  # derived from its display name; an agent member's is the kernel's pick
  # from the shipped name table; either is suffixed `-2`, `-3` … past a
  # collision. The system user derives too (`system`). A caller-given
  # handle is never rewritten: the person chose it.
  #
  # The default is chosen against the rows of the moment; two creations in
  # one account choosing one word in one instant lose to the unique index
  # as a loud `RecordNotUnique` — nothing corrupts, one request fails.
  #
  # THE COOLDOWN: a released handle is reserved in
  # its account for fourteen days, so a model's own memory or a stale
  # summary saying `@old` cannot land on another principal. Two columns on
  # the row — `previous_handle`, `handle_changed_at`, stamped by a CHANGE
  # and never by creation — no table, no sweep: the uniqueness rule also
  # refuses a word that is another row's previous handle released within
  # the cooldown, and the time comparison expires it. Only the LATEST
  # previous name is reserved; one's own
  # reservation never blocks oneself; the creation default skips reserved
  # words too. Every rename narrates `handle_changed` on the member. The
  # resolver is UNCHANGED: an old handle resolves to nobody — the kernel
  # never redirects a released name, and a swap waits out the cooldown.
  module Handle
    extend ActiveSupport::Concern

    MAX_LENGTH = 32
    # The word's shape, unanchored: the route segment a named definition's
    # door constrains (routing forbids anchors); FORMAT anchors it.
    SEGMENT = /[a-z0-9][a-z0-9_-]{1,31}/
    FORMAT = /\A#{SEGMENT}\z/
    FALLBACK_BASE = "user".freeze
    ADDRESS_PREFIX = "@".freeze
    # The column is `uuid`: a word that is not one must never reach it.
    PUBLIC_ID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    COOLDOWN = 14.days

    included do
      normalizes :handle, with: ->(value) { value.to_s.strip.downcase.presence }

      validates :handle, presence: true
      validates :handle, format: { with: FORMAT }, allow_blank: true
      validates :handle, uniqueness: { scope: :account_id }, if: :will_save_change_to_handle?
      validate :handle_is_not_reserved, if: :will_save_change_to_handle?

      before_validation :assign_default_handle, on: :create
      before_update :stamp_previous_handle, if: :will_save_change_to_handle?
      after_update :narrate_handle_change, if: :saved_change_to_handle?

      # THE ONE RESOLVER: `@handle`, `handle` or a public id, answered
      # within one account; a word that is neither shape is nothing. The
      # access entries and agent selection read through it; callers
      # chain it on `members`, so the system user is never addressed.
      scope :addressed_by, ->(account_id, address) do
        word = address.to_s.strip.downcase.delete_prefix(ADDRESS_PREFIX)
        if word.match?(FORMAT)
          where(account_id: account_id, handle: word)
        elsif word.match?(PUBLIC_ID_FORMAT)
          where(account_id: account_id, public_id: word)
        else
          none
        end
      end

      # The account's rows whose previous handle is still within the
      # cooldown (released LESS than fourteen days ago: the reservation
      # expires on the boundary itself), and the one row reserving a word.
      scope :reserving_handles, ->(account_id) do
        where(account_id: account_id).where(arel_table[:handle_changed_at].gt(COOLDOWN.ago))
      end
      scope :reserving_handle, ->(account_id, handle) { reserving_handles(account_id).where(previous_handle: handle) }
    end

    class << self
      # The Human's default is `String#parameterize`'s word: transliterated,
      # lowercased, every run outside `[a-z0-9_-]` one dash, trimmed (an
      # underscore survives, as the FORMAT admits it), then capped; nil when
      # nothing addressable survives (a name entirely outside Latin script).
      def derive(display_name)
        base = display_name.to_s.parameterize[0, MAX_LENGTH].gsub(/-+\z/, "")
        base if base.match?(FORMAT)
      end

      # The base, else `base-2`, `base-3` … — the first not in `taken`,
      # the base shortened so the suffix fits the cap.
      def first_free(base, taken)
        return base unless taken.include?(base)

        (2..).each do |n|
          suffix = "-#{n}"
          candidate = "#{base[0, MAX_LENGTH - suffix.length].gsub(/-+\z/, "")}#{suffix}"
          return candidate unless taken.include?(candidate)
        end
      end
    end

    private

      def assign_default_handle
        return if handle.present? || account_id.nil?

        base = handle_base.presence ||
          (agent_member? ? Nexus::AgentHandles.pick : (Handle.derive(display_name) || Handle::FALLBACK_BASE))
        # Every handle of the account and every word it still reserves: a
        # member set is small, and a capped base's `-n` candidate is
        # shorter than the base it came from.
        taken = User.where(account_id: account_id).pluck(:handle).to_set |
          User.reserving_handles(account_id).pluck(:previous_handle)
        self.handle = Handle.first_free(base, taken)
      end

      # A new row has no id: `where.not(id: nil)` is every row, which is
      # right — nothing of its own to exempt.
      def handle_is_not_reserved
        return if handle.blank?

        if User.reserving_handle(account_id, handle).where.not(id: id).exists?
          errors.add(:handle, :reserved, days: COOLDOWN.in_days.to_i)
        end
      end

      def stamp_previous_handle
        self.previous_handle = handle_in_database
        self.handle_changed_at = Time.current
      end

      # Inside the rename's own transaction, so the fact and the row commit
      # together. The member is its own host (`EventHost`): the rows are
      # the member's, readable by nothing on the Agent API yet.
      def narrate_handle_change
        old, new = saved_change_to_handle
        ConversationEvent::Append.call(host: self, items: [{
          type: "handle_changed",
          payload: { "user_public_id" => public_id, "old" => old, "new" => new },
        }])
      end
  end
end
