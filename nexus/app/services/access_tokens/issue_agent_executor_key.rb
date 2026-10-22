module AccessTokens
  # Creating the first application address shares Consume's User lock. Extra
  # keys preserve its epoch, so revoking one never revokes the other keys.
  class IssueAgentExecutorKey
    def self.call(...) = new(...).call

    def initialize(agent:, name:, note: nil)
      @agent = agent
      @name = name
      @note = note
    end

    def call
      result = Result.not_issuable
      @agent.with_lock do
        if @agent.execution_principal_eligible? && !@agent.named_agent?
          executor = Executor.address_for(@agent) || @agent.executors.create!(
            account: @agent.account, executor_kind: :agent, display_name: @agent.display_name
          )
          # The INSERT references the already-held User and its address; the
          # Account has no operational exclusive lock. No second owner is locked.
          result = IssueAPIKey.call(user: @agent, executor: executor, name: @name, note: @note)
          raise ActiveRecord::Rollback unless result.outcome == :issued
        end
      end
      result
    end
  end
end
