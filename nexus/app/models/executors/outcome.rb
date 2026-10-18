module Executors
  # The shared result of executor verbs: a domain reason, the row or frame
  # the verb produced, and any refusal detail. Controllers map HTTP statuses.
  Outcome = Data.define(:outcome, :value, :detail) do
    class << self
      def accepted(value = nil) = new(outcome: :accepted, value: value, detail: nil)
      def refused(code, value = nil, detail: nil) = new(outcome: code, value: value, detail: detail)
    end

    def accepted? = outcome == :accepted
  end
end
