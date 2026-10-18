module PromptDocuments
  # Whole-slot replace, intrinsically idempotent: one row per (anchor,
  # slot), `version` bumped on every rewrite. THE CALLER HOLDS THE ANCHOR
  # ROW (`MemoryDocuments::Write`'s sentence): the workspaces or users row
  # is the serialization point and the doors take it FIRST in ladder order;
  # `prompt_documents` joins no ladder. No `note_context_change`: the next
  # turn of every conversation reads the slot live.
  class Write
    # `detail` names what the refusal is about — the unknown macro's word.
    Result = Data.define(:outcome, :document, :detail) do
      class << self
        def written(document) = new(outcome: :written, document: document, detail: nil)
        def refused(code, detail: nil) = new(outcome: code, document: nil, detail: detail)
      end

      def written? = outcome == :written
    end

    def self.call(...) = new(...).call

    # `anchor` is `{workspace:}` or `{user:}` — the row the caller locked.
    def initialize(anchor:, slot:, content:, role: nil)
      @anchor = anchor
      @slot = slot
      @content = content
      @role = role
    end

    def call
      text = String.try_convert(@content)
      return Result.refused(:prompt_document_invalid) if text.nil?
      # The summarizer slot is content-only: its reader is a raw
      # `instructions` string and would ignore a role, so a role other
      # than the default is a lie-shaped field, refused rather than stored.
      return Result.refused(:prompt_document_invalid) if summarizer_role?

      PromptDocument.transaction do
        document = scope.find_or_initialize_by(slot: @slot) { |fresh| fresh.account = account }
        document.assign_attributes(
          content: text,
          role: @role.presence || PromptDocument::DEFAULT_ROLE,
          version: document.persisted? ? document.version + 1 : 1
        )
        document.save ? Result.written(document) : refused(document)
      end
    end

    private

      def summarizer_role?
        @slot == PromptDocument::SUMMARIZER_SLOT && @role.present? && @role != PromptDocument::DEFAULT_ROLE
      end

      def anchor_row = @anchor[:workspace] || @anchor.fetch(:user)
      def account = anchor_row.account
      def scope = anchor_row.prompt_documents

      def refused(document)
        errors = document.errors
        if errors.of_kind?(:content, Nexus::SizeBounds::REJECTION)
          Result.refused(:prompt_document_too_large)
        elsif errors.of_kind?(:content, :macro_unknown)
          Result.refused(:prompt_document_macro_unknown, detail: document.unknown_macro)
        elsif errors.of_kind?(:slot, :anchor_mismatch) || errors.of_kind?(:slot, :inclusion)
          Result.refused(:prompt_slot_unavailable, detail: document.slot)
        else
          Result.refused(:prompt_document_invalid)
        end
      end
  end
end
