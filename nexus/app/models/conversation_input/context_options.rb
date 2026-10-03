# THE ASSEMBLY INTENT (`context_options`): closed and typed, unlike the
# request_options bag — a typo'd intent that silently did nothing would
# defeat the bound asked for. The history bound, the replay policy, the
# client's inline text or slot override, and the turn's variables.
module ConversationInput::ContextOptions
  extend ActiveSupport::Concern

  # The client's own text in the assembly: `lead` then `tail`, behind
  # history and ahead of the prompt under the built-in order — or, naming
  # a `slot`, the override of that slot's registered document for this
  # turn: `slot` xor `position`, `role` optional beside a slot. A role the
  # lane refuses is the lane's typed refusal.
  INLINE_ROLES = %w[system developer user assistant].freeze
  # A positioned entry rides the turn's preface into every later turn's
  # history, behind earlier turns: `system` there is a mid-conversation
  # system message the Anthropic and Gemini lowerings hoist into the top
  # system block (moving byte one), and `assistant` is words the model
  # never said. A slot override keeps every role: it rides the leading run.
  POSITIONED_ROLES = %w[developer user].freeze
  INLINE_POSITIONS = %w[lead tail].freeze
  INLINE_KEYS = %w[role text position slot].freeze
  INLINE_LIMIT = 16

  included do
    # Judged when the intent is WRITTEN (the create, an edit while queued —
    # of the intent or of the mode it rides under) against the addressee's
    # row of that day; a later re-declaration is the drain's to name
    # (`prompt_template_invalid` parks the head), and the park's own state
    # change must not re-judge an intent it is naming.
    validate :context_options_must_be_valid,
      if: -> { new_record? || context_options_changed? || context_mode_changed? }
  end

  class_methods do
    # WHERE an inline entry lands — the one rule the door and the row share:
    # a slot (closed, no position) with an optional role, or a positioned
    # entry whose role is required.
    def inline_entry_addressed?(entry)
      if entry.key?("slot")
        PromptDocument::ASSEMBLY_SLOTS.include?(entry["slot"]) && !entry.key?("position")
      else
        entry.key?("role")
      end
    end

    # WHICH ROLE an inline entry may ride in — the one rule the row and a
    # template's turn check share: a slot override keeps every role (it
    # rides the leading run), a positioned entry only a POSITIONED_ROLES
    # one (it rides the turn's preface into every later turn's history).
    def inline_role_placed?(entry)
      entry.key?("slot") || POSITIONED_ROLES.include?(entry["role"])
    end
  end

  private

    def context_options_must_be_valid
      case context_options
      when Hash
        return if context_options.empty?
        # Only the assembled reply lane compiles, so only it has an assembly
        # for this intent to bound; anywhere else it would silently do nothing.
        return errors.add(:context_options, :invalid) if
          kind != "direct_reply" || context_mode == "raw"
        return errors.add(:context_options, :invalid) if
          (context_options.keys - %w[history reasoning_replay inline variables]).any?

        validate_history_intent(context_options["history"]) if context_options.key?("history")
        if context_options.key?("reasoning_replay")
          validate_reasoning_replay_intent(context_options["reasoning_replay"])
        end
        validate_inline_intent(context_options["inline"]) if context_options.key?("inline")
        validate_variables_intent(context_options["variables"]) if context_options.key?("variables")
      else
        errors.add(:context_options, :invalid)
      end
    end

    def validate_inline_intent(entries)
      case entries
      when Array
        return errors.add(:context_options, :invalid) if
          entries.empty? || entries.length > INLINE_LIMIT

        entries.each { |entry| validate_inline_entry(entry) }
      else
        errors.add(:context_options, :invalid)
      end
    end

    def validate_inline_entry(entry)
      case entry
      when Hash
        return errors.add(:context_options, :invalid) if
          (entry.keys - INLINE_KEYS).any?
        return errors.add(:context_options, :invalid) unless
          self.class.inline_entry_addressed?(entry)

        errors.add(:context_options, :invalid) unless
          entry["role"].nil? || INLINE_ROLES.include?(entry["role"])
        case entry["text"]
        when String
          errors.add(:context_options, :invalid) if entry["text"].blank?
          validate_inline_slot_macros(entry) if entry.key?("slot")
        else errors.add(:context_options, :invalid)
        end
        validate_inline_position(entry) unless entry.key?("slot")
      else
        errors.add(:context_options, :invalid)
      end
    end

    # A positioned entry lands where the addressee's template puts its
    # `lead` or `tail`; a template without that block has nowhere for it,
    # and an intent that would vanish is refused by name — as is a role
    # the turn's preface cannot carry (POSITIONED_ROLES).
    def validate_inline_position(entry)
      position = entry["position"] || "lead"
      return errors.add(:context_options, :invalid) unless INLINE_POSITIONS.include?(position)
      unless self.class.inline_role_placed?(entry)
        return errors.add(:context_options, :inline_role_unplaced, role: entry["role"])
      end

      errors.add(:context_options, :inline_position_unplaced, position: position) unless
        assembly_template.places?(position)
    end

    # THE TURN'S VARIABLES: values for the names the addressee's template
    # declares — admitted only where something compiles them (an
    # `assembly` addressee), closed to the declared names, each a string.
    # An intent nothing would read is invalid.
    def validate_variables_intent(variables)
      return errors.add(:context_options, :invalid) unless declaring_profile&.prompt_mechanism == "assembly"

      given = Hash.try_convert(variables)
      return errors.add(:context_options, :invalid) if given.nil?

      declared = assembly_template.variable_names
      given.each do |name, value|
        next errors.add(:context_options, :variable_undeclared, name: name) unless declared.include?(name.to_s)

        errors.add(:context_options, :invalid) if String.try_convert(value).nil?
      end
    end

    # A slot override is rendered by the slot door's registry, so it is
    # validated by it too: a word outside it is refused here by name,
    # exactly as the slot door refuses it — never rendered as literal
    # braces. A `system_prompt` override sees the addressee's declared
    # variables as its document would. A positioned entry is the
    # client's own text and is not a macro host.
    def validate_inline_slot_macros(entry)
      registry = Nexus::PromptMacros::REGISTRY
      registry += declaring_profile.declared_variable_names if entry["slot"] == "system_prompt" && declaring_profile
      name = Nexus::PromptMacros.unknown(entry["text"], registry)
      errors.add(:context_options, :macro_unknown, name: name) if name
    end

    # The replay policy for this one turn: none silences replay entirely,
    # last_turn replays the newest traced turn, all replays every one;
    # absent, the kernel's default (ContextAssembly::Replay::DEFAULT_MODE, all).
    def validate_reasoning_replay_intent(intent)
      case intent
      when Hash
        return errors.add(:context_options, :invalid) if
          (intent.keys - ["mode"]).any? || intent.empty?

        errors.add(:context_options, :invalid) unless
          %w[none last_turn all].include?(intent["mode"])
      else
        errors.add(:context_options, :invalid)
      end
    end

    def validate_history_intent(history)
      case history
      when Hash
        # An intent with no bounds is NO intent — the pristine {} is its
        # one spelling, so presence always means a live bound.
        return errors.add(:context_options, :invalid) if history.empty?
        return errors.add(:context_options, :invalid) if
          (history.keys - %w[max_entries token_budget_share]).any?

        case history["max_entries"]
        when nil
        when Integer
          # The same closed range the HTTP boundary enforces — two layers
          # must agree on what the vocabulary IS (200 is the
          # predecessor's own ceiling on this knob).
          errors.add(:context_options, :invalid) unless
            (0..200).cover?(history["max_entries"])
        else errors.add(:context_options, :invalid)
        end
        case history["token_budget_share"]
        when nil
        when Numeric
          share = history["token_budget_share"]
          errors.add(:context_options, :invalid) if share <= 0 || share > 1
        else errors.add(:context_options, :invalid)
        end
      else
        errors.add(:context_options, :invalid)
      end
    end
end
