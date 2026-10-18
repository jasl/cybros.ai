module AgentAPI
  # One principal as the member plane lists it: the key a conversation's
  # access carrier and the `to`-addressing verbs take, the handle either
  # accepts in its place (`@handle`), the words a person reads, and — for
  # an agent — the identifier its program connected under and the Human
  # it answers to. Every key is present on every row: a Human's
  # `agent_identifier` and `steward_public_id` are null, never absent, so
  # a consumer reads the shape and not the kind.
  class PrincipalPresenter
    class << self
      def basic(user)
        {
          public_id: user.public_id,
          handle: user.handle,
          kind: user.kind,
          display_name: user.display_name,
          agent_identifier: user.agent_identifier,
          steward_public_id: user.steward&.public_id,
        }
      end
    end
  end
end
