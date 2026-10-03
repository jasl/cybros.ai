require "uri"

module CybrosAgent
  module Api
    # The Workspace family's shared wire grammar: the typed maps of its
    # values over Parsing, and the argument guard every resource applies
    # before transport. metadata and value are opaque JSON — snapshotted
    # recursively and frozen so a value object can never be mutated into
    # disagreeing with what the server said.
    module WorkspaceProjections
      include Parsing

      WORKSPACE_SUMMARY = {
        public_id: :string, name: :string, access_mode: :string, state: :string, dedicated: :boolean,
        lock_version: :integer, archived_at: :optional_string, created_at: :string, updated_at: :string,
      }.freeze

      STORE_ENTRY_SUMMARY = {
        public_id: :string, namespace: :string, key: :string, lock_version: :integer,
        created_at: :string, updated_at: :string,
      }.freeze

      SHAPES = {
        WorkspaceSummary => WORKSPACE_SUMMARY,
        Workspace => WORKSPACE_SUMMARY.merge(
          metadata: :json_object,
          # Keys are namespaces; the map is frozen so no caller can retarget
          # a family after the read.
          tool_provider_overrides: lambda { |hash|
            fetch_hash(hash, "tool_provider_overrides").to_h do |namespace, entry|
              [json_snapshot(namespace), shape(ToolProviderOverride, hash_item(entry, "tool_provider_overrides"))]
            end.freeze
          },
          owner: [:shape, WorkspaceOwnerSummary],
          creator: [:shape, WorkspaceCreatorSummary]
        ),
        WorkspaceOwnerSummary => { public_id: :string, display_name: :optional_string },
        WorkspaceCreatorSummary => { public_id: :string, display_name: :optional_string, kind: :string },
        ToolProviderOverride => {
          provider_public_id: :string, display_name: :optional_string, assignment_scope: :optional_string,
        },
        StoreEntrySummary => STORE_ENTRY_SUMMARY,
        # The Full projection must actually carry `value`: a stored JSON
        # null arrives as a present-and-nil member, while an absent member
        # is a wrong shape rather than an entry that happens to hold nothing.
        StoreEntry => STORE_ENTRY_SUMMARY.merge(value: :nullable_json),
        # The principals listing, read strictly: every key is present
        # on every row — a Human's agent fields are null, never absent.
        Principal => {
          public_id: :string, handle: :string, kind: :string, display_name: :optional_string,
          agent_identifier: :optional_string, steward_public_id: :optional_string,
        },
      }.freeze

      private

        # Every caller-supplied id is percent-encoded into one opaque path
        # segment: URI metacharacters cannot re-address another route, and a
        # space never leaks the transport's raw URI error.
        def path_segment(value, name)
          URI.encode_uri_component(required_string(value, name))
        end

        def required_string(value, name)
          raise ArgumentError, "#{name} must be a nonempty String" unless value.is_a?(String) && !value.empty?

          value
        end

        # Contexts bind one resource for their entire lifetime. Copying before
        # freezing means neither the caller nor the context can retarget later
        # requests by mutating the original String object.
        def required_string_snapshot(value, name)
          required_string(value, name).dup.freeze
        end
    end
  end
end
