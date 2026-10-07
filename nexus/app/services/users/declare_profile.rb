module Users
  # Configuration and the Profile's own prompt documents form one declaration.
  # The User lock also orders single-slot edits; the configuration and both
  # replacement documents commit together.
  class DeclareProfile
    def self.call(...) = new(...).call

    def initialize(user:, configuration:, system_prompt: nil, summarizer: nil)
      @user = user
      @configuration = configuration
      @documents = { "system_prompt" => system_prompt, "summarizer" => summarizer }
    end

    def call
      return Outcome.new(outcome: :not_agent, user: @user) unless @user.agent_member?

      outcome = nil
      @user.with_lock do
        outcome = if @user.execution_principal_eligible?
          declare
        else
          Outcome.new(outcome: :not_authorized, user: @user)
        end
        raise ActiveRecord::Rollback unless outcome.accepted?
      end
      outcome
    end

    private

      def declare
        outcome = DeclareConfiguration.call(user: @user, **@configuration, replacing_prompt_documents: true)
        return outcome unless outcome.accepted?

        @documents.each do |slot, fields|
          if fields.nil?
            PromptDocuments::Delete.call(anchor: { user: @user }, slot: slot)
          else
            result = PromptDocuments::Write.call(anchor: { user: @user }, slot: slot, **fields)
            unless result.written?
              return Outcome.new(outcome: result.outcome, user: @user, detail: result.detail)
            end
          end
        end
        outcome
      end
  end
end
