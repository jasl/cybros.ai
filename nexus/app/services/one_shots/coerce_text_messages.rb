module OneShots
  # The one seam between wire JSON and the typed text grammar, which
  # refuses raw Hashes so a request body cannot forge its shape. Coerces,
  # never decides: an unrecognized shape passes through for the boundary to refuse.
  class CoerceTextMessages
    class << self
      def call(input)
        case input
        when Array then input.map { |message| coerce_message(message) }
        else input
        end
      end

      private

        def coerce_message(message)
          case message
          when Nexus::TextInputMessage then message
          when Hash then typed_message(message)
          else message
          end
        end

        # All or nothing: a half-coerced value wears a type the grammar
        # trusts while holding something it cannot read.
        def typed_message(message)
          case message["parts"]
          when Array
            parts = message["parts"].map { |part| coerce_part(part) }
            return message if parts.any?(&:nil?)

            Nexus::TextInputMessage.new(role: message["role"], parts: parts)
          else message
          end
        end

        # One closed part stream; anything this cannot type folds the
        # whole message back to what it came as.
        def coerce_part(part)
          case part
          when Nexus::TextInputPart, Nexus::UploadInputPart then part
          when Hash then typed_part(part)
          else nil
          end
        end

        def typed_part(part)
          case part["type"]
          when Nexus::InputParts::TEXT
            Nexus::TextInputPart.new(type: part["type"], text: part["text"])
          when Nexus::InputParts::UPLOAD
            Nexus::UploadInputPart.new(
              type: part["type"],
              upload_public_id: ContentUpload.canonical_public_id(part["upload_public_id"])
            )
          else nil
          end
        end
    end
  end
end
