# A NAMED DEFINITION'S OWN MEMORY (`agent/…`), managed by its declarer: the
# paired program that minted the row under `<its identifier>/<name>` reads
# and writes the notes that row carries into every conversation it answers.
# The one rung at this door is the named row's `agent/`; a path of another
# scope is `memory_scope_unavailable`, as at every one-scope door. Not a
# workspace's door, so no provider override reaches it and no
# `context_revision` moves: the next turn the named row answers reads the
# rows live. A Human is `not_agent`, a name the caller did not mint
# `not_found` — the definitions door's own rules.
class AgentAPI::V1::Profiles::Agents::MemoryController < AgentAPI::V1::Profiles::MemoryController
  include AgentAPI::V1::Profiles::NamedDefinitions

  before_action :require_agent
  before_action :find_definition

  private

    def find_definition
      @definition = own_definitions.find_by(agent_identifier: composed_identifier(params[:agent_name]))
      render_refusal(:not_found) if @definition.nil?
    end

    def agent = @definition

    def bindings = [{ "name" => "agent", "scope" => "agent", "access" => "read_write" }]
end
