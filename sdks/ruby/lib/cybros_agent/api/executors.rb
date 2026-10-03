module CybrosAgent
  module Api
    # THE EXECUTORS THIS PRINCIPAL MAY ADDRESS — a runner to bind
    # at create or through the handoff, a provider whose pool serves it —
    # with what each one announced.
    #
    # It hangs off the client rather than a Workspace for the same reason
    # the tool and model catalogs do: which machines exist is the account's
    # fact, not a workspace's. And it is not a list this gem could carry:
    # eligibility is the kernel's judgement over the machine's scope, its
    # credential readiness and the acting principal, which is why the
    # narrowing is asked of the server rather than done here.
    class Executors
      include ExecutorProjections
      # For the id helpers alone (`required_string`, `path_segment`) — the
      # ModelProviderContext precedent.
      include WorkspaceProjections

      PATH = "/agent_api/v1/executors".freeze

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      # `kind:` is `runner` or `tools_provider`; omitted, both machine kinds
      # list. An agent address is never listed — it binds nothing and is
      # nobody's to address — and asking for it is the server's 400.
      def list(kind: UNSET)
        params = UNSET.equal?(kind) ? nil : { "kind" => required_string(kind, "kind") }
        body = @dispatch.call(PATH, params: params)
        shapes(DiscoveredExecutor, body, "executors")
      end

      # One by its id. An ineligible or foreign id is ABSENCE (404), the
      # plane's rule: what this principal may not address, it cannot see.
      def show(public_id)
        body = @dispatch.call("#{PATH}/#{path_segment(public_id, "public_id")}")
        shape(DiscoveredExecutor, body, "executor")
      end
    end
  end
end
