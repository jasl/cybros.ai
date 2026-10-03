# Selection is a port, not a lookup: one call resolves or refuses typed,
# and nothing downstream re-asks the catalog. Callers inject the Resolver,
# so ambient process state can never select a model.
module ModelSelection
  Result = Data.define(:outcome, :selection, :refusal) do
    def self.resolved(selection) = new(outcome: :resolved, selection: selection, refusal: nil)
    def self.refused(refusal) = new(outcome: :refused, selection: nil, refusal: refusal)

    def resolved? = outcome == :resolved
  end

  # Resolver-private construction evidence. A selected candidate owns every
  # execution/capability fact; callers never assemble those mirrors one field
  # at a time on the final durable value.
  CandidateResolution = Data.define(
    :submitted, :candidate, :generation_config, :reasoning
  )

  # The fail-closed default keeps every alternate caller explicit too.
  class UnavailablePort
    # Account is accepted and ignored: refusing before any row is the whole
    # behavior, and a port that dropped the keyword would let a caller forget
    # to thread it and still compile.
    def resolve(account:, workload:, submitted:, configuration: {})
      Result.refused(:model_plane_unavailable)
    end
  end

  UNAVAILABLE_PORT = UnavailablePort.new

  # The port is chosen by the call, never by process state; `account:` is
  # a keyword because that is the smallest carrier that cannot be satisfied ambiently.
  def self.resolve(account:, workload:, submitted:, configuration: {}, port: UNAVAILABLE_PORT)
    port.resolve(
      account: account, workload: workload, submitted: submitted, configuration: configuration
    )
  end

  # A CATALOG REF AS A STANDING FACT: a profile's `default_model` and a
  # `spawn`/`send` call's named `model` are judged by the one accept-time
  # check the drain makes of a reply head — a complete `provider/model` under
  # the account's policies and credentials, on the reply workload, at the
  # model's own reasoning default. Nil when it resolves; else the resolver's
  # word (a selector or a bare word is `unknown_model`: the fact names one
  # model, never a policy).
  def self.ref_refusal(account:, ref:)
    return :unknown_model unless Nexus::ModelRef.parse(ref).complete?

    result = resolve(
      account: account, workload: "text_generation",
      submitted: Nexus::SubmittedModelSelection.new(model: ref.to_s, reasoning_effort: nil),
      port: Resolver.new
    )
    result.resolved? ? nil : result.refusal
  end
end
