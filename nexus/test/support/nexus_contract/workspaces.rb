module Nexus
  module Contract
    class << self
      private

        def workspaces
          basic, full = workspace_presenter_fixtures
          list_fixture = {
            "workspaces" => [basic],
            "pagination" => { "next_after" => nil },
          }

          {
            "states" => Workspace.states.keys.sort,
            "access_modes" => Workspace.access_modes.keys.sort,
            "visibility" => {
              "live" => Workspace::LIVE_STATES,
              "browsable" => Workspace::BROWSABLE_STATES,
              "tombstoned" => Workspace::TOMBSTONED_STATES,
            },
            "list_envelope" => list_fixture.keys,
            "singular_envelope" => %w[workspace],
            "pagination" => list_fixture.fetch("pagination").keys,
            "basic_projection" => basic.keys,
            "full_projection_adds" => full.keys - basic.keys,
            "list_filters" => %w[state dedicated_to_current_agent order after limit],
            "list_directions" => AgentAPI::KeysetPagination::DIRECTIONS.keys,
            "error_codes" => WORKSPACE_ERROR_STATUSES.keys,
            "error_statuses" => WORKSPACE_ERROR_STATUSES,
            "valid_fixture" => { "workspace" => basic },
            "valid_full_fixture" => { "workspace" => full },
            "valid_list_fixture" => list_fixture,
            "valid_create_request" => {
              "workspace" => {
                "name" => "Example",
                "access_mode" => "private",
                "metadata" => { "purpose" => "fixture" },
              },
            },
            "valid_update_request" => {
              "workspace" => {
                "name" => "Renamed",
                "metadata" => { "purpose" => "updated fixture" },
                "lock_version" => 0,
              },
            },
            "valid_access_mode_request" => {
              "access_mode" => { "access_mode" => "account_wide", "lock_version" => 0 },
            },
            "valid_tool_provider_overrides_request" => {
              "tool_provider_overrides" => {
                "overrides" => { "nexus.memory" => "01900000-0000-7000-8000-000000000030" },
                "lock_version" => 0,
              },
            },
            "overridable_namespaces" => Nexus::ToolRegistry.overridable_namespaces,
            "valid_state_filter_request" => { "state" => "archived" },
            # THE DIRECTION (KeysetPagination): the cursor carries it, so a
            # page continued the other way is refused rather than walked back.
            "valid_order_request" => { "order" => AgentAPI::KeysetPagination::DIRECTIONS.keys.last },
            "unknown_order_request" => { "order" => UNKNOWN_VALUE_FIXTURE },
            "valid_transfer_request" => {
              "ownership_transfer" => {
                "target_user_public_id" => "01900000-0000-7000-8000-000000000004",
                "lock_version" => 0,
              },
            },
            "valid_lifecycle_request" => { "command" => { "lock_version" => 0 } },
            "valid_delete_params" => { "lock_version" => 0 },
            # THE PRINCIPALS LISTING: every member with access to the workspace, of either kind;
            # every key present on every row — a Human's agent fields are null, never absent.
            "principals_envelope" => %w[principals],
            "principal_projection" => principals_fixture.fetch("principals").first.keys,
            "valid_principals_fixture" => principals_fixture,
            "valid_error_fixture" =>
              api_error_fixture("transition_in_progress", WORKSPACE_ERROR_STATUSES.fetch("transition_in_progress")),
            "unknown_state_fixture" => UNKNOWN_VALUE_FIXTURE,
            "unknown_state_filter_request" => { "state" => UNKNOWN_VALUE_FIXTURE },
            "unknown_state_response_fixture" => basic.merge("state" => UNKNOWN_VALUE_FIXTURE),
            "unknown_access_mode_fixture" => full.merge("access_mode" => UNKNOWN_VALUE_FIXTURE),
            "unknown_access_mode_request" => {
              "access_mode" => { "access_mode" => UNKNOWN_VALUE_FIXTURE, "lock_version" => 0 },
            },
            "unknown_creator_kind_fixture" => full.merge(
              "creator" => full.fetch("creator").merge("kind" => UNKNOWN_VALUE_FIXTURE)
            ),
            "terminal_state_fixture" => basic.merge("state" => "deleted"),
            "unknown_error_fixture" => unknown_api_error_fixture,
            "unknown_value_behavior" => "carry_unknown_response",
            "unknown_field_behavior" => "ignore",
          }
        end

        # One pack for the three doors: the hosts are a closed vocabulary a consumer can pin, and
        # the cap is per host.
        def store_entries
          basic, full = store_entry_presenter_fixtures
          list_fixture = {
            "store_entries" => [basic],
            "pagination" => { "next_after" => nil },
          }

          {
            "hosts" => %w[workspace conversation profile],
            "max_entries_per_host" => StoreEntry::MAX_ENTRIES_PER_HOST,
            "namespace_max_length" => StoreEntry::NAMESPACE_MAX_LENGTH,
            "key_max_length" => StoreEntry::KEY_MAX_LENGTH,
            "list_envelope" => list_fixture.keys,
            "singular_envelope" => %w[store_entry],
            "basic_projection" => basic.keys,
            "full_projection_adds" => full.keys - basic.keys,
            "error_codes" => STORE_ENTRY_ERROR_STATUSES.keys,
            "error_statuses" => STORE_ENTRY_ERROR_STATUSES,
            "valid_fixture" => { "store_entry" => full },
            "valid_basic_fixture" => { "store_entry" => basic },
            "valid_list_fixture" => list_fixture,
            "valid_create_request" => {
              "store_entry" => {
                "namespace" => "notes",
                "key" => "pinned",
                "value" => nil,
              },
            },
            "valid_update_request" => {
              "store_entry" => { "value" => { "pinned" => true }, "lock_version" => 0 },
            },
            "valid_delete_params" => { "lock_version" => 0 },
            "valid_delete_fixture" => { "status" => 204, "body" => nil },
            "valid_error_fixture" =>
              api_error_fixture("key_taken", STORE_ENTRY_ERROR_STATUSES.fetch("key_taken")),
            "unknown_error_fixture" => unknown_api_error_fixture,
            "unknown_field_behavior" => "ignore",
          }
        end

        # Rendered through the REAL presenter with duck-typed stand-ins: a
        # Human and the agent it stewards.
        def principals_fixture
          principal_type = Data.define(:public_id, :handle, :kind, :display_name, :agent_identifier, :steward)
          steward = principal_type.new(
            public_id: "01900000-0000-7000-8000-000000000003", handle: "fixture-owner", kind: "human",
            display_name: "Fixture owner", agent_identifier: nil, steward: nil
          )
          agent = principal_type.new(
            public_id: "01900000-0000-7000-8000-000000000005", handle: "lark", kind: "agent",
            display_name: "Fixture agent", agent_identifier: "fixture-agent", steward: steward
          )
          { "principals" => [steward, agent].map { |row| stringify_keys(AgentAPI::PrincipalPresenter.basic(row)) } }
        end

        def workspace_presenter_fixtures
          person_type = Data.define(:public_id, :display_name, :kind)
          workspace_type = Data.define(
            :public_id, :name, :access_mode, :state, :agent_identifier,
            :lock_version, :archived_at, :created_at, :updated_at, :metadata,
            :tool_provider_overrides, :owner, :creator
          )
          owner = person_type.new(
            public_id: "01900000-0000-7000-8000-000000000003",
            display_name: "Fixture owner",
            kind: "human"
          )
          creator = person_type.new(
            public_id: owner.public_id,
            display_name: owner.display_name,
            kind: "human"
          )
          workspace = workspace_type.new(
            public_id: "01900000-0000-7000-8000-000000000001",
            name: "Example",
            access_mode: "private",
            state: "active",
            agent_identifier: nil,
            lock_version: 0,
            archived_at: nil,
            created_at: Time.utc(2026, 7, 30),
            updated_at: Time.utc(2026, 7, 30),
            metadata: { "purpose" => "fixture" },
            tool_provider_overrides: {},
            owner: owner,
            creator: creator
          )

          [
            stringify_keys(AgentAPI::WorkspacePresenter.basic(workspace)),
            stringify_keys(AgentAPI::WorkspacePresenter.full(workspace)),
          ]
        end

        def store_entry_presenter_fixtures
          entry_type = Data.define(
            :public_id, :namespace, :key, :lock_version, :value, :created_at, :updated_at
          )
          entry = entry_type.new(
            public_id: "01900000-0000-7000-8000-000000000002",
            namespace: "notes",
            key: "pinned",
            lock_version: 0,
            value: nil,
            created_at: Time.utc(2026, 7, 30),
            updated_at: Time.utc(2026, 7, 30)
          )

          [
            stringify_keys(AgentAPI::StoreEntryPresenter.basic(entry)),
            stringify_keys(AgentAPI::StoreEntryPresenter.full(entry)),
          ]
        end
    end
  end
end
