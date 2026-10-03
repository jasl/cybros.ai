class User
  # THE NAMED DEFINITION: an agent profile minted by another's bearer as
  # its DEFINITION — `<declarer identifier>/ <name>`, composed by the door
  # from this one separator and never read back (the kernel lists by
  # column, never by prefix); no credential, no address; it answers
  # conversations and never claims or connects.
  module NamedDefinition
    extend ActiveSupport::Concern

    DEFINITION_SEPARATOR = "/".freeze
    DESCRIPTION_MAX_LENGTH = 1024

    included do
      # The instance that DECLARED this named definition (both scopes: the
      # publisher of a steward-scoped row is its `derived_from`), and the rows
      # this instance declared. No `dependent:`, as `stewarded_agents` declares
      # none: removal is a status cascade (`Lifecycle#remove`), the FK nullifies.
      belongs_to :derived_from, class_name: "User", optional: true
      has_many :named_definitions, class_name: "User", foreign_key: :derived_from_id, inverse_of: :derived_from

      # How long a named definition lives: `instance` — re-declared at every
      # boot of its declarer, removed with it; `steward` — published, persists
      # on its own for every agent of the steward. NULL on every paired row:
      # the column the door matches on.
      enum :definition_scope, %w[instance steward].index_by(&:itself),
        validate: { allow_nil: true }, scopes: false, prefix: true
      # The base the default handle is built from when the creator names one
      # (a named definition's name), else the kernel's own pick (`Handle`).
      attr_accessor :handle_base

      # The named definition's three facts: a scope iff a declarer, a declarer
      # that is itself an agent member; the description — the one line the
      # spawner's model chooses it by — one printable line, so a newline can
      # never forge a roster line; absent on humans and the system user.
      validates :derived_from, presence: true, if: -> { definition_scope.present? }
      validates :definition_scope, presence: true, if: :derived_from_id?
      validate :derived_from_is_an_agent_member
      validates :description, absence: true, if: -> { human? || system? }
      validates :description, presence: true, if: :named_definition?
      validates :description,
        length: { maximum: DESCRIPTION_MAX_LENGTH },
        format: { with: /\A[[:print:]]+\z/ },
        allow_nil: true
    end

    # A named definition: declared by another profile's bearer, its scope
    # says how long it lives; `published?` is the steward-scoped one.
    def named_definition? = derived_from_id.present?
    def published? = definition_scope_steward?

    # The definition's NAME — the tail of the composed identifier. Sound
    # without parsing the declarer's part: a name is a handle word and holds
    # no separator, so the last segment is exactly it whatever the prefix.
    def definition_name = named_definition? ? agent_identifier.rpartition(DEFINITION_SEPARATOR).last : nil

    # The identifier the dedication fence judges (Workspace::Access): a named
    # definition's is its declarer's — it answers where its parent answers.
    def root_identifier = derived_from&.agent_identifier || agent_identifier

    private

      def derived_from_is_an_agent_member
        errors.add(:derived_from, :invalid) if derived_from && !derived_from.agent_member?
      end
  end
end
