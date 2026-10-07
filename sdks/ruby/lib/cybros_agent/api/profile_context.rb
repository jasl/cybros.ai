module CybrosAgent
  module Api
    # The member plane's own row: the bootstrap read, and for an Agent
    # Profile the standing declaration the kernel freezes onto every turn.
    # Kernel tool bytes come from `client.tools`, never composed here.
    class ProfileContext
      include Parsing

      PATH = "/agent_api/v1/profile".freeze
      CONFIGURATION_PATH = "#{PATH}/configuration".freeze
      MEMORY_PATH = "#{PATH}/memory".freeze
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

      # Whole replacement — a merged tool SET is a different cached prefix, a merged RULE LIST
      # a different policy — so a field left nil clears, and every column is named in the
      # signature: `approval_rules` is required (nil = no rules) because an omission that
      # silently cleared the policy would silently select how tools gain permission to run. A
      # word the kernel does not read yet is refused typed (`InvalidRequest` carrying the
      # code); a malformed rule is `validation_failed` naming it — the kernel is the one
      # evaluator, this SDK never pre-parses. `default_model`: the profile's own model as
      # `provider/model`, nil to declare none; a ref the account may not run is
      # `validation_failed` naming the field with the resolver's word. `fallback_model`: the
      # model a step this profile answers re-runs on ONCE when a provider's classifier declined
      # it (`finish_quality: refused`) — never for an unavailable model, an overload, an error
      # or a content block — judged the same way; nil declares none, and no step is re-run.
      # `prompt_documents` replaces the Profile's own slots in this same transaction:
      # {"system_prompt" => {"content" => text, "role" => "developer"},
      #  "summarizer" => {"content" => text}}. A missing/null slot clears it.
      # `kernel_tools` names exact canonical tools; `runner_executor_public_ids` preserves
      # the application's candidate order. `runner_tool_names`: nil imports all model tools
      # from the selected Runner, [] imports none. Empty source lists enable no source.
      def declare_configuration(tool_definitions:, approval_mode:, approval_rules:, prompt_mechanism:,
                                compaction_policy:, prompt_template: nil, default_model: nil, lifecycle_hooks: nil,
                                fallback_model: nil, prompt_documents: nil, kernel_tools: [],
                                runner_executor_public_ids: [], runner_tool_names: nil)
        body = {
          "configuration" => {
            "tool_definitions" => tool_definitions,
            "kernel_tools" => kernel_tools,
            "runner_executor_public_ids" => runner_executor_public_ids,
            "runner_tool_names" => runner_tool_names,
            "approval_mode" => approval_mode,
            "approval_rules" => approval_rules,
            "prompt_mechanism" => prompt_mechanism,
            "prompt_template" => prompt_template,
            "compaction_policy" => compaction_policy,
            "default_model" => default_model,
            "lifecycle_hooks" => lifecycle_hooks,
            "fallback_model" => fallback_model,
          },
          "prompt_documents" => prompt_documents,
        }
        shape(Profile, @dispatch.call(CONFIGURATION_PATH, method: :put, body: body))
      end

      # THE PERSON'S OWN MEMORY SCOPE: `user/…` documents anchored
      # on the caller's controlling Human — an agent's steward, a human
      # themself — readable from any workspace by that person and every
      # agent they steward. The same four verbs as `chat.memory`; this door
      # serves `user/` alone, and refuses the other two scopes.
      def memory = MemoryContext.new(dispatch: @dispatch, path: MEMORY_PATH)

      # THE PRINCIPAL'S OWN STORE: the ACTING user's row — an
      # agent's entries are the agent's, not its steward's; the steward's
      # are the steward's. Memory's `user/` above is the other rule (the
      # controlling Human's). No receipt is kept at this door: a retried
      # create is `Conflict key_taken`, never a replay.
      def store_entries = StoreEntriesContext.new(dispatch: @dispatch, path: STORE_ENTRIES_PATH)

      # THE ACTING USER'S OWN PROMPT SLOT: an agent
      # profile's `system_prompt` — its own row, never its steward's; rho
      # reads or independently edits that slot here — or a
      # Human's `persona`, compiled into every turn that person posts. The
      # workspace's `character` has its own door; the other slots are
      # refused here by name (`prompt_slot_unavailable`).
      def prompt_documents = PromptDocumentsContext.new(dispatch: @dispatch, path: PROMPT_DOCUMENTS_PATH)

      # THE CALLER'S NAMED DEFINITIONS: the sub-agents
      # this profile mints under `<its identifier>/<name>` — listed,
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
        },
        Credential => { plane: :string, expires_at: :optional_string },
        AgentConfiguration => {
          tool_definitions: :json_array,
          kernel_tools: :string_list,
          runner_executor_public_ids: :string_list,
          runner_tool_names: :optional_string_list,
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
          lifecycle_hooks: :json,
          fallback_model: :optional_string,
        },
      }.freeze
    end
  end
end
