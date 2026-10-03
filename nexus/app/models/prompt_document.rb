# One slot of the default template: `system_prompt` on an agent profile User,
# `character` on a Workspace, `persona` on a Human — memory's anchor SHAPE
# (exactly one rung, the anchor row is the lock), not its path grammar. A slot
# is a current text; the sealed request records what was compiled, so there is
# no versions table and `version` counts writes. A fourth slot, `summarizer`,
# is NOT placed: it is the agent profile's own text for the kernel-mode
# compaction summarizer, read as the step's raw `instructions` — no macros
# (that request has no sources), no role, never assembled.
class PromptDocument < ApplicationRecord
  # The slots the three placement sites read (SlotBlocks, the assembly
  # template's slot block, an input's inline slot address).
  ASSEMBLY_SLOTS = %w[system_prompt character persona].freeze
  SUMMARIZER_SLOT = "summarizer".freeze
  SLOTS = (ASSEMBLY_SLOTS + [SUMMARIZER_SLOT]).freeze
  ROLES = %w[system developer user].freeze
  DEFAULT_ROLE = "system".freeze
  # WHOSE row each slot may stand on: the room's, the agent's own, the person's.
  SLOT_ANCHORS = {
    "character" => :workspace, "system_prompt" => :agent, "persona" => :human, SUMMARIZER_SLOT => :agent,
  }.freeze

  # The slots one anchor kind holds — the profile door's word list.
  def self.slots_anchored(anchor) = SLOT_ANCHORS.select { |_slot, held| held == anchor }.keys
  CONTENT_BOUND = :prompt_document_bound

  attr_readonly :account_id, :workspace_id, :user_id, :slot

  belongs_to :account
  belongs_to :workspace, optional: true
  belongs_to :user, optional: true

  validates :slot, inclusion: { in: SLOTS }
  validates :role, inclusion: { in: ROLES }
  validates :content, exclusion: { in: [nil] }
  validate :exactly_one_anchor
  validate :slot_matches_anchor
  validate :content_must_be_bounded
  validate :macros_are_known

  # `bytesize` is a stored generated column (`octet_length(content)`), the
  # database's own count. Rails returns it on INSERT and UPDATE, so the
  # write presenter can read the saved value without another query.

  # The names this document may use: the built-in sources, and — for an agent
  # profile's own `system_prompt` — the variables its assembly template
  # declares. `character` and `persona` stand on other anchors and see the
  # four alone.
  def macro_registry
    # The summarizer's request is a raw `instructions` string on a kernel
    # loop with no sources: `{{agent}}` would reach the model as braces.
    return [] if slot == SUMMARIZER_SLOT
    return Nexus::PromptMacros::REGISTRY unless slot == "system_prompt" && user

    Nexus::PromptMacros::REGISTRY + user.declared_variable_names
  end

  # The first macro outside this document's registry, else nil.
  def unknown_macro = Nexus::PromptMacros.unknown(content, macro_registry)

  private

    # The one arbiter — there is no CHECK; the two partial unique indexes
    # are the structural backstop.
    def exactly_one_anchor
      return if [workspace_id, user_id].count(&:present?) == 1

      errors.add(:base, :exactly_one_anchor)
    end

    def slot_matches_anchor
      anchor = SLOT_ANCHORS[slot]
      return if anchor.nil?

      held =
        case anchor
        when :workspace then workspace.present?
        when :agent then user&.agent?
        else user&.human?
        end
      errors.add(:slot, :anchor_mismatch, slot: slot, anchor: anchor) unless held
    end

    def content_must_be_bounded
      return if content.nil?

      unless Nexus::SizeBounds.bytes_within?(CONTENT_BOUND, content.to_s.bytesize)
        errors.add(:content, Nexus::SizeBounds::REJECTION)
      end
      # Postgres text cannot store U+0000 (the memory version's own rule).
      errors.add(:content, :unsupported_text) if content.include?("\u0000")
    end

    def macros_are_known
      name = unknown_macro
      errors.add(:content, :macro_unknown, name: name) if name
    end
end
