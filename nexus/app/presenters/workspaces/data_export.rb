module Workspaces
  class DataExport < DiagnosticExport
    def initialize(workspace:)
      @workspace = workspace
    end

    private

      def records
        yield envelope("export", format: "nexus.workspace.data", version: 1,
          exported_at: Time.current.iso8601, scope: "current_workspace_documents", consistency: CONSISTENCY,
          retention: { versions: "current_only", conversations: "not_included", agent_private_data: "not_included" })
        memory { |record| yield record }
        store { |record| yield record }
        document = read { @workspace.prompt_documents.find_by(slot: "character") }
        if document
          yield envelope("prompt_document", prompt_document: AgentAPI::PromptDocumentPresenter.full(document))
        end
      end

      def envelope(type, **fields)
        { type: type, workspace_public_id: @workspace.public_id, **fields }
      end

      def memory
        scope = MemoryDocument.for_workspace(@workspace.id)
        if @workspace.tool_provider_override_for("memory_read")
          # The memory read door still permits the reserved skills/ paths.
          scope = scope.skills
          yield envelope("memory_unavailable", reason: "memory_overridden", except: "workspace/skills/")
        end
        ceiling = read { scope.maximum(:id) }
        cursor = 0
        while ceiling && cursor < ceiling
          page = read do
            scope.where(id: (cursor + 1)..ceiling).order(:id).limit(PAGE_SIZE)
              .eager_load(:memory_document_version).map { |document| [document.id, AgentAPI::MemoryPresenter.full(document)] }
          end
          break if page.empty?

          cursor = page.last.first
          page.each { |_, projection| yield envelope("memory", memory: projection) }
        end
      end

      def store
        ceiling = read { @workspace.store_entries.maximum(:id) }
        cursor = 0
        while ceiling && cursor < ceiling
          page = read do
            @workspace.store_entries.where(id: (cursor + 1)..ceiling).order(:id).limit(PAGE_SIZE)
              .map { |entry| [entry.id, AgentAPI::StoreEntryPresenter.full(entry)] }
          end
          break if page.empty?

          cursor = page.last.first
          page.each { |_, projection| yield envelope("store_entry", store_entry: projection) }
        end
      end
  end
end
