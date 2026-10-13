require_relative "locales/en"

module Rho
  module FailureHints
    # Safe product guidance is selected by a kernel error key, never built
    # from a provider response. The CLI and ingress surfaces share this copy.
    def self.for(key) = Locales::ENGLISH[key]
  end
end
