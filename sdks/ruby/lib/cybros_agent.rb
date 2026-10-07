require_relative "cybros_agent/version"

require_relative "cybros_agent/redaction"
require_relative "cybros_agent/redacted"
require_relative "cybros_agent/size_bounds"

module CybrosAgent
  class Error < StandardError
    # Every diagnostic is scrubbed here, once, so no plane can drift into its
    # own redaction rule.
    def initialize(message = nil) = super(message && Redaction.call(message))

    # Retryable subclasses answer the delay the remote side prescribed; one
    # reader keeps retry loops polymorphic across every failure family.
    def retry_after = nil

    # Typed API failures carry the family's envelope code; the rest answer nil
    # so a consumer classifies by `code` without asking the class first.
    def code = nil
  end
end

require_relative "cybros_agent/transport"
require_relative "cybros_agent/device_flow"
require_relative "cybros_agent/application_oauth"
require_relative "cybros_agent/realtime/errors"
require_relative "cybros_agent/steps"
require_relative "cybros_agent/api"
require_relative "cybros_agent/kernel_feed"
require_relative "cybros_agent/input_materialization"
require_relative "cybros_agent/client"
require_relative "cybros_agent/executor_client"
require_relative "cybros_agent/platform"
require_relative "cybros_agent/platform_client"
require_relative "cybros_agent/sessions"
require_relative "cybros_agent/planes"
require_relative "cybros_agent/credentials"
require_relative "cybros_agent/model_pattern"
require_relative "cybros_agent/model_adaptations"

# The default transport pulls in httpx; a caller injecting its own transport
# does not need it installed.
begin
  require_relative "cybros_agent/http_transport"
rescue LoadError
  nil
end
