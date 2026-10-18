module MemoryDocuments
  # An exact passage replacement over the same immutable versions as a whole
  # write. The caller holds the anchor lock; member callers also require the
  # observed identity/version before matching text against the current content.
  class Edit
    def self.call(anchor:, old_text:, new_text:, expected:, revises: nil)
      document = anchor.documents.eager_load(:memory_document_version).find_by(name: anchor.name)
      return Write::Result.refused(:stale_object) if expected && !expected.matches?(document)
      return Write::Result.refused(:memory_not_found) if document.nil?

      old_text = old_text.to_s
      new_text = new_text.to_s
      return Write::Result.refused(:memory_edit_invalid) if old_text.empty?

      content = document.content
      first = content.index(old_text)
      return Write::Result.refused(:memory_edit_not_found) if first.nil?
      # Another start may overlap the first passage, including in multibyte text.
      return Write::Result.refused(:memory_edit_ambiguous) if content.index(old_text, first + 1)

      Write.call(anchor: anchor, content: content.sub(old_text) { new_text }, expected: expected,
        revises: revises, description: document.description)
    end
  end
end
