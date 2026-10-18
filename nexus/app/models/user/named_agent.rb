class User
  # A named Agent is a persistent User declared by another Agent
  # under its identifier — `<declarer identifier>/ <name>`, composed by the door
  # from this one separator and never read back (the kernel lists by
  # column, never by prefix); no separate credential or address. Its declarer's
  # application serves accepted work while the named Agent remains its principal.
  module NamedAgent
    extend ActiveSupport::Concern

    NAMED_AGENT_SEPARATOR = "/".freeze
    DESCRIPTION_MAX_LENGTH = 1024

    included do
      # The instance that DECLARED this named Agent (both scopes: the
      # publisher of a steward-scoped row is its `derived_from`), and the rows
      # this instance declared. No `dependent:`, as `stewarded_agents` declares
      # none: removal is a status cascade (`Lifecycle#remove`), the FK nullifies.
      belongs_to :derived_from, class_name: "User", optional: true
      has_many :named_agents, class_name: "User", foreign_key: :derived_from_id, inverse_of: :derived_from

      # How long a named Agent lives: `instance` — re-declared at every
      # boot of its declarer, removed with it; `steward` — published, persists
      # on its own for every agent of the steward. NULL on every paired row:
      # the column the door matches on.
      enum :named_agent_scope, %w[instance steward].index_by(&:itself),
        validate: { allow_nil: true }, scopes: false, prefix: true
      # The base the default handle is built from when the creator names one
      # (a named Agent's name), else the kernel's own pick (`Handle`).
      attr_accessor :handle_base

      # The named Agent's three facts: a scope iff a declarer, a declarer
      # that is itself an agent member; the description — the one line used
      # to identify it in an Agent listing — one printable line, so a newline can
      # never forge a roster line; absent on humans and the system user.
      validates :derived_from, presence: true, if: -> { named_agent_scope.present? }
      validates :named_agent_scope, presence: true, if: :derived_from_id?
      validate :derived_from_is_an_agent_member
      validates :description, absence: true, if: -> { human? || system? }
      validates :description, presence: true, if: :named_agent?
      validates :description,
        length: { maximum: DESCRIPTION_MAX_LENGTH },
        format: { with: /\A[[:print:]]+\z/ },
        allow_nil: true
    end

    # A named Agent: declared by another Agent's bearer, its scope
    # says how long it lives; `published?` is the steward-scoped one.
    # The declarer FK may be nullified by collection; the retained scope still
    # identifies a named Agent and never promotes it to an independent program.
    def named_agent? = named_agent_scope.present?
    def published? = named_agent_scope_steward?

    # The named Agent's name — the tail of the composed identifier. Sound
    # without parsing the declarer's part: a name is a handle word and holds
    # no separator, so the last segment is exactly it whatever the prefix.
    def named_agent_name = named_agent? ? agent_identifier.rpartition(NAMED_AGENT_SEPARATOR).last : nil

    # The identifier the dedication fence judges (Workspace::Access): a named
    # Agent's is its declarer's — it answers where its parent answers.
    def root_identifier = derived_from&.agent_identifier || agent_identifier

    # Transport ownership does not replace the execution's identity or memory.
    # A steward transfer leaves the declaration's history but ends shared serving
    # until the two identities once again belong to the same Human.
    def application_owner
      if derived_from
        derived_from if derived_from.steward_id == steward_id
      else
        self
      end
    end

    private

      def derived_from_is_an_agent_member
        errors.add(:derived_from, :invalid) if derived_from && !derived_from.agent_member?
      end
  end
end
