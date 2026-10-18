module API
  class PrivateRunnerPresenter
    def self.basic(runner)
      {
        public_id: runner.public_id,
        display_name: runner.display_name,
        status: runner.status,
        registration_identifier: runner.registration_identifier,
        assignment_scope: runner.assignment_scope,
        assignment_agent_public_id: runner.assignment_agent.public_id,
      }
    end
  end
end
