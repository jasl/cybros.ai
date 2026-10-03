module MemoryDocuments
  # Logical paths over database anchors. Execution passes its frozen configuration;
  # management and preview pass the conversation's current configuration.
  class Context
    Binding = Data.define(:name, :scope, :access, :row) do
      def anchor(document_name)
        Scopes::Anchor.call(path: "#{scope}/#{document_name}", **{ scope => row })
      end

      def matches?(conversation_id, workspace_id, user_id)
        { conversation: conversation_id, workspace: workspace_id, user: user_id }.fetch(scope) == row.id
      end
    end

    def initialize(workspace:, conversation:, principal:, configuration:)
      @workspace = workspace
      @conversation = conversation
      @principal = principal
      @default = configuration.nil?
      @configuration = @default ? MemoryContext::DEFAULT : MemoryContext.from_h(configuration)
    end

    def resolve(path, authoring: false)
      name, document = Scopes::Anchor.split(path)
      return refused(:memory_path_invalid) if document.nil?

      binding = bindings.find { |entry| entry.name == name }
      return refused(:memory_scope_unavailable) if binding.nil?
      return refused(:memory_read_only) if authoring && binding.access != :read_write
      if authoring && binding.scope == :conversation &&
          (binding.row.archived? || !binding.row.writable_by?(@principal))
        return refused(:memory_read_only)
      end

      binding.anchor(document)
    end

    # A missing explicit source never restores one of the default roots.
    def bindings
      @bindings ||= begin
        entries = @configuration.bindings
        ids = entries.filter_map { |entry| entry.conversation_public_id }
        sources = ids.empty? ? {} : Conversation.visible_to(@principal, workspace: @workspace)
          .where(public_id: ids).index_by(&:public_id)
        human = @conversation ? @conversation.memory_principal(@principal).controlling_human : @principal.controlling_human
        entries.filter_map do |entry|
          scope = entry.scope
          row = if scope == :conversation
            entry.conversation_public_id ? sources[entry.conversation_public_id] : @conversation
          elsif scope == :workspace
            @workspace
          else
            human
          end
          next if row.nil?
          next if scope == :conversation && (row.tombstoned? || !row.visible_to?(@principal))

          access = entry.access
          if scope == :conversation && (row.archived? || !row.writable_by?(@principal))
            access = :read
          end
          Binding.new(name: entry.name, scope: scope, access: access, row: row)
        end
      end
    end

    def sources_available?
      @default || @configuration.bindings.all? do |entry|
        resolved = bindings.find { |binding| binding.name == entry.name }
        resolved && (entry.access == :read || resolved.access == :read_write)
      end
    end

    def tool_refusal(verb:, input:)
      path = input["path"].to_s
      if %w[nexus.memory.ls nexus.memory.grep].include?(verb)
        return nil if path.empty? && bindings.any?

        path = "#{path.delete_suffix("/")}/x" unless path.include?("/") && !path.end_with?("/")
      end
      resolve(path, authoring: %w[nexus.memory.write nexus.memory.edit nexus.memory.delete].include?(verb)).refusal
    end

    def documents(path: nil)
      selected(path).reduce(MemoryDocument.none) { |scope, binding| scope.or(binding.anchor("x").documents) }
    end

    def paths(conversation_id, workspace_id, user_id, name, path: nil)
      selected(path).filter_map do |binding|
        "#{binding.name}/#{name}" if binding.matches?(conversation_id, workspace_id, user_id)
      end
    end

    def listing(path: nil)
      Listing.call(documents: documents(path: path), path_prefix: prefix(path),
        paths: ->(conversation_id, workspace_id, user_id, name) { paths(conversation_id, workspace_id, user_id, name, path: path) })
    end

    def search(pattern:, path: nil, ignore_case: false, limit: nil)
      unless path.to_s.empty?
        root = path.to_s.split("/", 2).first
        anchor = resolve("#{root}/x")
        return Search::Result.new(matches: [], truncated: false, refusal: anchor.refusal) unless anchor.resolved?
      end

      Search.call(documents: documents(path: path), pattern: pattern, path_prefix: prefix(path),
        ignore_case: ignore_case, limit: limit,
        paths: ->(document) { paths(document.conversation_id, document.workspace_id, document.user_id, document.name, path: path) })
    end

    def projection
      { bindings: bindings.map do |binding|
        { name: binding.name, scope: binding.scope.to_s, access: binding.access.to_s,
          "#{binding.scope}_public_id".to_sym => binding.row.public_id }
      end }
    end

    # Shared anchors can point in either direction between two conversations.
    # Order those rows by id so opposite writes cannot form a lock cycle.
    def with_locks(anchor)
      MemoryDocument.transaction do
        rows = [anchor.lockable, @conversation].compact.uniq
        rows.sort_by { |row| [row == anchor.user ? 0 : row == anchor.workspace ? 1 : 2, row.id] }.each(&:lock!)
        yield
      end
    end

    private

      def selected(path)
        root = path.to_s.split("/", 2).first
        root.blank? ? bindings : bindings.select { |binding| binding.name == root }
      end

      def prefix(path)
        path.to_s.split("/", 2).last if path.to_s.include?("/")
      end

      def refused(code)
        Scopes::Anchor::Result.new(scope: nil, conversation: nil, workspace: nil,
          user: nil, name: nil, refusal: code)
      end
  end
end
