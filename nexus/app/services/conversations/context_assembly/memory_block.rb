module Conversations
  class ContextAssembly
    # A direct reply has no tools, so injection is memory's only reader.
    # It leads because it changes rarely and history every reply (a warm
    # prefix), and it fills a budget — what does not fit is named, never silently dropped.
    class MemoryBlock
      # About four thousand tokens, the order Codex's always-loaded summary
      # occupies. Bytes, because this runs before a model is resolved.
      DEFAULT_BUDGET_BYTES = 16.kilobytes
      HEADER = <<~TEXT.strip.freeze
        Durable memory for this conversation, its workspace and the person
        this turn answers to. It persists across replies and machines. You
        cannot edit it from here.
      TEXT
      # The same sentence where there is no conversation (a standalone
      # loop): the smallest edit of the measured header.
      STANDALONE_HEADER = <<~TEXT.strip.freeze
        Durable memory for this workspace and the person this work answers
        to. It persists across runs and machines. You cannot edit it from here.
      TEXT
      BOUND_HEADER = "Durable database memory through the selected logical paths. " \
        "It persists across replies and machines.".freeze
      OMITTED = "Not shown here (too large to include):".freeze

      Block = Data.define(:segments, :included, :omitted) do
        def self.empty = new(segments: [], included: 0, omitted: 0)
        def empty? = segments.empty?
      end

      class << self
        # `budget` is the caller's, so the estimate surface and the send
        # path can never disagree about what was included. `principal` is
        # the User whose turn this is: the `user/` rung rendered is ITS
        # controlling Human's, so a Human B posting into a conversation
        # A's agent created reads B's notes and none of A's — except on a
        # spawned child, whose rung is its answerer's
        # (`Conversation#memory_principal`). `conversation` is the
        # Conversation or a `Source` (a standalone loop's room: its
        # workspace rows and the principal's rung, no conversation rows).
        def call(conversation:, principal:, budget: DEFAULT_BUDGET_BYTES, memory_context: Source.of(conversation).conversation&.memory_context)
          source = Source.of(conversation)
          # SILENT under an override: the provider's memory is not the
          # kernel's to render, and rendering the kernel's beside it
          # would be two memories under one name; the rows stay, so
          # clearing the override restores this block. A `direct_reply`
          # under an override therefore has NO memory — the recorded
          # product line.
          if source.workspace.tool_provider_override_for("memory_read")
            return Block.new(segments: [], included: 0, omitted: 0)
          end

          context = MemoryDocuments::Context.new(workspace: source.workspace, conversation: source.conversation,
            principal: principal, configuration: memory_context)
          entries = readable(context)
          catalog = memory_context && context.bindings.any?
          return Block.empty if entries.empty? && !catalog

          chosen, omitted = fit(entries, budget)
          return Block.new(segments: [], included: 0, omitted: omitted.length) if chosen.empty? && !catalog

          header = if catalog
            roots = context.bindings.map { |binding| "#{binding.name}/ (#{binding.access == :read ? "read only" : "read and write"})" }
            "#{BOUND_HEADER}\nAvailable roots: #{roots.join(", ")}."
          else
            source.standalone? ? STANDALONE_HEADER : HEADER
          end
          Block.new(
            segments: [Segment.plain("user", render_text(chosen, omitted, header))],
            included: chosen.length, omitted: omitted.length
          )
        end

        private

          # Three scopes: the conversation's own rows (a fork's inherited
          # pointers are its own; none for a standalone source), its
          # workspace's, and the TURN's principal's `user/` — skipped when
          # the principal answers to no Human (the system user). Selected
          # without detoasting: `bytesize` is on the version row so choosing
          # does not pull 4 MiB of content. NEVER A `skills/` ROW: a skill
          # is loaded on demand through the `skill` tool and its catalog is
          # the pointer; injected whole into every reply's prefix it would
          # be the opposite of one.
          def readable(context)
            context.documents.not_skills.joins(:memory_document_version)
              .order(Arel.sql("memory_document_versions.created_at DESC"), :name, :id)
              .pluck(:id, :conversation_id, :workspace_id, :user_id, :name,
                "memory_document_versions.bytesize").flat_map do |id, conversation_id, workspace_id, user_id, name, bytes|
                context.paths(conversation_id, workspace_id, user_id, name).map { |path| [id, path, bytes] }
              end
          end

          # Newest first ACROSS the scopes under ONE budget, stopping at the
          # first miss, so the block is always a prefix of the newest
          # documents rather than a size-selected subset nobody could
          # predict; an oversized newest one is omitted like any other.
          def fit(entries, budget)
            spent = 0
            chosen = []
            omitted = []
            entries.each do |id, path, bytes|
              if omitted.empty? && spent + bytes <= budget
                spent += bytes
                chosen << [id, path]
              else
                omitted << path
              end
            end
            [chosen, omitted]
          end

          def render_text(chosen, omitted, header)
            contents = MemoryDocumentVersion
              .joins(:memory_documents)
              .where(memory_documents: { id: chosen.map(&:first) })
              .pluck("memory_documents.id", :content).to_h
            body = chosen.map do |id, path|
              "## #{path}\n#{contents[id]}"
            end
            body.unshift(header)
            body << "#{OMITTED} #{omitted.join(", ")}" if omitted.any?
            body.join("\n\n")
          end
      end
    end
  end
end
