module ModelProviderOAuthSessions
  # Recover the same precise continuation after a missing or busy wake. The
  # claim transaction still decides whether each queued step may send.
  class AdvanceDueJob < ApplicationJob
    queue_as :default

    def perform(limit: 25)
      ModelProviders::CodexAuthorization::Sweeps.due(limit: limit).each do |session|
        AdvanceJob.perform_later(session.public_id)
      end
    end
  end
end
