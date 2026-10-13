module TaskExecutors
  # The one result a TaskExecutor verb answers: a domain reason, the row and the
  # refusal's detail — never an HTTP status.
  Outcome = Data.define(:outcome, :executor, :detail) do
    def initialize(detail: nil, **) = super

    def accepted? = outcome == :announced
  end
end
