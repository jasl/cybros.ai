module Conversations
  class ContextAssembly
    # THE THREE SLOTS OF THE DEFAULT TEMPLATE, in slot order:
    # `system_prompt` from the declaring profile, `character` from the
    # workspace, `persona` from the principal's controlling Human — each
    # an Inline segment in its registered role (`system` by default), so
    # the wire rule merges the system ones into the list's first item and
    # Anthropic lifts it. An inline entry naming a slot replaces that slot
    # for this assembly, registered or not; an absent slot renders
    # nothing. Macros are substituted here, from named sources, and never
    # stored. A template names which slots it places and where; the rest
    # are neither rendered nor read.
    class SlotBlocks
      # `versions` is the estimate's evidence — the registered documents
      # compiled, by slot; an override carries none. Not persisted.
      # `by_slot` is the same segments filed by slot for a template's layout.
      Blocks = Data.define(:segments, :versions, :by_slot) do
        def self.none = new(segments: [], versions: {}, by_slot: {})
      end

      class << self
        def call(conversation:, principal:, declaring_profile:, overrides: [], sources: nil,
                 slots: PromptDocument::ASSEMBLY_SLOTS)
          sources ||= MacroSources.call(conversation: conversation, principal: principal,
            declaring_profile: declaring_profile)
          new(conversation, principal, declaring_profile, overrides, sources, slots).call
        end
      end

      def initialize(conversation, principal, declaring_profile, overrides, sources, slots)
        # The Conversation or a `Source` (a standalone loop's room).
        @source = Source.of(conversation)
        @principal = principal
        @declaring_profile = declaring_profile
        @overrides = Array(overrides).index_by { |entry| entry["slot"] }
        @sources = sources
        @slots = PromptDocument::ASSEMBLY_SLOTS & slots
      end

      def call
        rendered = @slots.filter_map { |slot| block(slot) }
        # Every placed slot answers, an unfilled one with nothing.
        by_slot = @slots.to_h { |slot| [slot, []] }
          .merge(rendered.to_h { |slot, role, text, _version| [slot, Inline.call(role: role, text: text)] })
        Blocks.new(
          segments: by_slot.values.flatten,
          versions: rendered.filter_map { |slot, _role, _text, version| [slot, version] if version }.to_h,
          by_slot: by_slot
        )
      end

      private

        # [slot, role, rendered text, version] — nil when nothing fills the slot.
        def block(slot)
          override = @overrides[slot]
          registered = registered(slot)
          return nil if override.nil? && registered.nil?

          role = override&.fetch("role", nil) || registered&.role || PromptDocument::DEFAULT_ROLE
          text = override ? override["text"] : registered.content
          [slot, role, Nexus::PromptMacros.render(text, @sources), (registered&.version unless override)]
        end

        def registered(slot)
          anchor(slot)&.prompt_documents&.find_by(slot: slot)
        end

        def anchor(slot)
          case PromptDocument::SLOT_ANCHORS.fetch(slot)
          when :workspace then @source.workspace
          when :agent then @declaring_profile
          else @principal.controlling_human
          end
        end
    end
  end
end
