module Scopes
  # Resolves a logical path into its document relation, write attributes and
  # serialization row. Speaker memory shares the Agent's User lock while its
  # relation and capacity are specific to that Agent and Speaker pair.
  # Callers choose the principals; the resolver never infers a Human owner.
  class Anchor
    WORDS = %w[conversation workspace user agent speaker].freeze

    Result = Data.define(:scope, :conversation, :workspace, :user, :speaker, :name, :refusal) do
      def initialize(speaker: nil, **) = super
      def resolved? = refusal.nil?

      def documents
        return MemoryDocument.for_conversation(conversation.id) if conversation
        return MemoryDocument.for_workspace(workspace.id) if workspace

        return MemoryDocument.for_speaker(user.id, speaker.id) if speaker

        MemoryDocument.for_user(user.id)
      end

      def attributes
        return { conversation: conversation } if conversation
        return { workspace: workspace } if workspace

        speaker ? { user: user, speaker: speaker } : { user: user }
      end

      # The row every write serializes on — the fork's serialization point
      # too, which buys the cap count its consistency. In ladder order
      # (users and workspaces rank above conversations), this is the row
      # `Memory::Run#revising` and `Conversations::Memory::Apply#apply` lock
      # FIRST, before the conversation they then hold for the fence.
      def lockable = conversation || workspace || user
    end

    class << self
      def call(path:, workspace: nil, conversation: nil, user: nil, agent: nil, speaker: nil)
        scope, name = split(path)
        return refused(:memory_path_invalid) if name.nil?
        return refused(:memory_path_invalid) unless WORDS.include?(scope)

        row = { "conversation" => conversation, "workspace" => workspace, "user" => user, "agent" => agent, "speaker" => (agent if speaker) }
          .fetch(scope)
        return refused(:memory_scope_unavailable) if row.nil?

        Result.new(scope: scope, name: name, refusal: nil,
          conversation: (row if scope == "conversation"),
          workspace: (row if scope == "workspace"),
          user: (row if %w[user agent speaker].include?(scope)),
          speaker: (speaker if scope == "speaker"))
      end

      # The scope prefix is required. A bare `notes.md` is refused rather
      # than defaulted: a default here decides where a model's notes live
      # by accident, and the scopes differ in who can read them.
      def split(path)
        text = String.try_convert(path).to_s
        scope, name = text.split("/", 2)
        return [nil, nil] if name.to_s.empty?

        [scope, name]
      end

      private

        def refused(code)
          Result.new(scope: nil, conversation: nil, workspace: nil, user: nil,
            name: nil, refusal: code)
        end
    end
  end
end
