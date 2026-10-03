module Conversations
  # The one result a conversation-plane service answers: a domain reason,
  # the row(s) the verb produced, and — for `invalid` — the record carrying
  # its errors. Never an HTTP status; controllers map those.
  Outcome = Data.define(:outcome, :value, :record) do
    class << self
      def accepted(value = nil) = new(outcome: :accepted, value: value, record: nil)
      # A refusal may carry the row that explains it (`descendant_pinned`
      # names the pinning fork).
      def refused(code, value = nil) = new(outcome: code, value: value, record: nil)
      def invalid(record) = new(outcome: :invalid, value: nil, record: record)
    end

    def accepted? = outcome == :accepted
    def invalid? = outcome == :invalid
    # The invalid record's errors, under the name every plane's refusal
    # result answers (`Workspaces::Mutation::Result`, `StoreEntries::Authority::Result`).
    def errors = record&.errors
  end
end
