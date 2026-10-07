module ModelProviders
  module CodexAuthorization
    # THE ONE RESULT the authorization steps answer (shared by all steps in
    # this namespace): a domain reason and whichever rows the step produced
    # — the session it moved, the task it claimed or settled, the
    # credential it installed, the prepared request a claim earned. Absent
    # fields are nil; each step's own predicate names the one outcome that
    # lets its caller continue.
    Result = Data.define(:outcome, :session, :task, :credential, :prepared) do
      def initialize(outcome:, session: nil, task: nil, credential: nil, prepared: nil) = super

      # AcceptSession: a session exists to advance.
      def accepted? = outcome == :accepted
      def refused? = !accepted?
      # Claim: an exchange may go out.
      def claimed? = outcome == :claimed
      # ApplyDeviceStart: the session moved to its next phase.
      def applied? = outcome == :applied
      # InstallCredential: a usable pair landed.
      def installed? = outcome == :installed
      # Advance: the step wrote something — a successor may follow.
      def advanced? = %i[applied installed expired retryable].include?(outcome)
    end
  end
end
