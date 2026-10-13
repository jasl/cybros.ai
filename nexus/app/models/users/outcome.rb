module Users
  # The one result a User verb answers: a domain reason and the row, never
  # an HTTP status. `detail` names what a refusal is about where the word
  # alone is not enough (the named definition door relays the prompt
  # door's macro); nil otherwise.
  Outcome = Data.define(:outcome, :user, :detail) do
    ACCEPTED = %i[declared replaced].freeze

    def initialize(outcome:, user:, detail: nil) = super

    def accepted? = ACCEPTED.include?(outcome)
  end
end
