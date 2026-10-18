module Users
  class AgentConfigurationSnapshot
    def self.read(scope:)
      # The caller scopes this to a unique User. LIMIT with a has-many eager load
      # makes Rails split the read; one joined statement keeps the declaration
      # and both owned prompt documents in the same unlocked database snapshot.
      user = scope.eager_load(:prompt_documents).to_a.first
      raise ActiveRecord::RecordNotFound if user.nil?

      user
    end
  end
end
