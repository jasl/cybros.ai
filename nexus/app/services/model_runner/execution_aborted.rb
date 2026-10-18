module ModelRunner
  # The raise the host injects into an in-flight fiber; the transport owns
  # the idle bound. Neither kind writes a row: a cut parent's attempt is
  # the converger's, a shutdown survivor the sweep's — a started attempt may be billed.
  class ExecutionAborted < StandardError
    def self.cancel = new("execution aborted: parent invocation cut")
    def self.shutdown = new("execution aborted: host shutting down")
  end
end
