module MemoryDocuments
  # Source authority is independent of kernel content state. Provider stamps
  # use the former; documents and Skills additionally require a live collection.
  class Context
    Binding = Data.define(:selection, :scope, :access, :row, :speaker, :collection) do
      def name = selection.name
      def anchor(document_name)
        Scopes::Anchor::Result.new(collection: collection, scope: scope.to_s, name: document_name, refusal: nil)
      end
    end

    def self.inherit_from(run)
      new(workspace: run.workspace, conversation: run.conversation, principal: run.creating_user,
        configuration: run.memory_context, agent: run.execution_agent, execution: true).inheritable_configuration
    end

    def initialize(workspace:, conversation:, principal:, configuration:, agent:, execution: false)
      @workspace, @conversation, @principal, @agent, @execution = workspace, conversation, principal, agent, execution
      @configuration = configuration.nil? ? MemoryContext::DEFAULT : MemoryContext.from_h(configuration)
    end

    # Only the accepting write path calls this, outside Conversation/Run locks.
    # A deleted default still occupies its unique identity and is never replaced.
    def prepare_defaults
      unprepared_defaults.each do |binding|
        binding.row.with_lock("FOR NO KEY UPDATE") do
          MemoryCollection.default_for(binding.row, speaker: binding.speaker) if binding.row.active?
        end
      end
      @sources = nil
    end

    def defaults_missing? = unprepared_defaults.any?

    def capture
      MemoryContext.new(automatic: @configuration.automatic, bindings: sources.map do |binding|
        entry = binding.selection
        next entry if entry.capture

        entry.with(capture: MemoryContext::Capture.new(collection_public_id: binding.collection&.public_id,
          owner_public_id: binding.row.public_id, scope: binding.scope, speaker_public_id: binding.speaker&.public_id))
      end).to_h
    end

    # Delegation rebinds relative roles, but cannot revive a source the sender
    # can no longer use. A provider scope remains usable after kernel deletion.
    def inheritable_configuration
      bindings = sources.filter_map do |binding|
        next if !(overridden? && binding.selection.collection_public_id.nil?) &&
          (binding.collection.nil? || binding.collection.deleted?)

        binding.selection.with(access: binding.access, capture: nil)
      end
      @configuration.with(bindings: bindings).to_h
    end

    def selection_refusal
      return :memory_collection_provider_unsupported if overridden? && exact?
      return nil if @configuration.automatic

      :memory_scope_unavailable unless @configuration.bindings.all? do |entry|
        next true if entry.scope == :speaker && entry.speaker_public_id.nil?
        next true if entry.scope == :conversation && entry.conversation_public_id.nil? && @conversation&.new_record?

        binding = sources.find { |candidate| candidate.name == entry.name }
        # A first-use Speaker default has no content yet. Its validated
        # owner/subject can be selected without making preview/config reads
        # allocate it; materialization prepares it before capture. A tombstone
        # is an existing identity, so it never takes this arm.
        unallocated_speaker = binding && entry.scope == :speaker && entry.capture.nil? && binding.collection.nil?
        binding && (overridden? || unallocated_speaker || (binding.collection && !binding.collection.deleted?)) &&
          (entry.access == :read || binding.access == :read_write)
      end
    end

    def resolve(path, authoring: false)
      root, name = Scopes::Anchor.split(path)
      return Scopes::Anchor.refused(:memory_path_invalid) if name.nil?

      binding = bindings.find { |entry| entry.name == root }
      return Scopes::Anchor.refused(:memory_scope_unavailable) unless binding
      return Scopes::Anchor.refused(:memory_read_only) if authoring && binding.access != :read_write

      binding.anchor(name)
    end

    def bindings
      sources.filter_map do |binding|
        collection = binding.collection
        next if collection.nil? || collection.deleted?

        binding.with(access: collection.archived? ? :read : binding.access)
      end
    end

    def tool_refusal(verb:, input:)
      return :memory_collection_provider_unsupported if overridden? && exact?

      entries = overridden? ? sources : bindings
      path = input["path"].to_s
      return nil if %w[nexus.memory.ls nexus.memory.grep].include?(verb) && path.empty?

      binding = entries.find { |entry| entry.name == path.split("/", 2).first }
      if binding.nil? then :memory_scope_unavailable
      elsif %w[nexus.memory.write nexus.memory.edit nexus.memory.delete].include?(verb) && binding.access != :read_write
        :memory_read_only
      end
    end

    def documents(path: nil)
      MemoryDocument.where(memory_collection_id: selected(path).map { |binding| binding.collection.id }.uniq)
    end

    def paths(collection_id, name, path: nil)
      selected(path).filter_map { |binding| "#{binding.name}/#{name}" if binding.collection.id == collection_id }
    end

    def listing(path: nil)
      Listing.call(documents: documents(path: path), path_prefix: prefix(path),
        paths: ->(collection_id, name) { paths(collection_id, name, path: path) })
    end

    def search(pattern:, path: nil, ignore_case: false, limit: nil)
      Search.call(documents: documents(path: path), pattern: pattern, path_prefix: prefix(path),
        ignore_case: ignore_case, limit: limit,
        paths: ->(document) { paths(document.memory_collection_id, document.name, path: path) })
    end

    def projection
      { bindings: sources.map do |binding|
        anchor = if binding.scope == :speaker
          { agent_public_id: binding.row.public_id, speaker_public_id: binding.speaker.public_id }
        else
          { "#{binding.scope}_public_id".to_sym => binding.row.public_id }
        end
        { name: binding.name, scope: binding.scope.to_s, access: binding.access.to_s, **anchor }
      end }
    end

    def management_projection
      { bindings: sources.map do |binding|
        collection = binding.collection
        state = if collection.nil? then "unallocated"
        elsif collection.deleted? then "deleted"
        elsif collection.archived? then "archived"
        else "active"
        end
        { name: binding.name, source: binding.selection.to_h.fetch("source"), scope: binding.scope.to_s,
          access: (collection&.archived? ? :read : binding.access).to_s, collection_public_id: collection&.public_id,
          owner_public_id: binding.row.public_id, speaker_public_id: binding.speaker&.public_id, state: state }
      end }
    end

    def with_locks(anchor)
      MemoryDocument.transaction do
        # Prefer the exact host object the writer revises when both names
        # identify one row; locking a second instance would leave it stale.
        rows = [@conversation, anchor.lockable].compact.uniq
        # Parent locks order opposite conversation aliases and serialize Fork.
        rows.sort_by { |row| [row == anchor.workspace ? 0 : row == anchor.user ? 1 : 2, row.id] }
          .each { |row| row.lock!("FOR NO KEY UPDATE") }
        # Collection state must be re-read under the same arbiter as Delete.
        anchor.collection.lock!
        yield
      end
    end

    private

      def unprepared_defaults
        sources.select do |binding|
          binding.scope == :speaker && binding.selection.capture.nil? &&
            binding.selection.collection_public_id.nil? && binding.collection.nil?
        end
      end

      def overridden? = @workspace.tool_provider_override_for("memory_read").present?
      def exact? = @configuration.bindings.any?(&:collection_public_id)

      def sources
        @sources ||= @configuration.bindings.filter_map do |entry|
          collection = if entry.capture
            MemoryCollection.find_by(account_id: @principal.account_id, public_id: entry.capture.collection_public_id)
          elsif entry.collection_public_id
            MemoryCollection.find_by(account_id: @principal.account_id, public_id: entry.collection_public_id)
          end
          scope = entry.capture&.scope || entry.scope || collection&.natural_scope
          next unless scope

          row, speaker = source_owner(entry, scope, collection)
          next unless row && authorized?(row, scope, speaker)
          next if MemoryContext::SCOPES.include?(entry.name.to_sym) &&
            (entry.name.to_sym != scope || (scope == :conversation && row != @conversation))

          unless entry.capture || entry.collection_public_id
            collection = row.memory_collections.find_by(is_default: true, speaker: speaker)
          end
          access = entry.access
          access = :read if scope == :conversation && !conversation_writable?(row)
          Binding.new(selection: entry, scope: scope, access: access, row: row, speaker: speaker, collection: collection)
        end
      end

      def source_owner(entry, scope, collection)
        if entry.collection_public_id
          [collection&.owner, collection&.speaker]
        elsif entry.capture
          model = { conversation: Conversation, workspace: Workspace, user: User, agent: User, speaker: User }.fetch(scope)
          row = model.find_by(account_id: @principal.account_id, public_id: entry.capture.owner_public_id)
          [row, subject(entry.capture.speaker_public_id)]
        else
          row = case scope
          when :conversation
            entry.conversation_public_id ? Conversation.find_by(account_id: @principal.account_id, public_id: entry.conversation_public_id) : @conversation
          when :workspace then @workspace
          when :user then (@principal if @principal.human?)
          when :agent, :speaker then @agent
          else raise ArgumentError, "unknown memory scope"
          end
          [row, subject(entry.speaker_public_id)]
        end
      end

      def subject(public_id)
        Speaker.find_by(account_id: @principal.account_id, public_id: public_id) if public_id
      end

      def authorized?(row, scope, speaker)
        return false unless @workspace.non_tombstoned? && @workspace.data_accessible_by?(@principal)

        case scope
        when :conversation then row.workspace_id == @workspace.id && !row.tombstoned? && row.visible_to?(@principal)
        when :workspace then row == @workspace
        when :user then row == @principal && row.human? && row.active?
        when :agent then row == @agent && row.active?
        when :speaker then row == @agent && row.active? && speaker.present?
        else raise ArgumentError, "unknown memory scope"
        end
      end

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
  end
end
