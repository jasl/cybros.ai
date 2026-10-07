module Nexus
  # THE ONE OWNER of the skill grammar:
  # a skill is a `MemoryDocument` under the reserved `skills/` name
  # prefix with a description — content with a scope, not a role's
  # property. The doors, the model's memory verbs, the catalog block and
  # the announcement refusal all read the rules here and restate none.
  #
  # The name grammar after the prefix is the agentskills specification's
  # (`[a-z0-9]`, single hyphens, ≤ 64) — STRICTER than
  # `MemoryDocument::NAME_FORMAT`, which admits `_. /`, because a skill
  # name is typed back by a model from the catalog and must match a
  # directory name on a runner byte for byte: `skills/pdf/extract` and
  # `skills/PDF` are refused, never normalized.
  module Skills
    PREFIX = "skills/".freeze
    NAME_FORMAT = /\A[a-z0-9](?:-?[a-z0-9])*\z/
    NAME_MAX_LENGTH = 64
    # The agentskills specification's own bound on a description — the line
    # the model reads in its turn's skills block to choose.
    DESCRIPTION_MAX_LENGTH = 1024
    # The header of the assembly's `skills` block: its first words are
    # what the `skill` tool's description points at, so the two texts
    # name each other through this one constant.
    CATALOG_HEADER = <<~TEXT.strip.freeze
      Skills available now. A skill is a reusable set of instructions for a kind of
      task; the list carries summaries only — load a skill with the skill tool
      before following or quoting it.
    TEXT
    # The header's first words — the name the `skill` tool's description
    # and its `name` parameter quote (`Nexus::ToolRegistry`), derived from
    # the header so the two texts cannot drift apart.
    CATALOG_TITLE = CATALOG_HEADER[/\A[^.]+/].freeze

    class << self
      # A bare skill name (the path's remainder after the prefix) under the
      # grammar and its length bound.
      def skill_name?(name)
        text = String.try_convert(name)
        !text.nil? && text.length <= NAME_MAX_LENGTH && text.match?(NAME_FORMAT)
      end

      # THE ONE PREDICATE for "this document is a skill": the prefix alone.
      # The writer guarantees the description; a second condition here
      # would be a second definition of the kind.
      def reserved?(document_name)
        String.try_convert(document_name).to_s.start_with?(PREFIX)
      end

      # The skill name a document name carries, or nil when the name is not
      # under the prefix.
      def name_of(document_name)
        text = String.try_convert(document_name).to_s
        return nil unless text.start_with?(PREFIX)

        text.delete_prefix(PREFIX)
      end
    end
  end
end
