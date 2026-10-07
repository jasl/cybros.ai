module CybrosAgent
  module Api
    IngressSpeaker = Data.define(:public_id, :kind, :channel_key, :external_id, :display_name)

    # Typed projections of the two bootstrap resources. Each block carries the
    # server's own `measured_at` where the wire supplies one: a composed read
    # is evidence about a moment, never a live handle.

    # `handle`: the member's NAME beside its id — what a
    # peer addresses (`@handle`) on an access carrier or a `to:`; the
    # kernel assigned an agent's, the steward may rename it.
    Member = Data.define(:public_id, :handle, :kind, :role, :display_name)
    Credential = Data.define(:plane, :expires_at)
    # An Agent's standing declaration, frozen onto each turn by the
    # kernel; `nil` on a human's profile, which declares nothing.
    # `kernel_tools` adds canonical tools; ordered `runner_executor_public_ids`
    # supplies candidates. `runner_tool_names` imports the selected Runner's model
    # tools: nil means all, [] means none. `approval_rules` is the rule list the
    # profile authors — opaque JSON here, the kernel's grammar — nil when
    # it authored none. `default_model` is
    # the profile's OWN model as a catalog ref `provider/model` — the
    # application's word, the first choice in the kernel's answer-engine ladder —
    # nil when it declared none. `fallback_model` is the model a
    # step the profile answers re-runs on once when a provider's classifier
    # declined it, nil when it declared none.
    AgentConfiguration = Data.define(
      :tool_definitions, :kernel_tools, :runner_executor_public_ids, :runner_tool_names,
      :approval_mode, :approval_rules, :prompt_mechanism, :prompt_template,
      :compaction_policy, :default_model, :lifecycle_hooks, :fallback_model
    )
    # The member plane's bootstrap read. It names no delivery address: a
    # profile has at most one current non-revoked address, and an accepted
    # connection's sibling transport credential names it on the executor plane.
    # A program learns that address from ExecutorDescription below.
    Profile = Data.define(:member, :credential, :configuration, :measured_at)

    # A NAMED DEFINITION as the profile's agents door lists it:
    # the principals row (`public_id`, `handle`,
    # `kind`, `display_name`, `agent_identifier`, `steward_public_id`) plus
    # `scope` (`instance` — its declarer's own, removed with it; `steward`
    # — published, persisting for every agent of the steward), `name`
    # (the definition's, the handle when free), `description` (the one
    # line a spawner chooses it by), `derived_from_public_id` (the paired
    # instance that declared it), and its `configuration` block whole.
    NamedAgent = Data.define(
      :scope, :name, :public_id, :handle, :display_name, :description, :agent_identifier,
      :steward_public_id, :kind, :derived_from_public_id, :configuration
    ) do
      def instance? = scope == "instance"
      def published? = scope == "steward"
    end

    # `presence` is the kernel's word for the live, pong-verified executor
    # socket — `online` | `offline` | `not_yet_seen` — beside the contact
    # sample and when the socket opened: display, never a gate.
    ExecutorAddress = Data.define(
      :public_id, :kind, :status, :display_name, :credential_epoch,
      :presence, :last_seen_at, :connected_at
    ) do
      def initialize(last_seen_at: nil, connected_at: nil, **members)
        super(last_seen_at: last_seen_at, connected_at: connected_at, **members)
      end
    end

    # The executor plane's self-description: which address this credential is.
    ExecutorDescription = Data.define(:executor, :measured_at)

    # A host's optional default for future Runner calls that omit a target.
    # Changing it never moves accepted tasks. Presence and the last contact
    # sample are display facts, independent of each task's frozen target.
    DefaultRunner = Data.define(:executor_public_id, :display_name, :presence, :last_seen_at) do
      def initialize(display_name: nil, last_seen_at: nil, **members)
        super(display_name: display_name, last_seen_at: last_seen_at, **members)
      end

      def online? = presence == "online"
      def to_h = super.compact
    end
  end
end
