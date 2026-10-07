module Scopes
  # ONE ANCHOR FOR THE THREE SCOPES. The scope is the path's first segment,
  # so a model hands a listed path back verbatim to any verb, and the
  # resolver answers two questions for every scope: which row to lock, which
  # rows to list. WHOSE User the `user/` rung means is the caller's decision,
  # never this resolver's: memory passes the controlling Human; the store
  # anchors on the ROUTE's host — the acting User's own row at
  # `profile/store_entries` — and shares this resolver's shape (exactly one
  # of three rungs, the anchor row locked first), not its grammar. A scope
  # whose row is absent — a standalone loop's `conversation/`, the profile
  # door's `workspace/`, a nil controlling Human's `user/` — is refused as
  # data the caller reads, never a failure.
  class Anchor
    Result = Data.define(:scope, :conversation, :workspace, :user, :name, :refusal) do
      def resolved? = refusal.nil?

      def documents
        return MemoryDocument.for_conversation(conversation.id) if conversation
        return MemoryDocument.for_workspace(workspace.id) if workspace

        MemoryDocument.for_user(user.id)
      end

      def attributes
        return { conversation: conversation } if conversation
        return { workspace: workspace } if workspace

        { user: user }
      end

      # The row every write serializes on — the fork's serialization point
      # too, which buys the cap count its consistency. In ladder order
      # (users and workspaces rank above conversations), this is the row
      # `Memory::Run#revising` and `Conversations::Memory::Apply#apply` lock
      # FIRST, before the conversation they then hold for the fence.
      def lockable = conversation || workspace || user
    end

    class << self
      def call(path:, workspace: nil, conversation: nil, user: nil)
        scope, name = split(path)
        return refused(:memory_path_invalid) if name.nil?
        return refused(:memory_path_invalid) unless MemoryDocument::SCOPES.include?(scope)

        row = { "conversation" => conversation, "workspace" => workspace, "user" => user }
          .fetch(scope)
        return refused(:memory_scope_unavailable) if row.nil?

        Result.new(scope: scope, name: name, refusal: nil,
          conversation: (row if scope == "conversation"),
          workspace: (row if scope == "workspace"),
          user: (row if scope == "user"))
      end

      # The scope prefix is required. A bare `notes.md` is refused rather
      # than defaulted: a default here decides where a model's notes live
      # by accident, and the three scopes differ in who can read them.
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
