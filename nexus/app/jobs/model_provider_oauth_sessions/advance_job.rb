module ModelProviderOAuthSessions
  class AdvanceJob < ApplicationJob
    queue_as :default

    def perform(public_id)
      due = ModelProviders::CodexAuthorization::ContinueSession.call(public_id)
      self.class.set(wait_until: due).perform_later(public_id) if due
    end
  end
end
