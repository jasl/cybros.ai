module AgentAPI
  # The shared HTTP boundary for the input-shaped InferenceRequest commands. Strong
  # Parameters owns sibling allowlisting; the domain coercers own the input
  # grammar itself.
  module InferenceRequestInputParameters
    private

      def plain_inference_request_configuration(fields)
        fields[:configuration]&.to_h&.to_hash || {}
      end

      # A string-or-message-array cannot be expressed by Strong Parameters
      # without losing one of its shapes, so read it from the same parsed body
      # after the surrounding command fields have been allowlisted.
      def raw_inference_request_input(root)
        container = request.request_parameters[root.to_s]
        case container
        when Hash then container["input"]
        else nil
        end
      end

      def submitted_inference_request_selection(fields)
        model = fields[:model] || {}
        Nexus::SubmittedModelSelection.new(
          model: model[:model].to_s,
          reasoning_effort: model[:reasoning_effort],
          reasoning_enabled: cast_boolean(model[:reasoning_enabled])
        )
      end
  end
end
