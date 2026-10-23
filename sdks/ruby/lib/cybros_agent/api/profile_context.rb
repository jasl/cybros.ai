module CybrosAgent
  module Api
    # The authenticated member's self view and own resources. An Agent's
    # configuration supplies defaults when an input omits agent_configuration.
    # Kernel tool bytes come from `client.tools`, never composed here.
    class ProfileContext
      include Parsing

      PATH = "/agent_api/v1/profile".freeze
      CONFIGURATION_PATH = "#{PATH}/configuration".freeze
      STORE_ENTRIES_PATH = "#{PATH}/store_entries".freeze
      PROMPT_DOCUMENTS_PATH = "#{PATH}/prompt_documents".freeze
      AGENTS_PATH = "#{PATH}/agents".freeze

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      # No delivery address here: the member plane never answers with the
      # caller's own; ExecutorClient#describe names it.
      # A stable bridge identity resolves without renaming or transferring its controller.
      def register_ingress_speaker(channel_key:, external_id:, display_name:)
        body = { "ingress_speaker" => { "channel_key" => channel_key, "external_id" => external_id,
                                    "display_name" => display_name } }
        shape(IngressSpeaker, @dispatch.call("#{PATH}/ingress_speakers", method: :post, body: body, success: [200, 201]), "ingress_speaker")
      end

      def fetch = shape(Profile, @dispatch.call(PATH))

      def budgets
        Platform::BudgetReads.new(dispatch: @dispatch, path: "#{PATH}/budgets")
      end

      # Whole replacement — a merged tool SET is a different cached prefix, a merged RULE LIST
      # a different policy — so a field left nil clears, and every column is named in the
      # signature: `approval_rules` is required (nil = no rules) because an omission that
      # silently cleared the policy would silently select how tools gain permission to run. A
      # word the kernel does not read yet is refused typed (`InvalidRequest` carrying the
      # code); a malformed rule is `validation_failed` naming it — the kernel is the one
      # evaluator, this SDK never pre-parses. `default_model`: the profile's own model as
      # `provider/model`, nil to declare none; a ref the account may not run is
      # `validation_failed` naming the field with the resolver's word. `fallback_models`
      # declares an ordered recovery list independently of the default; [] disables switching.
      # The execution captures this list with its model/provider selection constraints.
      # `prompt_documents` replaces the Profile's own slots in this same transaction:
      # {"system_prompt" => {"content" => text, "role" => "developer"},
      #  "summarizer" => {"content" => text}}. A missing/null slot clears it.
      # `kernel_tools` names exact canonical tools; `runner_executor_public_ids` preserves
      # the application's candidate order. `runner_tool_names`: nil imports all model tools
      # from the selected Runner, [] imports none. Empty source lists enable no source.
      # `memory_context_limit` caps future execution's named memory bindings;
      # nil applies no profile cap, an empty bindings list disables memory.
      # `conversation_reach`: `subtree` narrows conversation tools to the
      # execution's conversation and descendants; nil restores workspace reach.
      # A `delegation_catalog` entry may name `inherited_tool_names`: exact
      # callable names to copy from the direct parent's captured tool set.
      # Missing names are ignored; an absent or empty list inherits none.
      def declare_configuration(tool_definitions:, approval_mode:, approval_rules:, prompt_mechanism:,
                                compaction_policy:, prompt_template: nil, default_model: nil, image_model: nil, lifecycle_hooks: nil,
                                fallback_models: [], prompt_documents: nil, kernel_tools: [],
                                runner_executor_public_ids: [], runner_tool_names: nil, mcp_tools: [],
                                memory_context_limit: nil, conversation_reach: nil, delegation_catalog: nil)
        body = {
          "configuration" => {
            "tool_definitions" => tool_definitions,
            "kernel_tools" => kernel_tools,
            "runner_executor_public_ids" => runner_executor_public_ids,
            "runner_tool_names" => runner_tool_names,
            "mcp_tools" => mcp_tools,
            "approval_mode" => approval_mode,
            "approval_rules" => approval_rules,
            "prompt_mechanism" => prompt_mechanism,
            "prompt_template" => prompt_template,
            "compaction_policy" => compaction_policy,
            "default_model" => default_model,
            "image_model" => image_model,
            "lifecycle_hooks" => lifecycle_hooks,
            "fallback_models" => fallback_models,
            "memory_context_limit" => memory_context_limit,
            "conversation_reach" => conversation_reach,
            "delegation_catalog" => delegation_catalog,
          },
          "prompt_documents" => prompt_documents,
        }
        shape(Profile, @dispatch.call(CONFIGURATION_PATH, method: :put, body: body))
      end

      def memory_collections = OwnedMemoryCollectionsContext.new(dispatch: @dispatch, path: "#{PATH}/memory_collections")

      # THE PRINCIPAL'S OWN STORE: the ACTING user's row — an
      # agent's entries are the agent's, not its steward's; the steward's
      # are the steward's. No receipt is kept at this door: a retried
      # create is `Conflict key_taken`, never a replay.
      def store_entries = StoreEntriesContext.new(dispatch: @dispatch, path: STORE_ENTRIES_PATH)

      # THE ACTING USER'S OWN PROMPT SLOT: an agent
      # profile's `system_prompt` — its own row, never its steward's; rho
      # reads or independently edits that slot here — or a
      # Human's `persona`, compiled into every turn that person posts. The
      # workspace's `character` has its own door; the other slots are
      # refused here by name (`prompt_slot_unavailable`).
      def prompt_documents = PromptDocumentsContext.new(dispatch: @dispatch, path: PROMPT_DOCUMENTS_PATH)

      # The caller's named Agent identities, declared under
      # `<its identifier>/<name>` — listed,
      # declared whole and removed by name; a sibling's published row
      # rides the listing read-only.
      def agents = AgentsContext.new(dispatch: @dispatch, path: AGENTS_PATH)

      SHAPES = {
        IngressSpeaker => {
          public_id: :string, kind: :string, channel_key: :string, external_id: :string, display_name: :string,
        },
        Profile => {
          member: [:shape, Member],
          credential: [:shape, Credential],
          # Absent on a human's profile; on an agent's, every field is nil
          # (the list empty) until the profile declares.
          configuration: [:optional_shape, AgentConfiguration],
          measured_at: :string,
        },
        Member => {
          public_id: :string, handle: :string, kind: :string, role: :string, display_name: :optional_string,
          agent_identifier: :optional_string,
        },
        Credential => { plane: :string, expires_at: :optional_string },
        AgentConfiguration => {
          tool_definitions: :json_array,
          kernel_tools: :string_list,
          runner_executor_public_ids: :string_list,
          runner_tool_names: :optional_string_list,
          mcp_tools: :json_array,
          approval_mode: :optional_string,
          # Nil when the profile authored none (an empty list reads back
          # nil: an empty set is none), a frozen snapshot otherwise.
          approval_rules: :json,
          prompt_mechanism: :optional_string,
          # The assembly template: the block list the profile
          # compiles under `assembly`, a frozen snapshot; nil when none.
          prompt_template: :json,
          compaction_policy: :json,
          default_model: :optional_string,
          image_model: :optional_string,
          lifecycle_hooks: :json,
          fallback_models: :string_list,
          memory_context_limit: :optional_json_object,
          conversation_reach: :optional_string,
          delegation_catalog: :optional_json_array,
        },
      }.freeze
    end
  end
end
