module CybrosAgent
  module Api
    # A pure scoping handle over one Workspace public id:
    # constructing it performs no HTTP, and every command answers the Full
    # projection the server rendered after the commit. Owner policy stays
    # server-side — a non-owner invoking a management command receives the
    # honest Forbidden, never a client-side guess.
    class WorkspaceContext
      include WorkspaceProjections
      include Fields

      attr_reader :public_id

      def initialize(dispatch:, public_id:)
        @dispatch = dispatch
        @public_id = required_string_snapshot(public_id, "public_id")
      end

      # Rename and/or replace metadata under the required lock_version. The
      # at-least-one contract validates before transport: a lock_version-only
      # patch is the caller's bug, not a server 422.
      def update(name: UNSET, metadata: UNSET, lock_version:)
        body = fields(name:, metadata:)
        raise ArgumentError, "update requires name or metadata" if body.empty?

        body["lock_version"] = lock_version
        shape(Workspace, @dispatch.call(path, method: :patch, body: { "workspace" => body }), "workspace")
      end

      def update_access_mode(access_mode:, lock_version:)
        answer = @dispatch.call(
          "#{path}/access_mode",
          method: :put,
          body: { "access_mode" => { "access_mode" => access_mode, "lock_version" => lock_version } }
        )
        shape(Workspace, answer, "workspace")
      end

      # THE PROVIDER OVERRIDE OPT-IN: the workspace opts a kernel
      # family (`nexus.memory`) into a tools provider by naming the provider's
      # public id under the namespace. A WHOLE REPLACEMENT of the map under
      # the required lock_version — `{}` clears, and the key is always sent,
      # because the server reads an absent map as a missing parameter and
      # never as "clear". The server's three lock-free checks answer 422
      # `InvalidRequest` with `reserved_namespace` (a namespace a provider
      # can never serve), `provider_not_eligible` (not a live tools provider
      # of the account, or one some member of the workspace could not reach)
      # or `provider_incomplete` (it does not announce every live tool of the
      # namespace); a lost CAS is the ordinary `Conflict` `stale_object`. No
      # rho verb sets this — the SDK is its client.
      def set_tool_provider_overrides(overrides:, lock_version:)
        raise ArgumentError, "overrides must be a Hash" unless overrides.is_a?(Hash)

        answer = @dispatch.call(
          "#{path}/tool_provider_overrides",
          method: :put,
          body: { "tool_provider_overrides" => { "overrides" => overrides, "lock_version" => lock_version } }
        )
        shape(Workspace, answer, "workspace")
      end

      def transfer_ownership(target_user_public_id:, lock_version:)
        answer = @dispatch.call(
          "#{path}/ownership_transfer",
          method: :post,
          body: {
            "ownership_transfer" => {
              "target_user_public_id" => target_user_public_id, "lock_version" => lock_version,
            },
          }
        )
        shape(Workspace, answer, "workspace")
      end

      def archive(lock_version:)
        lifecycle_command("archival", lock_version)
      end

      def restore(lock_version:)
        lifecycle_command("restoration", lock_version)
      end

      # Deletion is an accepted lifecycle command, not a vanishing act: the
      # lock_version travels as a query parameter and the answer is the Full
      # projection carrying the transition state.
      def delete(lock_version:)
        shape(Workspace, @dispatch.call(path, method: :delete, params: { "lock_version" => lock_version }), "workspace")
      end

      def store_entries
        StoreEntriesContext.new(dispatch: @dispatch, path: "#{path}/store_entries")
      end

      # THE ROOM'S OWN MEMORY DOOR: the
      # `workspace/` scope without a conversation — the rows every
      # conversation of this workspace assembles from, written and read
      # here by anyone with write standing on the room. The same four
      # verbs as `chat.memory`; this door serves `workspace/` alone, and
      # refuses the other two scopes `memory_scope_unavailable`. While the
      # workspace's memory is overridden to a provider every plain verb
      # answers `Conflict` `memory_overridden` — a `skills/` path passes.
      def memory = MemoryContext.new(dispatch: @dispatch, path: "#{path}/memory")

      # THE PRINCIPALS LISTING: who may be named on a conversation's
      # access carrier — every member with access to this workspace, of
      # either kind, by display name. The one user listing the member plane
      # has: an agent reads its peers' ids here and its own steward's off
      # its own row. No page — the set is an account's members with access.
      def principals
        shapes(Principal, @dispatch.call("#{path}/principals"), "principals")
      end

      # THE ROOM'S CHARACTER: the workspace's one prompt slot,
      # compiled behind the agent's `system_prompt` and ahead of the
      # person's `persona` on every assembled turn. Write standing under
      # the dedication fence; a fenced agent reads and never writes.
      def prompt_documents
        PromptDocumentsContext.new(dispatch: @dispatch, path: "#{path}/prompt_documents")
      end

      # The model plane, from the Agent's side: one direct call, five
      # workloads, asynchronous by contract.
      def inference_requests
        InferenceRequestsContext.new(dispatch: @dispatch, workspace_public_id: @public_id)
      end

      # The multi-turn plane. The collection is here; ONE conversation's
      # own surface is `conversation(public_id)` below, reachable without
      # listing first because a caller that already holds an id has no
      # reason to.
      def conversations
        ConversationsContext.new(dispatch: @dispatch, workspace_public_id: @public_id)
      end

      def conversation(public_id)
        ConversationContext.new(
          dispatch: @dispatch, workspace_public_id: @public_id, public_id: public_id
        )
      end

      # THE AUTHOR HALF of the agent-run surface, and the person's and the
      # decider's task verbs below it. The executing half — the inbox, the
      # claim, the commit — is the EXECUTOR plane's (`ExecutorClient#inbox`); no member door hands out work.
      def runs
        RunsContext.new(
          dispatch: @dispatch, workspace_public_id: @public_id
        )
      end

      def run(public_id)
        RunContext.new(
          dispatch: @dispatch, workspace_public_id: @public_id,
          run_public_id: public_id
        )
      end

      def run_task(run_public_id:, task_key:)
        RunTasksContext.new(
          dispatch: @dispatch, workspace_public_id: @public_id,
          run_public_id: run_public_id, task_key: task_key
        )
      end

      private

        def path
          "#{Workspaces::PATH}/#{path_segment(@public_id, "public_id")}"
        end

        def lifecycle_command(action, lock_version)
          answer = @dispatch.call(
            "#{path}/#{action}",
            method: :post,
            body: { "command" => { "lock_version" => lock_version } }
          )
          shape(Workspace, answer, "workspace")
        end
    end
  end
end
