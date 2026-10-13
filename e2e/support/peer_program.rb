require "securerandom"
require_relative "ceremony"
require_relative "device_authorization_budget"

module E2E
  # A SECOND AGENT PROGRAM under the steward: a device-flow agent confirmed through the steward's
  # own browser session — one grant of the per-IP device budget — answering the member plane as that
  # program. It declares nothing: a speaker, never an engine. Lifted from the two lanes that paired
  # one inline (`rho_conversation`, `side_conversation`), so a lane that needs a peer pairs it in
  # one line and reads its member public id — the key every access carrier takes — off the profile
  # read, the way an agent learns its own id. `credential` is the member bearer, for a cable
  # endpoint opened as this program. `declare_configuration` is the one thing a lane may make it: an
  # ANSWERER with its own declaration — a template under `assembly`, a tool under `bypass` — through
  # the profile's door, whole.
  module PeerProgram
    Peer = Data.define(:client, :public_id, :agent_identifier, :credential) do
      def declare_configuration(tool_definitions: [], approval_mode: nil, approval_rules: nil,
                                prompt_mechanism: "default", prompt_template: nil, compaction_policy: nil,
                                prompt_documents: nil, runner_executor_public_ids: [], runner_tool_names: nil)
        client.profile.declare_configuration(
          tool_definitions: tool_definitions, approval_mode: approval_mode, approval_rules: approval_rules,
          prompt_mechanism: prompt_mechanism, prompt_template: prompt_template, compaction_policy: compaction_policy,
          prompt_documents: prompt_documents, runner_executor_public_ids: runner_executor_public_ids,
          runner_tool_names: runner_tool_names
        )
      end
    end

    module_function

    # `name` becomes the identifier's stem (`e2e-<name>-<hex>`) and the
    # display names the ceremony page shows.
    def pair(base_url:, actor:, name:)
      device = CybrosAgent::DeviceFlow::Client.new(base_url: base_url, sleeper: ->(_seconds) { sleep 0.2 })
      DeviceAuthorizationBudget.consume
      identifier = "e2e-#{name}-#{SecureRandom.hex(4)}"
      authorization = device.request_authorization(
        agent_identifier: identifier, agent_display_name: "E2E #{name}", executor_display_name: "E2E #{name} app"
      )
      Ceremony.confirm(actor: actor, status: nil, started: {
        "verification_uri_complete" => authorization.verification_uri_complete,
        "user_code" => authorization.user_code,
        "branch" => "agent",
      })
      credentials = device.await_credentials(authorization)
      client = CybrosAgent.planes_for(credentials, base_url: base_url).client
      Peer.new(client: client, public_id: client.profile.fetch.member.public_id, agent_identifier: identifier,
        credential: credentials.access_token)
    end
  end
end
