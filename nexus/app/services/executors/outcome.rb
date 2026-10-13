module Executors
  # The shared result of executor-plane verbs: a domain reason, the row or frame
  # the verb produced — a refusal may carry the row that explains it — and
  # the refusal's detail a person reads. Never an HTTP status; the
  # controllers map those.
  Outcome = Data.define(:outcome, :value, :detail) do
    class << self
      def accepted(value = nil) = new(outcome: :accepted, value: value, detail: nil)
      def refused(code, value = nil, detail: nil) = new(outcome: code, value: value, detail: detail)
    end

    def accepted? = outcome == :accepted
  end
end
