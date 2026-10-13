require_relative "../internal/keys"

module SimpleInference
  module Planning
    # An outgoing view of the caller's messages. It never changes the input
    # that a later call may compile for another model, and never chooses a
    # format from a provider, endpoint or model name.
    module PromptFormat
      INSTRUCTION_ROLES = %w[system developer].freeze
      TEXT_PART_TYPES = %w[text input_text output_text].freeze

      class << self
        def apply(format:, input:, options:)
          case format
          when nil then [input, options]
          when "qwen3_5" then qwen_instructions(input, options)
          else raise ArgumentError, "unhandled prompt format #{format}"
          end
        end

        private

        # Qwen's layout permits one initial system message and no developer
        # role. Later instructions stay at their original position as user
        # messages; moving them into the prefix would change earlier turns.
        def qwen_instructions(input, options)
          messages = messages_for(input)
          unless options[:instructions].nil?
            messages.unshift({ "role" => "system", "content" => options[:instructions] })
          end
          boundary = messages.index { |message| !instruction?(message) } || messages.length
          leading = messages.take(boundary)
          projected = leading.empty? ? [] : [leading_system(leading)]
          messages.drop(boundary).each do |message|
            if instruction?(message)
              projected << message.merge("role" => "user")
            else
              projected << message
            end
          end
          [projected, options.except(:instructions)]
        end

        # The public Responses input union includes a bare prompt, messages,
        # and strings inside a message list. Only message keys need inspection;
        # user media, tool payloads and reasoning remain opaque nested values.
        def messages_for(input)
          case input
          in String then [{ "role" => "user", "content" => input }]
          in Array
            input.map do |entry|
              case entry
              in String then { "role" => "user", "content" => entry }
              in Hash then Internal::Keys.shallow_stringify(entry)
              else raise SimpleInference::ValidationError, "prompt input entries must be messages or strings"
              end
            end
          else raise SimpleInference::ValidationError, "prompt input must be a string or message list"
          end
        end

        def instruction?(message) = INSTRUCTION_ROLES.include?(message["role"].to_s)

        def leading_system(messages)
          parts = messages.flat_map.with_index do |message, index|
            content = instruction_parts(message["content"])
            index.zero? ? content : [text_part("\n\n"), *content]
          end
          { "role" => "system", "content" => parts }
        end

        # The model's initial system slot is text-only. Reject media in the
        # merged prefix rather than dropping it or relocating it. Later
        # instructions become user messages and retain their media content.
        def instruction_parts(content)
          case content
          in String then [text_part(content)]
          in Array then content.map { |part| instruction_part(part) }
          in Hash then [instruction_part(content)]
          in nil then []
          else raise SimpleInference::ValidationError, "qwen3_5 instruction content must contain only text"
          end
        end

        def instruction_part(part)
          case part
          in String then text_part(part)
          in Hash
            normalized = Internal::Keys.shallow_stringify(part)
            unless TEXT_PART_TYPES.include?(normalized["type"])
              raise SimpleInference::ValidationError, "qwen3_5 instruction content must contain only text"
            end
            normalized
          else raise SimpleInference::ValidationError, "qwen3_5 instruction content must contain only text"
          end
        end

        def text_part(text) = { "type" => "input_text", "text" => text }
      end
    end
  end
end
