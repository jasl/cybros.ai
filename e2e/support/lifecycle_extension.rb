# Loaded as an ordinary operator extension by the deployed rho. Its results
# travel through the real executor claim and commit path.
module LifecycleProbe
  NAME = "e2e.lifecycle".freeze

  def self.register(api) = api.register_tool(Check, serves: :agent)

  class Check
    NAME = "lifecycle_check".freeze
    DESCRIPTION = "A deterministic lifecycle check.".freeze
    SCHEMA = { "type" => "object", "properties" => {}, "additionalProperties" => true }.freeze
    EFFECT_PROFILE = {
      "kind" => "read_only", "destructive" => false, "effect_scope" => "closed",
      "idempotency" => "intrinsic", "reconciliation" => "none",
    }.freeze
    TIMEOUT_MS = 30_000

    def initialize(env:)
      @env = env
    end

    def call(args)
      event = args.fetch("event")
      if event == "stop"
        continue = args.fetch("task_key") == "r1"
        result = { "continue" => continue }
        result["feedback"] = "Include lifecycle-feedback-verified in your final answer." if continue
        Rho::Runner::Result.ok("checked #{event}", result)
      else
        Rho::Runner::Result.ok("observed #{event}", { "continue" => false })
      end
    end
  end
end
