module MemoryDocuments
  # Logical paths over database anchors. Execution passes frozen bindings;
  # management passes the host's current effective bindings. Archive keeps
  # execution writes while management remains read-only. Agent memory
  # belongs to the answerer; Speaker memory adds the explicit subject to that
  # Agent owner. Only a Human principal resolves an explicitly selected user root.
  class Context
    Binding = Data.define(:name, :scope, :access, :row, :speaker) do
      def initialize(speaker: nil, **) = super
      def anchor(document_name)
        return Scopes::Anchor.call(path: "speaker/#{document_name}", agent: row, speaker: speaker) if scope == :speaker

        Scopes::Anchor.call(path: "#{scope}/#{document_name}", **{ scope => row })
      end

      # A subject-bearing row never matches an Agent-private or Human-owned
      # binding even when its primary User id is the same.
      def matches?(conversation_id, workspace_id, user_id, speaker_id)
        return row.id == user_id && speaker.id == speaker_id if scope == :speaker
        return false if speaker_id

        { conversation: conversation_id, workspace: workspace_id, user: user_id, agent: user_id }.fetch(scope) == row.id
      end
    end

    def initialize(workspace:, conversation:, principal:, configuration:, agent:, execution: false)
      @workspace = workspace
      @conversation = conversation
      @principal = principal
      @agent = agent
      @execution = execution
      @default = configuration.nil?
      @configuration = @default ? MemoryContext::DEFAULT : MemoryContext.from_h(configuration)
    end

    def resolve(path, authoring: false)
      name, document = Scopes::Anchor.split(path)
      return refused(:memory_path_invalid) if document.nil?

      binding = bindings.find { |entry| entry.name == name }
      return refused(:memory_scope_unavailable) if binding.nil?
      return refused(:memory_read_only) if authoring && binding.access != :read_write
      if authoring && binding.scope == :conversation && !conversation_writable?(binding.row)
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
        speaker_ids = entries.filter_map(&:speaker_public_id)
        speakers = speaker_ids.empty? ? {} : Speaker.where(account_id: @principal.account_id, public_id: speaker_ids).index_by(&:public_id)
        human = @principal if @principal.human?
        entries.filter_map do |entry|
          scope = entry.scope
          row = case scope
          when :conversation
            entry.conversation_public_id ? sources[entry.conversation_public_id] : @conversation
          when :workspace then @workspace
          when :user then human
          when :agent then @agent
          when :speaker then (@agent if speakers[entry.speaker_public_id])
          else raise ArgumentError, "unknown memory scope #{scope.inspect}"
          end
          next if row.nil?
          next if scope == :conversation && (row.tombstoned? || !row.visible_to?(@principal))

          access = entry.access
          if scope == :conversation && !conversation_writable?(row)
            access = :read
          end
          Binding.new(name: entry.name, scope: scope, access: access, row: row, speaker: speakers[entry.speaker_public_id])
        end
      end
    end

    def sources_available?
      @default || @configuration.bindings.all? do |entry|
        next true if entry.scope == :speaker && entry.speaker_public_id.nil?

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

    def paths(conversation_id, workspace_id, user_id, name, speaker_id: nil, path: nil)
      selected(path).filter_map do |binding|
        "#{binding.name}/#{name}" if binding.matches?(conversation_id, workspace_id, user_id, speaker_id)
      end
    end

    def listing(path: nil)
      Listing.call(documents: documents(path: path), path_prefix: prefix(path),
        paths: ->(conversation_id, workspace_id, user_id, speaker_id, name) { paths(conversation_id, workspace_id, user_id, name, speaker_id: speaker_id, path: path) })
    end

    def search(pattern:, path: nil, ignore_case: false, limit: nil)
      unless path.to_s.empty?
        root = path.to_s.split("/", 2).first
        anchor = resolve("#{root}/x")
        return Search::Result.new(matches: [], truncated: false, refusal: anchor.refusal) unless anchor.resolved?
      end

      Search.call(documents: documents(path: path), pattern: pattern, path_prefix: prefix(path),
        ignore_case: ignore_case, limit: limit,
        paths: ->(document) { paths(document.conversation_id, document.workspace_id, document.user_id, document.name, speaker_id: document.speaker_id, path: path) })
    end

    def projection
      { bindings: bindings.map do |binding|
        anchor = if binding.scope == :speaker
          { agent_public_id: binding.row.public_id, speaker_public_id: binding.speaker.public_id }
        else
          { "#{binding.scope}_public_id".to_sym => binding.row.public_id }
        end
        { name: binding.name, scope: binding.scope.to_s, access: binding.access.to_s, **anchor }
      end }
    end

    # Shared anchors can point in either direction between two conversations.
    # Order those rows by id so opposite writes cannot form a lock cycle.
    # Memory changes no parent key: NO KEY UPDATE keeps writers and deletes
    # serialized while admitting a fork's parent-FK KEY SHARE locks.
    def with_locks(anchor)
      MemoryDocument.transaction do
        rows = [anchor.lockable, @conversation].compact.uniq
        rows.sort_by { |row| [row == anchor.user ? 0 : row == anchor.workspace ? 1 : 2, row.id] }
          .each { |row| row.lock!("FOR NO KEY UPDATE") }
        yield
      end
    end

    private

      def conversation_writable?(conversation)
        (@execution || !conversation.archived?) && conversation.writable_by?(@principal)
      end

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
