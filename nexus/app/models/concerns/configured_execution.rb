# A configuration capture belongs to the execution, while access, attribution
# and executor addressing continue to use its actual User principal.
module ConfiguredExecution
  extend ActiveSupport::Concern

  included do
    attribute :agent_configuration, AgentConfiguration.to_type
    validates :agent_configuration, store_model: true, allow_nil: true
    validates :agent_configuration_document, bounded_json: { bound: :snapshot_bound }, allow_nil: true
  end

  def execution_configuration = agent_configuration || execution_agent

  private

    def agent_configuration_document = agent_configuration&.as_json
end
