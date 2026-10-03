module Rho
  class Runner
    # rho-runner carries its own error root rather than reaching for rho's:
    # the whole point of the split is that a runner can run with no daemon
    # around it, and inheriting from a class in another gem would make that
    # false at load time.
    class Error < StandardError; end

    module Extensions
      # An extension that cannot be registered as written. Raised at LOAD
      # — the moment somebody can still read it — rather than surfacing
      # later as a task parked to its deadline with nothing to read.
      class RegistrationError < Error; end
    end
  end
end
