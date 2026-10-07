module Rho
  module T3
    module Tools
      EFFECT = { "kind" => "write", "destructive" => true, "effect_scope" => "open",
        "idempotency" => "keyed", "reconciliation" => "lookup" }.freeze

      def self.delegate(factory)
        build("delegate_coding", factory, :delegate, {
          "type" => "object", "properties" => {
            "prompt" => { "type" => "string", "minLength" => 1, "maxLength" => 65_536 },
            "title" => { "type" => "string", "minLength" => 1, "maxLength" => 200 },
            "work_id" => { "type" => "string", "minLength" => 1 },
            "agent" => { "type" => "string", "minLength" => 1, "description" => "Available coding agent name, such as Codex or Claude Code; discover with coding_work action=agents." },
            "model" => { "type" => "string", "minLength" => 1, "description" => "A model ID, name or alias from this coding agent's available models. Applies only to new work." },
          }, "required" => ["prompt"], "additionalProperties" => false,
        }, "Delegate a complete coding assignment to an available coding agent. Handle straightforward work with your own tools when appropriate; delegation is a choice, not a requirement. " \
          "Honor an explicitly requested agent and model; discover supported combinations with coding_work action=agents instead of substituting an unsupported selection. " \
          "The selected agent owns its native execution policy. This call waits for completion, relays questions and approval requests, and returns its selected model, checks and result/diff captures. " \
          "Use ordinary background work to keep this conversation available. Pass a completed work_id to continue its original agent, model and workspace. " \
          "Never repeat a launch after an uncertain outcome; observe its work_id.")
      end

      def self.control(factory)
        build("coding_work", factory, :control, {
          "type" => "object", "properties" => {
            "action" => { "type" => "string", "enum" => %w[agents list observe steer stop forget] },
            "work_id" => { "type" => "string", "minLength" => 1 },
            "prompt" => { "type" => "string", "minLength" => 1, "maxLength" => 65_536 },
          }, "required" => ["action"], "additionalProperties" => false,
          "allOf" => [
            { "if" => { "properties" => { "action" => { "const" => "steer" } } }, "then" => { "required" => ["prompt"] } },
            { "if" => { "properties" => { "action" => { "enum" => %w[observe steer stop forget] } } }, "then" => { "required" => ["work_id"] } },
          ],
        }, "Discover available coding agents and their supported models with action=agents. List, observe, steer or stop coding work from this conversation. List finds work IDs; observe reads live state. Observations show subagents, pending questions, " \
          "reported commands and results. Stop is a request; observe its completion. Forget releases a settled continuation slot " \
          "after its Nexus task has ended; task history and retained captures remain.")
      end

      def self.build(name, factory, verb, schema, description)
        Class.new do
          const_set(:NAME, name.freeze)
          const_set(:DESCRIPTION, description.freeze)
          const_set(:SCHEMA, Ractor.make_shareable(schema))
          const_set(:EFFECT_PROFILE, EFFECT)
          const_set(:TIMEOUT_MS, verb == :delegate ? 3_600_000 : 60_000)
          define_method(:initialize) { |env:| @env = env }
          define_method(:call) do |args|
            factory.call(@env).public_send(verb, args)
          # SDK failures must reach TaskRun's failed outcome, which closes any
          # accepted question whose response was lost before observation.
          rescue Error => error
            Rho::Runner::Result.error(error.message)
          end
        end
      end
    end
  end
end
