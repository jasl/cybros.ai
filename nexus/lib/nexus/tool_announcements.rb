module Nexus
  # The rules one announcement obeys: what an executor SERVES, for delivery
  # only — the sibling of ToolDeclarations, which rules what the model SEES.
  # Two facts, two writers; this one never shapes a round's tools list. The
  # two declaration keys an entry may carry (`description`, `input_schema`)
  # are what a machine says about itself, stored for an agent that authors a
  # declaration from a runner it did not load; compilation reads only the
  # declaration. The DOCUMENTS list is the third list the verb replaces
  # whole: what an executor can LOAD for a model, as `{name, description}`
  # under the skill grammar (Nexus::Skills) and nothing more — no `kind`:
  # the model never sees one, and a curating executor (ADR-0040) shapes an
  # MCP prompt or resource into this entry itself.
  module ToolAnnouncements
    # The runner's own tool-name rule (rho-runner Extensions::Tool::NAME_FORMAT),
    # mirrored so the door refuses what the runner could not have registered.
    NAME_FORMAT = /\A[a-zA-Z0-9_-]{1,64}\z/
    ENTRY_KEYS = %w[name effect_profile timeout_ms description input_schema].freeze
    DECLARATION_KEYS = %w[description input_schema].freeze
    DOCUMENT_KEYS = %w[name description].freeze
    PROFILE_VALUES = {
      "kind" => Nexus::ToolRegistry::EFFECT_KINDS,
      "destructive" => [true, false].freeze,
      "world" => Nexus::ToolRegistry::EFFECT_WORLDS,
      "idempotency" => Nexus::ToolRegistry::IDEMPOTENCY_KINDS,
      "reconciliation" => Nexus::ToolRegistry::RECONCILIATION_KINDS,
    }.freeze

    Refusal = Data.define(:code, :detail)

    class << self
      # The first refusal, or nil. `[]` is "serves nothing" and is accepted —
      # an agent application that announces nothing sees no row. A kernel name
      # is classified in either spelling: under a reserved namespace it is
      # `reserved_namespace`, and in the TWO ADMITTED CLASSES it is admitted in
      # its wire spelling — OVERRIDABLE (nexus.memory.* today: the door rules
      # delivery, and a workspace's opt-in is what routes it) and ROUTED BY
      # SOURCE (`skill`: the announcer of a document serves the load of its
      # name, `Nexus::ToolRegistry::ROUTED_BY_SOURCE`). Every other defect is
      # `invalid_announcement`, named by entry index and field.
      def refusal(entries)
        entries = Array.try_convert(entries)
        return invalid("tools", "must be a list of entries") if entries.nil?

        seen = Set.new
        entries.each_with_index do |entry, index|
          hash = Hash.try_convert(entry)
          return invalid("tools[#{index}]", "must be an object") if hash.nil?

          refusal = entry_refusal(hash, index, seen)
          return refusal if refusal
        end
        nil
      end

      # The environment document is OPAQUE (executor-local semantics belong
      # to the executor): an object or nothing, no key read. nil is "none",
      # which the row stores as `{}`.
      def environment_refusal(document)
        return nil if document.nil? || Hash.try_convert(document)

        invalid("environment", "must be an object")
      end

      # Sorted by name and reduced to the closed entry shape: unknown keys are
      # dropped at the boundary, the profile keeps exactly the five keys, the
      # declaration keys are kept verbatim when announced.
      def canonical(entries)
        entries.map { |entry| canonical_entry(entry) }.sort_by { |entry| entry["name"] }
      end

      # The documents' refusal, or nil. nil is "none" (the row stores `[]`);
      # a present list is judged entry by entry — an object, a `name`
      # under the skill grammar met once, a `description` that is a
      # non-empty string within the grammar's byte bound — and named by
      # index and field as a tool entry is. A document never carries an
      # effect profile: a load is the announcer's read, addressed by the
      # `skill` tool it must also announce (executor.md).
      def document_refusal(entries)
        return nil if entries.nil?

        entries = Array.try_convert(entries)
        return invalid("documents", "must be a list of entries") if entries.nil?

        seen = Set.new
        entries.each_with_index do |entry, index|
          hash = Hash.try_convert(entry)
          return invalid("documents[#{index}]", "must be an object") if hash.nil?

          refusal = document_entry_refusal(hash, index, seen)
          return refusal if refusal
        end
        nil
      end

      # Sorted by name and reduced to the two keys; nil is `[]`.
      def canonical_documents(entries)
        Array(entries).map { |entry| entry.slice(*DOCUMENT_KEYS) }.sort_by { |entry| entry["name"] }
      end

      private

        def invalid(field, message)
          Refusal.new(code: "invalid_announcement", detail: "#{field} #{message}")
        end

        def entry_refusal(entry, index, seen)
          name = String.try_convert(entry["name"])
          field = "tools[#{index}]"
          refusal = kernel_name_refusal(field, name)
          return refusal if refusal
          return invalid("#{field}.name", "must match #{NAME_FORMAT.inspect}") unless name&.match?(NAME_FORMAT)
          return invalid("#{field}.name", "repeats #{name}") unless seen.add?(name)

          profile_refusal("#{field}.effect_profile", entry["effect_profile"]) ||
            timeout_refusal("#{field}.timeout_ms", entry) ||
            description_refusal("#{field}.description", entry) ||
            input_schema_refusal("#{field}.input_schema", entry)
        end

        # The kernel's names in both spellings are classified BEFORE the
        # format rule, so a dotted canonical is refused for the right reason
        # when it is reserved, and for the format alone when it is merely
        # overridable (the wire spelling is what a node's `tool_name`
        # carries, so only that spelling is worth storing).
        def kernel_name_refusal(field, name)
          canonical = Nexus::ToolRegistry.resolve(name)
          return nil if canonical.nil?
          return nil unless Nexus::ToolRegistry.reserved_namespace?(canonical)

          Refusal.new(code: "reserved_namespace",
            detail: "#{field}.name names a reserved kernel namespace (#{Nexus::ToolRegistry.namespace(canonical)})")
        end

        # Exactly the closed vocabulary (ToolRegistry): an absent profile is
        # refused, never stored as "unknown = not replayable".
        def profile_refusal(field, profile)
          profile = Hash.try_convert(profile)
          return invalid(field, "is required") if profile.nil?
          return invalid(field, "must carry exactly #{Nexus::ToolRegistry::EFFECT_KEYS.join(", ")}") unless
            profile.keys.sort == Nexus::ToolRegistry::EFFECT_KEYS.sort

          PROFILE_VALUES.each do |key, allowed|
            return invalid("#{field}.#{key}", "must be one of #{allowed.inspect}") unless
              allowed.include?(profile[key])
          end
          nil
        end

        # A positive integer with no ceiling; an absent one means the
        # kernel default applies at dispatch.
        def timeout_refusal(field, entry)
          timeout = entry["timeout_ms"]
          return nil if timeout.nil?

          integer = Integer.try_convert(timeout)
          return nil if integer == timeout && integer.positive?

          invalid(field, "must be a positive integer")
        end

        # Optional; when present, a non-empty string. A key present with the
        # wrong shape is refused, never dropped.
        def description_refusal(field, entry)
          description = entry["description"]
          return nil if description.nil?

          text = String.try_convert(description)
          return nil if text && !text.strip.empty?

          invalid(field, "must be a non-empty string")
        end

        # Optional; when present, a JSON Schema object — the runner's own
        # load-time rule minus the compile: the kernel interprets no tool
        # arguments, the runner validates its own calls at claim.
        def input_schema_refusal(field, entry)
          schema = entry["input_schema"]
          return nil if schema.nil?
          return nil if Hash.try_convert(schema)&.fetch("type", nil) == "object"

          invalid(field, "must be a JSON Schema object (type: object)")
        end

        def document_entry_refusal(entry, index, seen)
          field = "documents[#{index}]"
          name = entry["name"]
          return invalid("#{field}.name", "must match #{Nexus::Skills::NAME_FORMAT.inspect}, at most " \
                                          "#{Nexus::Skills::NAME_MAX_LENGTH} characters") unless Nexus::Skills.skill_name?(name)
          return invalid("#{field}.name", "repeats #{name}") unless seen.add?(name)

          description = String.try_convert(entry["description"])
          return invalid("#{field}.description", "must be a non-empty string") if description.nil? || description.strip.empty?
          return invalid("#{field}.description", "exceeds #{Nexus::Skills::DESCRIPTION_MAX_LENGTH} bytes") if
            description.bytesize > Nexus::Skills::DESCRIPTION_MAX_LENGTH

          nil
        end

        def canonical_entry(entry)
          profile = entry["effect_profile"]
          timeout = entry["timeout_ms"]
          {
            "name" => entry["name"],
            "effect_profile" => Nexus::ToolRegistry::EFFECT_KEYS.to_h { |key| [key, profile[key]] },
            **(timeout.nil? ? {} : { "timeout_ms" => Integer.try_convert(timeout) }),
            **entry.slice(*DECLARATION_KEYS),
          }
        end
    end
  end
end
