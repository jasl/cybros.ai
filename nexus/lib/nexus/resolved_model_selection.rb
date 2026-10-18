module Nexus
  # One accept-time in-memory resolution. The full profile and capability
  # view exist only long enough to validate the submitted request; persistence
  # extracts the Invocation's narrow semantic facts and discards this value.
  ResolvedModelSelection = Data.define(
    :submitted, :workload, :provider_id, :model_ref,
    :execution_profile, :capabilities, :generation_config, :reasoning
  ) do
    class << self
      def from_resolution(candidate_resolution)
        candidate = candidate_resolution.candidate
        new(
          submitted: candidate_resolution.submitted,
          workload: candidate.workload,
          provider_id: candidate.provider_id,
          model_ref: candidate.model_ref,
          execution_profile: candidate.execution_profile,
          capabilities: candidate.capabilities,
          generation_config: candidate_resolution.generation_config,
          reasoning: candidate_resolution.reasoning,
        )
      end
    end

    def request_options = generation_config.request_options


    private_class_method :new
  end
end
