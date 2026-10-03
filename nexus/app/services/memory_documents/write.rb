module MemoryDocuments
  # Whole-document replace, without retained version history. HTTP callers
  # supply the row/version they observed; native tools explicitly pass nil
  # for ordinary replacement. The old content version is reclaimed, and
  # the reclaim may lose to a fork's RESTRICT.
  #
  # THE CALLER HOLDS THE ANCHOR ROW (`Scopes::Anchor::Result#lockable`),
  # like `Delete`: it is the write's serialization point and the cap
  # count's, and the doors take it FIRST in ladder order — before the
  # conversation they then hold for the fence (`Memory::Run#revising`,
  # `Conversations::Memory::Apply#apply`, the profile door). A lock taken
  # here again would land AFTER the conversation in the SQL stream, and
  # the lock-order guard reads tables, not rows.
  #
  # THE ONE WRITER BOTH DOORS CALL is where a skill row is judged:
  # a `skills/` path needs a name
  # under the skill grammar, a rung that is not the conversation's (a
  # skill is never per conversation — a fork would copy it into a second
  # authority for one instruction), and a description; a plain document
  # takes none. Four words, one sentence each, in that order.
  class Write
    Result = Data.define(:outcome, :document) do
      class << self
        def written(document) = new(outcome: :written, document: document)
        def refused(code) = new(outcome: code, document: nil)
      end

      def written? = outcome == :written
    end

    def self.call(...) = new(...).call

    # `revises` is the conversation this write is FOR — the one whose next
    # reply assembles differently — and it owes the fence every such write
    # owes, whichever scope the document lands in. Nil for a standalone
    # loop, which assembles for nobody.
    def initialize(anchor:, content:, expected:, revises: nil, description: nil)
      @anchor = anchor
      @content = content
      @revises = revises
      @description = description
      @expected = expected
    end

    def call
      text = String.try_convert(@content)
      return Result.refused(:memory_content_invalid) if text.nil?

      refusal = skill_refusal
      return Result.refused(refusal) if refusal

      MemoryDocument.transaction do
        existing = @anchor.documents.find_by(name: @anchor.name)
        next Result.refused(:stale_object) if @expected && !@expected.matches?(existing)
        next Result.refused(:memory_full) if existing.nil? && at_capacity?

        version = build_version(text)
        next Result.refused(version_refusal(version)) unless version.persisted?

        result = existing ? repoint(existing, version) : create(version)
        @revises&.note_context_change if result.written?
        result
      end
    end

    private

      # The prefix decides which rules apply; nothing else about the row
      # does (the prefix is the kind). The description is normalized once
      # at this boundary: absent, a string, or neither.
      def skill_refusal
        return (:memory_description_invalid unless @description.nil?) unless
          Nexus::Skills.reserved?(@anchor.name)
        return :skill_name_invalid unless Nexus::Skills.skill_name?(Nexus::Skills.name_of(@anchor.name))
        return :skill_scope_unavailable if @anchor.scope == "conversation"

        text = String.try_convert(@description)
        return :skill_description_required if @description.nil? || text&.strip&.empty?

        # A string within the agentskills bound, in BYTES — the line a model
        # reads in its skills block; the model validation's character bound
        # can never fire past this one.
        :memory_description_invalid if text.nil? || text.bytesize > MemoryDocument::DESCRIPTION_MAX_LENGTH
      end

      def at_capacity?
        @anchor.documents.count >= MemoryDocument::MAX_DOCUMENTS_PER_ANCHOR
      end

      def build_version(text)
        MemoryDocumentVersion.create(account: account, content: text)
      end

      def version_refusal(version)
        return :memory_document_too_large if
          version.errors.of_kind?(:content, Nexus::SizeBounds::REJECTION)

        :memory_content_invalid
      end

      def repoint(document, version)
        previous_id = document.memory_document_version_id
        document.update!(memory_document_version: version, description: @description)
        MemoryDocumentVersion.reclaim(previous_id)
        Result.written(document)
      end

      def create(version)
        document = MemoryDocument.create(
          account: account, name: @anchor.name, memory_document_version: version,
          description: @description, **@anchor.attributes
        )
        return Result.refused(:memory_path_invalid) unless document.persisted?

        Result.written(document)
      end

      def account = @anchor.lockable.account
  end
end
