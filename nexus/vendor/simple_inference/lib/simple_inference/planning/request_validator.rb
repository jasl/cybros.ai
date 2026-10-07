require_relative "../internal/keys"
require_relative "prompt_format"

module SimpleInference
  module Planning
    # Pure request validation and model prompt preparation against an
    # ExecutionProfile.
    #
    # This is the capability half of the single compile path: every gate reads
    # an explicit profile fact and fails closed — a workload, model pin,
    # capability, or input modality the profile does not declare rejects the
    # request before any protocol object or wire body exists.
    module RequestValidator
      CONVERSATION_STATE_KEYS = %i[previous_response_id conversation conversation_id].freeze

      # SDK-only control flags: they gate the checks below and are NEVER
      # provider request parameters — validate_responses_request strips them
      # after validation so no protocol can serialize them to the wire.
      RESPONSES_CONTROL_KEYS = %i[
        allow_builtin_tools
        prefer_stateful_responses
        allow_multimodal_inputs
        allow_image_input
        allow_audio_input
        allow_video_input
        allow_file_input
      ].freeze

      module_function

      def validate_responses_request(profile:, model:, input:, options:, streaming:)
        ensure_workload(profile, "text_generation", surface: "responses")
        ensure_model_pin(profile, model)
        ensure_streaming(profile) if streaming

        normalized = Internal::Keys.shallow_symbolize(options)

        validate_protocol_enum_values(normalized)
        validate_tool_request(profile, normalized)
        validate_conversation_state_request(profile, normalized)
        validate_multimodal_request(profile, input, normalized)

        PromptFormat.apply(
          format: profile.wire_option(:prompt_format), input: input,
          options: normalized.except(*RESPONSES_CONTROL_KEYS)
        )
      end

      def validate_images_request(profile:, model:, options:)
        ensure_workload(profile, "image_generation", surface: "images.generate")
        ensure_model_pin(profile, model)

        normalized = Internal::Keys.shallow_symbolize(options)
        if option_explicitly_false?(normalized, :allow_image_generation)
          raise SimpleInference::CapabilityError, "images.generate is disabled for this request"
        end

        normalized.reject { |key, _value| key == :allow_image_generation }
      end

      def validate_speech_request(profile:, model:, options:)
        ensure_workload(profile, "speech_generation", surface: "audio.speech.create")
        ensure_model_pin(profile, model)

        Internal::Keys.shallow_symbolize(options)
      end

      def validate_transcription_request(profile:, model:, options:)
        ensure_workload(profile, "transcription", surface: "audio.transcriptions.create")
        ensure_model_pin(profile, model)

        Internal::Keys.shallow_symbolize(options)
      end

      def validate_embeddings_request(profile:, model:, options:)
        ensure_workload(profile, "embedding", surface: "embeddings.create")
        ensure_model_pin(profile, model)

        Internal::Keys.shallow_symbolize(options)
      end

      def ensure_workload(profile, workload, surface:)
        return if profile.workload == workload

        raise SimpleInference::CapabilityError,
              "#{surface} requires a #{workload} execution profile " \
              "(#{profile.profile_id} is #{profile.workload})"
      end

      def ensure_model_pin(profile, model)
        return if model.to_s == profile.model_pin

        raise SimpleInference::CapabilityError,
              "model #{model.inspect} is not the execution profile's pinned model " \
              "(#{profile.profile_id} pins #{profile.model_pin})"
      end

      def ensure_streaming(profile)
        return if profile.streaming?

        raise SimpleInference::CapabilityError,
              "streaming is not enabled for execution profile #{profile.profile_id}"
      end

      def validate_protocol_enum_values(options)
        validate_response_format_shape(options)
        validate_tools_shape(options)
        validate_envelope_type(options[:response_format], "response_format")
        Array(options[:tools]).each do |tool|
          validate_envelope_type(tool, "tool")
        end

        tool_choice = options[:tool_choice]
        if tool_choice.is_a?(Hash)
          validate_envelope_type(tool_choice, "tool_choice")
        elsif !tool_choice.nil? && !tool_choice.is_a?(String)
          raise SimpleInference::ValidationError, "tool_choice must be a string or object"
        end
      end

      def validate_response_format_shape(options)
        return unless options.key?(:response_format)
        return if options[:response_format].is_a?(Hash)

        raise SimpleInference::ValidationError, "response_format must be an object"
      end

      def validate_tools_shape(options)
        return unless options.key?(:tools)
        raise SimpleInference::ValidationError, "tools must be an array" unless options[:tools].is_a?(Array)

        options[:tools].each do |tool|
          next if tool.is_a?(Hash)

          raise SimpleInference::ValidationError, "tool must be an object"
        end
      end

      def validate_envelope_type(envelope, label)
        return if envelope.nil?

        if envelope.key?("type")
          raise SimpleInference::ValidationError, "#{label} type must use a symbol key"
        end

        return unless envelope.key?(:type)
        return if envelope[:type].is_a?(String)

        raise SimpleInference::ValidationError, "#{label} type must be a string"
      end

      def validate_tool_request(profile, options)
        tools = Array(options[:tools])
        return if tools.empty?

        typed_tools = tools.filter_map do |entry|
          type = tool_type(entry)
          [entry, type] if type
        end
        function_tools, builtin_tools = typed_tools.partition { |_entry, type| type == "function" }

        if function_tools.any? && !profile.capability_enabled?("tool_calls")
          raise SimpleInference::CapabilityError,
                "function tools are not enabled for execution profile #{profile.profile_id}"
        end

        return if builtin_tools.empty?

        if option_explicitly_false?(options, :allow_builtin_tools)
          raise SimpleInference::CapabilityError, "builtin tools are disabled for this request"
        end

        return if profile.capability_enabled?("provider_builtin_tools")

        raise SimpleInference::CapabilityError,
              "builtin tools are not enabled for execution profile #{profile.profile_id}"
      end

      def validate_conversation_state_request(profile, options)
        stateful_keys = CONVERSATION_STATE_KEYS.select { |key| present_option?(options, key) }
        return if stateful_keys.empty?

        if option_explicitly_false?(options, :prefer_stateful_responses)
          raise SimpleInference::CapabilityError, "conversation state is disabled for this request"
        end

        return if profile.capability_enabled?("conversation_state")

        raise SimpleInference::CapabilityError,
              "conversation state is not enabled for execution profile #{profile.profile_id}"
      end

      def validate_multimodal_request(profile, input, options)
        part_kinds = extract_part_kinds(input)
        return if part_kinds.empty?

        if option_explicitly_false?(options, :allow_multimodal_inputs)
          raise SimpleInference::CapabilityError, "multimodal inputs are disabled for this request"
        end

        part_kinds.each do |kind|
          if option_explicitly_false?(options, :"allow_#{kind}_input")
            raise SimpleInference::CapabilityError, "#{kind} inputs are disabled for this request"
          end

          next if profile.input_modality_enabled?(kind)

          raise SimpleInference::CapabilityError,
                "#{kind} inputs are not enabled for execution profile #{profile.profile_id}"
        end
      end

      def extract_part_kinds(input)
        case input
        when Array
          input.flat_map { |entry| extract_part_kinds(entry) }.uniq
        when Hash
          extract_part_kinds_from_hash(input)
        else
          []
        end
      end

      def extract_part_kinds_from_hash(entry)
        entry = Internal::Keys.shallow_stringify(entry)

        if entry.key?("content")
          return extract_part_kinds(entry["content"])
        end

        type = entry["type"].to_s
        return [type_to_part_kind(type)].compact if value_present?(type)

        keys_to_part_kinds(entry)
      end

      def keys_to_part_kinds(entry)
        normalized_entry = Internal::Keys.shallow_stringify(entry)

        if value_present?(normalized_entry["image_url"])
          ["image"]
        elsif value_present?(normalized_entry["file_id"]) || value_present?(normalized_entry["file_data"])
          ["file"]
        elsif value_present?(normalized_entry["input_audio"])
          ["audio"]
        elsif value_present?(normalized_entry["input_video"])
          ["video"]
        elsif normalized_entry["inline_data"]
          kind = inline_data_kind(Internal::Keys.shallow_stringify(normalized_entry["inline_data"]))
          kind ? [kind] : []
        else
          []
        end
      end

      def inline_data_kind(inline_data)
        mime_type = inline_data["mime_type"].to_s
        return "image" if mime_type.start_with?("image/")
        return "audio" if mime_type.start_with?("audio/")
        return "video" if mime_type.start_with?("video/")
        # NOTE: plain-Ruby presence check — this gem must not assume ActiveSupport.
        return "file" if value_present?(mime_type)

        nil
      end

      def type_to_part_kind(type)
        case type
        when "input_image", "image", "image_url"
          "image"
        when "input_audio", "audio"
          "audio"
        when "input_video", "video"
          "video"
        when "input_file", "file"
          "file"
        else
          nil
        end
      end

      def tool_type(tool)
        type = tool[:type]
        type if type.is_a?(String) && !type.empty?
      end

      def option_explicitly_false?(options, key)
        return false unless options.key?(key)

        options[key] == false
      end

      def present_option?(options, key)
        value_present?(options[key])
      end

      def value_present?(value)
        case value
        when nil
          false
        when String, Array, Hash
          !value.empty?
        else
          true
        end
      end
    end
  end
end
