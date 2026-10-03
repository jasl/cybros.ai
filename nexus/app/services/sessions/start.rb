module Sessions
  class Start
    Credentials = Data.define(:email, :password) do
      def invalid_for_authentication?
        email.include?("\0") || !Identity.bcrypt_compatible_password?(password)
      end
    end
    Result = Data.define(:outcome, :session, :secret)

    class << self
      # Exactly one BCrypt verification, dummy hash included. Login is not
      # serialized against password mutations: a Session minted across one is born fenced.
      def call(source:, kind: :browser, user_agent: nil, ip_address: nil)
        case source
        when Credentials
          authenticate_and_start(source, kind: kind, user_agent: user_agent, ip_address: ip_address)
        when Identity
          start_established_identity(source, kind: kind, user_agent: user_agent, ip_address: ip_address)
        else
          raise ArgumentError, "unsupported session source: #{source.class}"
        end
      end

      private

        def authenticate_and_start(credentials, kind:, user_agent:, ip_address:)
          if credentials.invalid_for_authentication?
            return result(:invalid_credentials)
          end

          identity = Identity.authenticate_by(email: credentials.email, password: credentials.password)
          if identity.nil? || !identity.user&.active?
            result(:invalid_credentials)
          elsif identity.local_recovery_pending?
            result(:local_recovery_required)
          elsif kind == :api && identity.password_change_required?
            result(:password_change_required)
          else
            start(identity, kind: kind, user_agent: user_agent, ip_address: ip_address)
          end
        end

        def start_established_identity(identity, kind:, user_agent:, ip_address:)
          if kind == :browser
            start_browser(identity, user_agent: user_agent, ip_address: ip_address)
          else
            raise ArgumentError, "an established identity can start only a browser session"
          end
        end

        def start(identity, kind:, user_agent:, ip_address:)
          case kind
          when :api
            start_api(identity)
          when :browser
            start_browser(identity, user_agent: user_agent, ip_address: ip_address)
          else
            raise ArgumentError, "unknown session kind: #{kind.inspect}"
          end
        end

        def start_api(identity)
          parts = Session::DIGESTED.mint_parts
          session = identity.sessions.create!(kind: :api, lookup_id: parts.lookup_id, secret_digest: parts.digest)
          result(:authenticated, session: session, secret: parts.raw)
        end

        def start_browser(identity, user_agent:, ip_address:)
          session = identity.sessions.create!(user_agent: user_agent&.first(255), ip_address: ip_address)
          result(:authenticated, session: session)
        end

        def result(outcome, session: nil, secret: nil)
          Result.new(outcome: outcome, session: session, secret: secret)
        end
    end
  end
end
