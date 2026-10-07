module Rho
  module Acp
    class Agent
      # A JSON-RPC ERROR THE SURFACE ANSWERS: the code, the sentence, the data. Raised on the
      # thread that serves a request and rendered by the dispatcher as
      # `Inbound#fail`; nothing else is ever a refusal on the wire.
      class Refusal < StandardError
        attr_reader :code, :data

        def initialize(code, message, data: nil)
          super(message)
          @code = code
          @data = data
        end

        class << self
          def invalid_params(message, data: nil) = new(Acp::Methods::ErrorCode::INVALID_PARAMS, message, data: data)
          def invalid_request(message) = new(Acp::Methods::ErrorCode::INVALID_REQUEST, message)
          def not_found(message) = new(Acp::Methods::ErrorCode::RESOURCE_NOT_FOUND, message)
          def internal(message, data: nil) = new(Acp::Methods::ErrorCode::INTERNAL, message, data: data)
          def auth_required(message, data: nil) = new(Acp::Methods::ErrorCode::AUTH_REQUIRED, message, data: data)
          def method_not_found(name) = new(Acp::Methods::ErrorCode::METHOD_NOT_FOUND, "#{Acp::Methods::ErrorCode::MESSAGES.fetch(Acp::Methods::ErrorCode::METHOD_NOT_FOUND)}: #{name}")

          def cancelled
            code = Acp::Methods::ErrorCode::REQUEST_CANCELLED
            new(code, Acp::Methods::ErrorCode::MESSAGES.fetch(code))
          end
        end
      end

      # THE ERROR MAPPING: a `Rho::Error` — the
      # daemon's refusal — is -32603 with the sentence and `data.code`, the
      # refusal's own code word as `Core::Refused` carries it beside the
      # sentence and the status (`Core#refuse` relayed the message alone, so this mapping read SENTENCES — a prefix, two regexes, a leading "<word>: " — and a daemon rewording broke it silently; the code is the contract now, and no sentence is read); a plain `Rho::Error` (the core's own
      # refusal before any call, a daemon not running) is -32603 with the
      # sentence and no code invented from its words; `ConnectionError`
      # is -32603; `Core::Deadline` -32603; the connection's `Closed`
      # -32603 (the editor went away mid-call); a `RemoteError` the client
      # answered -32603 quoting it. The four codes that fault the REQUEST
      # are -32602 with the daemon's sentence: a kernel block
      # (`input_blocked` — the sentence carries the kernel's reason, an
      # unknown model, a refused selection), the environment door's two
      # validation words (`not_a_directory`, `protected_root`) and a
      # `malformed_body`. A `Refusal` passes through as itself.
      module Errors
        INVALID_PARAMS = %w[input_blocked not_a_directory protected_root malformed_body].freeze

        module_function

        def translate(error)
          case error
          when Refusal then error
          when Rho::ConnectionError then Refusal.internal(error.message)
          when Rho::Core::Deadline then Refusal.internal(error.message)
          when Rho::Core::Refused then from_refusal(error)
          when RemoteError then Refusal.internal("the client answered #{error.code}: #{error.message}")
          when Closed, Unanswered then Refusal.internal(error.message)
          when Rho::Error then Refusal.internal(error.message)
          else Refusal.internal("#{error.class}: #{error.message}")
          end
        end

        # The daemon's refusal, by its code.
        def from_refusal(error)
          return Refusal.invalid_params(error.message) if INVALID_PARAMS.include?(error.code)

          Refusal.internal(error.message, data: error.code && { "code" => error.code })
        end
      end
    end
  end
end
