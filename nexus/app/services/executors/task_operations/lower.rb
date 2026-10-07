module Executors
  module TaskOperations
    # The public step grammar with inherited declarations and model defaults.
    # This boundary resolves aliases before any child can become executable.
    class Lower
      Step = AgentRuns::Tasks::Step

      class Refusal < StandardError
        attr_reader :code

        def initialize(code, message)
          @code = code
          super(message)
        end
      end

      def initialize(node)
        @node = node
        @defaults = Context.defaults(node)
        @tools = Array(@defaults["tools"])
      end

      def call(steps)
        values = Array.try_convert(steps)
        refuse(:invalid_steps, "steps must be an array") if values.nil? || values.empty?
        refuse(:too_many_steps, "one operation accepts at most 64 steps") if count(values) > 64

        values.each_with_index.map { |step, index| lower(step, "steps[#{index}]") }
      end

      private

        def count(steps)
          values = Array.try_convert(steps) || refuse(:invalid_steps, "parallel members must be an array")
          values.sum do |entry|
            sequence = Array.try_convert(entry)
            next count(sequence) if sequence

            fields = Hash.try_convert(entry) || refuse(:invalid_steps, "each step must be an object")
            fields.key?("parallel") ? count(fields.fetch("parallel")) : 1
          end
        end

        def lower(value, path)
          fields = Hash.try_convert(value)
          refuse(:invalid_steps, "#{path} must be a step object") if fields.nil?
          refuse(:unsupported_step, "script steps are not supported by task operations") if fields.key?("script")

          if fields.key?("parallel")
            step = Step.from_h(fields, path)
            members = fields.fetch("parallel").each_with_index.map do |member, index|
              sequence = Array.try_convert(member)
              sequence ? sequence.each_with_index.map { |item, offset| lower(item, "#{path}.parallel[#{index}][#{offset}]") } :
                lower(member, "#{path}.parallel[#{index}]")
            end
            return policies(step.with(members: members))
          end

          if fields.key?("model")
            model(fields.fetch("model"), path)
          else
            step = policies(Step.from_h(fields, path))
            step.verb == "tool" ? tool(step) : step
          end
        end

        def policies(step)
          if step.lifetime && !AgentRunTask::LIFETIMES.include?(step.lifetime)
            refuse(:invalid_lifetime, "lifetime must be turn or conversation")
          end
          if step.wake && !AgentRunTask::WAKE_MODES.include?(step.wake)
            refuse(:invalid_wake, "wake must be auto or passive")
          end
          step
        end

        def tool(step)
          name = step.name.to_s
          unless Nexus::ToolDeclarations.names(@tools).include?(name)
            refuse(:unknown_tool_name, "#{name.inspect} is not declared for this execution")
          end
          refuse(:context_not_authorable, "child tools inherit the execution context") if step.model_defaults

          resolved, input, alias_name = Nexus::ToolDeclarations.resolve_call(@tools, name, step.input)
          route = Nexus::ToolDeclarations.route_for(@tools, name)&.except("tool_name")
          if step.route && step.route != route
            refuse(:tool_route_mismatch, "child tools must retain their declared Runner target")
          end
          step.with(name: resolved, input: input, alias: alias_name, route: route,
            on_failure: step.on_failure || "absorb")
        end

        def model(value, path)
          unless @defaults["model"]
            refuse(:context_not_authorable, "model work requires a declaring model or explicit standalone model_defaults")
          end
          fields = Hash.try_convert(value) || refuse(:invalid_steps, "#{path}.model must be an object")
          if fields.keys.intersect?(Nexus::ToolImports::FIELDS.map(&:to_s))
            refuse(:context_not_authorable, "child model work inherits its accepted tool and Runner context")
          end
          wanted = fields["tools"]
          if !wanted.nil? && Array.try_convert(wanted).nil?
            refuse(:invalid_tools, "model tools must be a list of declared names")
          end
          undeclared = wanted && Nexus::ToolDeclarations.undeclared(@tools, wanted)
          refuse(:unknown_tool_name, "#{undeclared.inspect} is not declared for this execution") if undeclared
          narrowed = AgentRuns::BranchTools.rerender(Nexus::ToolDeclarations.narrow(@tools, wanted))

          environment = @defaults["environment"]
          merged = @defaults.except("environment").merge(fields).merge("tools" => narrowed.presence)
          merged["on_failure"] ||= "absorb"
          selected = merged["model"]
          merged["model"] = { "model" => selected } if String.try_convert(selected)
          policies(Step.from_h({ "model" => merged.compact }, path).with(environment: environment))
        end

        def refuse(code, message) = raise Refusal.new(code, message)
    end
  end
end
