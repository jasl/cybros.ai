module Conversations
  class ContextAssembly
    # The selected environment is an accepted fact. Place its readable
    # announcement with the ordinary lead so history carries it once and a
    # regenerated request retains the original sealed preface.
    module EnvironmentLead
      module_function

      def call(environment)
        return [] unless environment

        public_id = environment["default_runner_executor_public_id"]
        return [] if public_id.nil? && Array(environment["runner_candidates"]).empty?

        selected = Array(environment["executors"]).find { |entry| entry["runner_executor_public_id"] == public_id }
        heading = public_id ? "Work environment: Runner #{public_id}." : "Work environment: no Runner selected."
        # The announcement's environment is opaque publisher metadata. Only
        # its optional readable fragments participate in prompt assembly.
        fragments = Array(selected&.dig("environment", "fragments")).filter_map do |fragment|
          Hash.try_convert(fragment)&.fetch("text", nil)
        end
        [Segment.plain("user", [heading, *fragments].join("\n\n"))]
      end
    end
  end
end
