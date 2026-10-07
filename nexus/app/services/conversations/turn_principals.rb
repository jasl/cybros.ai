module Conversations
  # WHO A TURN IS BETWEEN: its AUTHOR — the poster, whose `user/` memory
  # rung and `persona` the assembly renders — and its ANSWERER — the
  # addressee, whose standing declaration (`declaring_profile`), prompt
  # mechanism and template the compile runs under, and against whom
  # history's speakers are enveloped. ONE rule for the input row the drain
  # compiles (`ConversationInput`) and for the estimate that models that
  # send (`ContextEstimate`), so the two cannot drift: the preview
  # compiles under the addressee the door would resolve, and the author is
  # the caller.
  module TurnPrincipals
    class << self
      # THE ADDRESSEE: the named profile through the one resolver —
      # `@handle` or a public id within the account, the system user never
      # — refused by name (`principal_unknown`) or as ineligible
      # (`answerer_not_eligible`: a Human, `read` on the row, a fenced
      # profile all read the same). The kernel's own mail skips the
      # eligibility. Unnamed: `default`, else the host's answerer.
      def resolve(host:, author:, address:, default: nil, kernel: false)
        return Outcome.accepted(ConversationTurn::Principals.new(author: author, answerer: default || host.answering_user)) if address.blank?

        user = User.members.addressed_by(host.account_id, address).first
        return Outcome.refused(:principal_unknown) if user.nil?
        return Outcome.refused(:answerer_not_eligible) unless kernel || host.answerer_eligible?(user)

        Outcome.accepted(ConversationTurn::Principals.new(author: author, answerer: user))
      end
    end
  end
end
