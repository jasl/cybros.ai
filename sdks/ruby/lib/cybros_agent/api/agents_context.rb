module CybrosAgent
  module Api
    # THE CALLER'S NAMED DEFINITIONS: the Agent Profiles this profile MINTS as its own
    # sub-agents — a member row each, addressed by `@handle` in `spawn` and
    # `send` like any peer, carrying its own configuration block and
    # `system_prompt`, and nothing a pairing mints: no credential, no
    # address. The identifier is composed by the kernel's door
    # (`<caller identifier>/<name>`), so a row is this caller's alone to
    # rewrite or remove; a sibling's PUBLISHED row (`scope: "steward"`)
    # rides the listing read-only.
    #
    # `declare` is a WHOLE replacement by name, idempotent: the same row
    # (handle, public id, identifier unchanged) on every later PUT — the
    # scope may flip (`instance` → `steward` publishes it), a removed row
    # of the name comes back as itself. `remove` is the kernel's reversible
    # status flip; the name is free to declare again.
    class AgentsContext
      include Parsing

      attr_reader :path

      def initialize(dispatch:, path:)
        @dispatch = dispatch
        @path = path
      end

      # The caller's own rows of both scopes plus the steward's other
      # published rows, by display name.
      def list = shapes(NamedAgent, @dispatch.call(path), "agents")

      # `configuration` carries the same fields as
      # `declare_configuration` takes them (the kernel's same writer and
      # refusals; `default_model` and `fallback_model` judged at
      # declaration); `system_prompt`
      # nil deletes the slot; `display_name` defaults to the name.
      def declare(name:, scope:, description:, configuration:, display_name: nil, system_prompt: nil)
        body = {
          "scope" => scope, "description" => description, "display_name" => display_name,
          "system_prompt" => system_prompt, "configuration" => configuration.transform_keys(&:to_s),
        }
        shape(NamedAgent, @dispatch.call(name_path(name), method: :put, body: body, success: [200, 201]), "agent")
      end

      def remove(name:)
        @dispatch.call(name_path(name), method: :delete, success: 204)
        nil
      end

      SHAPES = {
        NamedAgent => {
          scope: :string, name: :string, public_id: :string, handle: :string, display_name: :optional_string,
          description: :string, agent_identifier: :string, steward_public_id: :string, kind: :string,
          derived_from_public_id: :string,
          configuration: [:shape, AgentConfiguration],
        },
        AgentConfiguration => ProfileContext::SHAPES.fetch(AgentConfiguration),
      }.freeze

      private

        # The name is the URL's member segment, the handle grammar
        # (`[a-z0-9][a-z0-9_-]{1,31}`); the kernel answers outside it with
        # 404, so nothing is pre-judged here.
        def name_path(name)
          raise ArgumentError, "name must be a nonempty String" unless name.is_a?(String) && !name.empty?

          "#{path}/#{name}"
        end
    end
  end
end
