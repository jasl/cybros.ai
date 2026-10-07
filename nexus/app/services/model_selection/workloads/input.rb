module ModelSelection
  module Workloads
    # Payload refusals are the only ones decided by what the caller sent
    # rather than what the catalog offers, and every content door must refuse identically.
    module Input
      TEXT_MESSAGE_ROLES = %w[system developer user assistant].freeze
      # An image edit is an image upload on the image lane (images/edits
      # takes the source images in); which rows take one is their
      # `input_modalities`, so the policy below is the same optional one
      # text carries.
      WORKLOAD_UPLOAD_MODALITIES = {
        "text_generation" => %w[image file].freeze,
        "image_generation" => ["image"].freeze,
        "transcription" => ["audio"].freeze,
      }.freeze
      # Neither is a 413: a model-context overflow and an inline-part bound
      # are 422s named for the limit hit, so a caller can tell what to shrink.
      OVER_MODEL_LIMIT = :input_over_model_limit
      OVER_INLINE_BOUND = ModelRequests::Build::OVER_INLINE_BOUND
      UPLOAD_POLICY = {
        "text_generation" => :optional,
        "image_generation" => :optional,
        "speech_generation" => :none,
        "transcription" => :exactly_one_audio,
        "embedding" => :none,
      }.freeze

      class << self
        include Predicates

        def normalize_input(workload:, input:)
          return Normalization.refused(:unsupported_workload) unless
            Nexus::ModelWorkloads::ALL.include?(workload)

          case workload
          when "text_generation"
            normalize_text_input(input)
          when "embedding"
            normalize_embedding_input(input)
          when "image_generation", "speech_generation"
            normalize_required_string_input(input)
          when "transcription"
            normalize_optional_string_input(input)
          else
            raise ArgumentError, "unhandled workload: #{workload}"
          end
        end

        # A composed request still needs a message; role-less items exist to
        # precede one, never replace it. This checks the aggregate, not its grammar.
        def message_presence_refusal(messages)
          has_message = messages.any? do |element|
            case element
            when Nexus::TextInputMessage then true
            else false
            end
          end
          :missing_input unless has_message
        end

        # Public because only the assembling facade holds the resolved
        # selection and the ordered upload bindings these judgments assume.
        def upload_policy_refusal(selection, uploads)
          case UPLOAD_POLICY.fetch(selection.workload)
          when :none
            :uploads_not_supported unless uploads.empty?
          when :exactly_one_audio
            return :missing_input_upload if uploads.empty?
            return :too_many_input_uploads if uploads.length > 1
            unless media_allowed?(selection, uploads.first.content_type)
              return :unsupported_input_media
            end
            oversize_pass_through_refusal(uploads, selection)
          when :optional
            unsupported_optional_upload_refusal(uploads, selection) ||
              oversize_pass_through_refusal(uploads, selection)
          else
            raise ArgumentError, "unhandled upload policy: #{UPLOAD_POLICY.fetch(selection.workload)}"
          end
        end

        # Which roles this lane's wire accepts: the global vocabulary is the
        # union, so a role a lane's wire does not admit is refused here, where
        # the caller can fix it, rather than at the wire. `developer` rides
        # every shipped lane (Anthropic and Gemini lower it to `user` in
        # place), so no shipped wire is narrower than the union today.
        def role_policy_refusal(selection, value)
          # A text_generation input is a message list or a bare prompt; only
          # the list carries roles at all.
          messages = case value
          when Array then value
          else return
          end

          accepted = SimpleInference::ApiFormat.accepted_roles(
            selection.execution_profile.adapter_profile
          )
          return if accepted.nil?

          roles = messages.filter_map do |message|
            # Role-less items (replayed reasoning, tool splices) carry no
            # role to police.
            case message
            when Nexus::ReasoningInputItem, Nexus::ToolCallInputItem,
                 Nexus::ToolResultInputItem
              nil
            else message.role
            end
          end
          :unsupported_input_role unless roles.all? { |role| accepted.include?(role) }
        rescue SimpleInference::ConfigurationError
          nil
        end

        # How many texts this route carries, asked here so work that could
        # never run is not told yes; the arity is the gem's declaration.
        def input_arity_refusal(selection, value)
          return unless selection.workload == "embedding"

          bound = SimpleInference::ApiFormat.max_input_texts(
            selection.execution_profile.adapter_profile
          )
          return if bound.nil?

          Workloads::TOO_MANY_INPUT_TEXTS if Array(value).length > bound
        rescue SimpleInference::ConfigurationError
          nil
        end

        # Upload placement is exact: an upload with no occurrence has no
        # placement a compiler may invent, and an occurrence naming an
        # unbound upload references bytes never accepted.
        def upload_placement_refusal(workload, value, uploads)
          placed = placed_upload_public_ids(workload, value)
          return if placed.nil?

          bound = uploads.map(&:public_id)
          return :unplaced_input_upload if (bound - placed).any?
          return :unknown_input_upload if (placed - bound).any?

          nil
        end

        # `nil` is "carries no occurrences", not "carries none". A plain
        # string with bound uploads has nowhere to put them, so it is
        # refused here rather than stranded at compile time.
        def placed_upload_public_ids(workload, value)
          return unless workload == "text_generation"

          case value
          when Array
            value.flat_map do |element|
              case element
              when Nexus::TextInputMessage then element.upload_public_ids
              else []
              end
            end.uniq
          else []
          end
        end

        # The count is storage's sanity bound, sized above what the byte
        # wall admits — a refusal here is corruption protection, never a
        # ceiling: a composed round under the byte wall cannot reach it.
        def input_count_refusal(value)
          entries = Array(value).length
          return if Nexus::SizeBounds.count_within?(:body_entry_count_bound, entries)

          Nexus::SizeBounds::COUNT_REJECTION
        end

        def input_bound_refusal(selection, value, uploads)
          limit = selection.capabilities.limits.input_bytes
          return unless limit

          bytes = normalized_input_bytes(selection.workload, value) + uploads.sum(&:byte_size)
          OVER_MODEL_LIMIT if bytes > limit
        end

        # Allowed when the lane accepts its bytes: workload, capability
        # and allowlist. No `token_cost` clause — the seal-time gate it
        # protected left with the course correction. PUBLIC: the one
        # predicate placement reads at assembly, so the part a row
        # cannot take degrades to the index line where the segments are
        # built rather than blocking the head here.
        def media_allowed?(selection, media_type)
          selection.execution_profile.input_media.any? do |modality, facts|
            next false unless WORKLOAD_UPLOAD_MODALITIES.fetch(selection.workload).include?(modality)
            next false unless selection.capabilities.input_modalities.include?(modality)

            facts.mime_allowlist.include?(media_type.to_s)
          end
        end

        private

          def normalize_text_input(input)
            case input
            when String
              normalize_required_string_input(input)
            when Array
              normalize_text_messages(input)
            when nil
              Normalization.refused(:missing_input)
            else
              Normalization.refused(:invalid_input)
            end
          end

          def normalize_embedding_input(input)
            values = case input
            when String
              [input]
            else
              input
            end
            case values
            when Array
              if values.empty?
                Normalization.refused(:missing_input)
              elsif values.all? { |value| present_string?(value) }
                Normalization.accepted(values.map { |value| value.dup.freeze }.freeze)
              else
                Normalization.refused(:invalid_input)
              end
            when nil
              Normalization.refused(:missing_input)
            else
              Normalization.refused(:invalid_input)
            end
          end

          def normalize_required_string_input(input)
            case input
            when String
              if input.strip.empty?
                Normalization.refused(:missing_input)
              else
                Normalization.accepted(input.dup.freeze)
              end
            when nil
              Normalization.refused(:missing_input)
            else
              Normalization.refused(:invalid_input)
            end
          end

          def normalize_optional_string_input(input)
            case input
            when String
              if input.strip.empty?
                Normalization.refused(:invalid_input)
              else
                Normalization.accepted(input.dup.freeze)
              end
            when nil
              Normalization.accepted(nil)
            else
              Normalization.refused(:invalid_input)
            end
          end

          def normalize_text_messages(messages)
            return Normalization.refused(:missing_input) if messages.empty?

            normalized = messages.map { |element| normalize_text_element(element) }
            return Normalization.refused(:invalid_input) if normalized.any?(&:nil?)
            refusal = message_presence_refusal(normalized)
            return Normalization.refused(refusal) if refusal

            Normalization.accepted(normalized.freeze)
          end

          def normalize_text_element(element)
            case element
            when Nexus::TextInputMessage then normalize_text_message(element)
            when Nexus::ReasoningInputItem then normalize_reasoning_item(element)
            when Nexus::ToolCallInputItem then normalize_tool_call_item(element)
            when Nexus::ToolResultInputItem then normalize_tool_result_item(element)
            else nil
            end
          end

          # Raw callers supply their own tool splice pair. Each payload must
          # match its declared wire kind; kernel-authored pairs trust their writer.
          def normalize_tool_call_item(element)
            payload = Hash.try_convert(element.payload)
            return unless payload && payload["type"].to_s == "function_call"

            Nexus::ToolCallInputItem.new(
              type: "tool_call_item", payload: payload.freeze, native_origin: element.native_origin
            )
          end

          def normalize_tool_result_item(element)
            payload = Hash.try_convert(element.payload)
            return unless payload && payload["type"].to_s == "function_call_output"

            Nexus::ToolResultInputItem.new(
              type: "tool_result_item", payload: payload.freeze
            )
          end

          # The Responses family's role-less reasoning item, kernel-authored
          # by the replay ladder (raw mode may also carry one — full control
          # is raw's point; a forged blob is the provider's 400 to give).
          def normalize_reasoning_item(element)
            payload = Hash.try_convert(element.payload)
            return unless payload && payload["type"].to_s == "reasoning"

            Nexus::ReasoningInputItem.new(
              type: "reasoning_item", payload: payload.freeze, native_origin: element.native_origin
            )
          end

          def normalize_text_message(message)
            return unless present_string?(message.role) && TEXT_MESSAGE_ROLES.include?(message.role)
            return if message.parts.empty?

            parts = message.parts.map { |part| normalize_text_part(part) }
            return if parts.any?(&:nil?)

            # A wire's label on an assistant message rides with its origin
            # verbatim, as a replayed item's origin does: the compiler, not
            # acceptance, decides which wire may receive it.
            Nexus::TextInputMessage.new(
              role: message.role.dup.freeze,
              parts: parts.freeze,
              phase: message.phase,
              native_origin: message.native_origin
            )
          end

          # One closed part stream; an upload part carries only a reference, so a
          # caller cannot declare a type the bytes disagree with.
          def normalize_text_part(part)
            case part
            when Nexus::TextInputPart then normalize_text_only_part(part)
            when Nexus::UploadInputPart then normalize_upload_part(part)
            when Nexus::ReasoningInputPart then normalize_reasoning_part(part)
            else nil
            end
          end

          # In-message replayed reasoning: the neutral block shapes the
          # protocol layer lowers natively and the chat fields the build
          # lifts — a closed set (`Nexus::ReasoningInputPart::PAYLOAD_TYPES`),
          # so a typo'd shape refuses here instead of surfacing as a provider 400.
          def normalize_reasoning_part(part)
            payload = Hash.try_convert(part.payload)
            return unless payload &&
              Nexus::ReasoningInputPart::PAYLOAD_TYPES.include?(payload["type"].to_s)

            Nexus::ReasoningInputPart.new(
              type: Nexus::InputParts::REASONING, payload: payload.freeze, native_origin: part.native_origin
            )
          end

          def normalize_text_only_part(part)
            return unless present_string?(part.text)

            Nexus::TextInputPart.new(type: Nexus::InputParts::TEXT, text: part.text.dup.freeze)
          end

          def normalize_upload_part(part)
            return unless present_string?(part.upload_public_id)

            Nexus::UploadInputPart.new(
              type: Nexus::InputParts::UPLOAD,
              upload_public_id: part.upload_public_id.dup.freeze
            )
          end

          def unsupported_optional_upload_refusal(uploads, selection)
            return if uploads.empty?

            if uploads.any? { |upload| !media_allowed?(selection, upload.content_type) }
              :unsupported_input_media
            end
          end

          # The inline bound where it is already knowable — a pass-through
          # lane sends the source bytes — so work is not accepted and then
          # refused at send; the send says which workloads inline at all.
          def oversize_pass_through_refusal(uploads, selection)
            return if selection.execution_profile.multipart?

            declared = selection.execution_profile.input_media
            return if declared.empty?

            oversize = uploads.any? do |upload|
              _modality, facts = declared.find do |_name, media|
                media.mime_allowlist.include?(upload.content_type.to_s)
              end
              next false if facts.nil? || !facts.max_dimension.nil?

              !Nexus::SizeBounds.bytes_within?(:inline_binary_bound, upload.byte_size)
            end

            OVER_INLINE_BOUND if oversize
          end

          def normalized_input_bytes(workload, value)
            case workload
            when "text_generation"
              case value
              when String
                value.bytesize
              when Array
                Nexus::CanonicalJson.bytesize(value.map(&:to_h))
              else
                raise ArgumentError, "unhandled normalized text input: #{value.class}"
              end
            when "embedding"
              value.sum(&:bytesize)
            when "image_generation", "speech_generation"
              value.bytesize
            when "transcription"
              value&.bytesize || 0
            else
              raise ArgumentError, "unhandled workload: #{workload}"
            end
          end
      end
    end
  end
end
