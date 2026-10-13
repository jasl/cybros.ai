module PromptDocuments
  # A delete ends the slot; the next turn of every conversation reads its
  # absence live. The caller holds the anchor row, as `Write` says.
  class Delete
    Result = Data.define(:outcome) do
      def deleted? = outcome == :deleted
    end

    def self.call(anchor:, slot:)
      scope = anchor[:workspace]&.prompt_documents || anchor.fetch(:user).prompt_documents
      PromptDocument.transaction do
        document = scope.find_by(slot: slot)
        next Result.new(outcome: :prompt_document_not_found) if document.nil?

        document.destroy!
        Result.new(outcome: :deleted)
      end
    end
  end
end
