module CybrosAgent
  # The member plane: the Agent → Nexus direction. It carries the
  # member credential and reaches the resources that act as the Agent.
  # A runner never constructs this client — it holds no member credential and
  # is not a principal.
  class Client < Api::BaseClient
    # The credential's own row: the bootstrap read (`fetch`, no delivery address) and the declaration an Agent writes for itself.
    def profile
      Api::ProfileContext.new(dispatch: dispatch)
    end

    # The Workspace collection: list, receipt-idempotent create,
    # and the singular fetch.
    def workspaces
      Api::Workspaces.new(dispatch: dispatch)
    end

    # A pure scoping handle over one Workspace public id — management
    # commands and the nested store entries. No HTTP happens here.
    def workspace(public_id)
      Api::WorkspaceContext.new(dispatch: dispatch, public_id: public_id)
    end

    # Staging binary input. It hangs off the client rather than a Workspace
    # because an upload belongs to the credential's own (Account, creator)
    # pair — it becomes a Workspace's business only when a InferenceRequest there names
    # it.
    def uploads
      Api::UploadsContext.new(dispatch: dispatch)
    end

    # THE KERNEL TOOL CATALOG — the exact bytes a task must send to turn a
    # kernel tool on. A client CANNOT paraphrase one: a declaration that
    # is not byte-identical to the registry's is refused
    # `kernel_tool_redefined`, because the tools block is the front of
    # every cached prefix. So the bytes are fetched, never composed here;
    # an SDK that carried its own copy would be a second and staler
    # authority, and would go wrong the round the kernel reworded a
    # description.
    #
    # It hangs off the client rather than a Workspace because the catalog
    # is the kernel's, not a workspace's.
    def tools
      Api::ToolCatalog.new(dispatch: dispatch)
    end

    # WHICH MODELS THIS ACCOUNT CAN RUN. Also the kernel's own
    # configuration rather than a workspace's — and also not a constant
    # this gem could carry: which models a deployment serves is an
    # operator's file, and whether one runs for you is your account's
    # lanes and credentials.
    def models
      Api::ModelCatalog.new(dispatch: dispatch)
    end

    # THE LANES BEHIND THEM: enabled, credentialed, or neither. A model
    # runs only when both are true, and the two are set separately.
    def model_providers
      Api::ModelProviders.new(dispatch: dispatch)
    end

    # AUTHORIZED DISCOVERY: the executors this credential may
    # address — a runner to bind at create or through `set_default_runner`, a
    # provider whose pool serves it — with what each announced. Account-
    # level for the reason the two catalogs are: which machines exist is
    # not a workspace's fact. Filtered by eligibility on the server, never
    # by presence, which is shown and never a reason to choose.
    def executors
      Api::Executors.new(dispatch: dispatch)
    end
  end
end
