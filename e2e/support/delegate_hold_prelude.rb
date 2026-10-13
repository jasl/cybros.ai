# Loaded through RUBYOPT into the rho the delegate-compaction journey KILLS: the shipped summarizer
# handler is replaced by one that NEVER ANSWERS — it holds the claim, checking the runner's cancel
# at every tick, until the process dies. That is the only shape that yields a claimed, unanswered
# delegate: a live rho's clamp answers every handler at the park's deadline, and killing
# rho between claim and commit on the mock is a sub-second race. With rho dead the operator
# backdates the park, the sweep settles the row `timed_out` by its replayable profile, and the
# kernel appends its own summarizer once — the fallback under test.
#
# A test double of a product handler and nothing else: the extension still
# registers, announces `summarize_history` with its profile and timeout, and
# the declaration under the settings flag still names it. The constant is
# the product's own — a rename breaks this journey loudly at boot.
begin
  require "rho"
rescue LoadError
  # The `bundle` launcher itself runs first, before bundler/setup put rho on
  # the load path; only the product process past it has a handler to park.
else
  Rho::Extensions::Compaction::SummarizeHistory.prepend(Module.new do
    def call(_args)
      loop do
        Rho::Runner::ExecutionContext.current&.raise_if_cancelled!
        sleep 0.05
      end
    end
  end)
end
