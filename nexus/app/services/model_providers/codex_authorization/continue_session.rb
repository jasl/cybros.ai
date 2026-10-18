module ModelProviders
  module CodexAuthorization
    # Precise wakes shorten the device ceremony; the recurring due/sweep jobs
    # remain the recovery path after a missing wake or interrupted transport.
    module ContinueSession
      def self.call(public_id, now: Time.current)
        session = ModelProviderOAuthSession.nonterminal.find_by(public_id: public_id)
        return unless session

        result = Advance.call(session: session, now: now)
        if session.pending? && result.advanced?
          session.next_action_at
        end
      end
    end
  end
end
