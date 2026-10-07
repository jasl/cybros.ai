module AgentAPI
  # One document shape for both prompt-document doors: the listing
  # carries the slot, its role, its size and its write count; the full
  # document adds the content as written — macros unrendered.
  class PromptDocumentPresenter
    class << self
      def listing(documents)
        documents.map { |document| entry(document) }
      end

      def full(document)
        entry(document).merge(content: document.content)
      end

      private

        def entry(document)
          { slot: document.slot, role: document.role, bytesize: document.bytesize,
            version: document.version, written_at: document.updated_at }
        end
    end
  end
end
