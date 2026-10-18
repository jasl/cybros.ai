module Users
  # Configuration and the Agent's own prompt documents form one declaration.
  # The User lock also orders single-slot edits; the configuration and both
  # replacement documents commit together.
  class ConfigureAgent
    def self.call(...) = new(...).call
    def self.declare_locked(...) = new(...).declare_locked

    def initialize(user:, configuration:, system_prompt: nil, summarizer: nil)
      @user = user
      @configuration = configuration
      @documents = { "system_prompt" => system_prompt, "summarizer" => summarizer }
    end

    def call
      return Outcome.new(outcome: :not_agent, user: @user) unless @user.agent_member?

      outcome = nil
      @user.with_lock do
        outcome = if !@user.execution_principal_eligible?
          Outcome.new(outcome: :not_authorized, user: @user)
        else
          declare_locked
        end
        raise ActiveRecord::Rollback unless outcome.accepted?
      end
      outcome
    end

    # Named declarations already hold their declarer and existing definition
    # locks; a fresh definition is saved by the same configuration writer.
    def declare_locked
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
      # The successful response captures the documents before releasing the
      # same User lock; a later writer cannot mix its slots into this response.
      @user.prompt_documents.reset.load
      outcome
    end
  end
end
