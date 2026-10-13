module ModelProviders
  module CodexAuthorization
    # Pure request construction, no IO or clock. The codecs are not
    # uniform: three phases post JSON, `code_exchange` posts form-encoded
    # to the same endpoint the JSON refresh uses.
    module Requests
      Prepared = Data.define(:phase, :http_method, :url, :headers, :body)

      JSON_CONTENT_TYPE = "application/json".freeze
      FORM_CONTENT_TYPE = "application/x-www-form-urlencoded".freeze

      class << self
        def user_code_request
          json(:user_code_request, CodexAuthorization.user_code_url, { "client_id" => CLIENT_ID })
        end

        def device_token_poll(device_auth_id:, user_code:)
          json(
            :device_token_poll, CodexAuthorization.device_token_url,
            { "device_auth_id" => required(device_auth_id, "device_auth_id"),
              "user_code" => required(user_code, "user_code") }
          )
        end

        # The one form-encoded phase. `redirect_uri` is the frozen release fact
        # rather than anything the poll response supplied: the response hands us
        # PKCE material, never a destination.
        def code_exchange(authorization_code:, code_verifier:)
          form(
            :code_exchange, CodexAuthorization.token_url,
            "grant_type" => "authorization_code",
            "code" => required(authorization_code, "authorization_code"),
            "redirect_uri" => CodexAuthorization.redirect_uri,
            "client_id" => CLIENT_ID,
            "code_verifier" => required(code_verifier, "code_verifier")
          )
        end

        # Exactly the upstream request struct. A rotated-away token is
        # refused by the provider (`invalid_grant`) — its fact, so a resent
        # refresh needs no gate on this side.
        def token_refresh(refresh_token:)
          json(
            :token_refresh, CodexAuthorization.token_url,
            { "client_id" => CLIENT_ID,
              "grant_type" => "refresh_token",
              "refresh_token" => required(refresh_token, "refresh_token") }
          )
        end

        private

          def json(phase, url, fields)
            Prepared.new(
              phase: phase, http_method: :post, url: url,
              headers: { "Content-Type" => JSON_CONTENT_TYPE }.freeze,
              body: ActiveSupport::JSON.encode(fields).freeze
            ).freeze
          end

          def form(phase, url, **fields)
            Prepared.new(
              phase: phase, http_method: :post, url: url,
              headers: { "Content-Type" => FORM_CONTENT_TYPE }.freeze,
              body: URI.encode_www_form(fields).freeze
            ).freeze
          end

          # A blank secret would otherwise be posted as an empty field and read
          # by the issuer as a different request than the one we meant.
          def required(value, name)
            text = value.to_s
            raise ArgumentError, "#{name} is required" if text.strip.empty?

            text
          end
      end
    end
  end
end
