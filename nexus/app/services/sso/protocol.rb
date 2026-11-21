module Sso
  class Protocol
    SIGNING_ALGORITHMS = %w[RS256 RS384 RS512 PS256 PS384 PS512 ES256 ES384 ES512].freeze

    def initialize(provider)
      @provider = provider
    end

    def authorization_url(attempt:, state:)
      endpoint = endpoints.fetch("authorization_endpoint").dup
      args = {
        response_type: "code", client_id: @provider.client_id, redirect_uri: attempt.redirect_uri,
        scope: @provider.scopes, state: state, code_challenge_method: "S256",
        code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(attempt.code_verifier), padding: false),
      }
      if @provider.protocol == "oidc"
        args[:nonce] = attempt.nonce
        args[:max_age] = 300 if attempt.purpose == "reauth"
      end
      endpoint.query = URI.encode_www_form(URI.decode_www_form(endpoint.query.to_s) + args.to_a)
      endpoint.to_s
    end

    def authenticate(attempt:, code:)
      raise ProtocolError unless code.present? && code.bytesize <= 4096

      form = { grant_type: "authorization_code", code: code, code_verifier: attempt.code_verifier, redirect_uri: attempt.redirect_uri }
      headers = {}
      if @provider.token_auth_method == "client_secret_post"
        form.merge!(client_id: @provider.client_id, client_secret: @provider.client_secret)
      else
        credentials = [@provider.client_id, @provider.client_secret].map { |v| URI.encode_www_form_component(v) }.join(":")
        headers["authorization"] = "Basic #{Base64.strict_encode64(credentials)}"
      end

      grant = Http.json("POST", endpoints.fetch("token_endpoint"), headers: headers, form: form)
      token = grant.fetch("access_token")
      raise ProtocolError unless grant.fetch("token_type").to_s.casecmp?("bearer") && token.to_s.match?(/\A[!-~]+\z/)

      if @provider.protocol == "oidc"
        claims = verified_claims(grant.fetch("id_token"), attempt)
        info = user_info(token)
        raise ProtocolError unless claims.fetch("sub") == info.fetch("sub")

        groups = info["groups"]
        admitted = @provider.required_group.blank? || Array.try_convert(groups)&.include?(@provider.required_group)
        profile(info.fetch("sub"), info["email"], info["email_verified"], info["name"] || info["preferred_username"], !!admitted)
      else
        info = user_info(token)
        subject = field(info, @provider.subject_field)
        # OAuth APIs commonly return a numeric primary key. Never stringify a nested object.
        subject = case subject
        when String then subject
        when Integer then subject.to_s
        else raise ProtocolError
        end
        profile(subject, field(info, @provider.email_field), field(info, @provider.email_verified_field),
          field(info, @provider.name_field), @provider.required_group.blank?)
      end
    rescue KeyError, TypeError, ArgumentError, JWT::DecodeError, JWT::JWKError, OpenSSL::PKey::PKeyError
      raise ProtocolError, cause: nil
    end

    private

      def endpoints
        @endpoints ||= if @provider.protocol == "oidc"
          discovery = Http.json("GET", endpoint_uri("#{@provider.issuer.delete_suffix("/")}/.well-known/openid-configuration"))
          raise ProtocolError unless discovery["issuer"] == @provider.issuer
          permitted = [URI(@provider.issuer).origin, *@provider.trusted_origins.to_s.split]
          %w[authorization_endpoint token_endpoint userinfo_endpoint jwks_uri].to_h do |key|
            uri = endpoint_uri(discovery.fetch(key))
            raise ProtocolError unless permitted.include?(uri.origin)
            [key, uri]
          end
        else
          %w[authorization_endpoint token_endpoint userinfo_endpoint].to_h { |key| [key, endpoint_uri(@provider.public_send(key))] }
        end
      rescue KeyError, ArgumentError, URI::Error
        raise ProtocolError, cause: nil
      end

      def endpoint_uri(value)
        uri = URI.parse(value.to_s)
        permitted = uri.scheme == "https" || (Rails.env.local? && uri.scheme == "http")
        raise ProtocolError unless permitted && uri.host.present? && !uri.userinfo && !uri.fragment
        uri
      end

      def verified_claims(token, attempt)
        keys = Http.json("GET", endpoints.fetch("jwks_uri"))
        claims, = JWT.decode(token, nil, true, algorithms: SIGNING_ALGORITHMS, jwks: keys,
          iss: @provider.issuer, verify_iss: true, aud: @provider.client_id, verify_aud: true,
          verify_iat: true, required_claims: %w[iss sub aud iat exp nonce])
        audiences = Array(claims.fetch("aud"))
        if audiences.length > 1 || claims.key?("azp")
          raise ProtocolError unless claims["azp"] == @provider.client_id
        end
        raise ProtocolError unless claims.fetch("nonce") == attempt.nonce
        if attempt.purpose == "reauth"
          auth_time = claims.fetch("auth_time")
          raise ProtocolError unless (5.minutes.ago.to_i..Time.now.to_i).cover?(auth_time)
        end
        claims
      end

      def user_info(token)
        Http.json("GET", endpoints.fetch("userinfo_endpoint"), headers: { "authorization" => "Bearer #{token}" })
      end

      def field(info, path)
        info.dig(*path.split(".")) if path.present?
      end

      def profile(subject, email, verified, name, admitted)
        subject = String.try_convert(subject)
        mail = String.try_convert(email)
        name = String.try_convert(name)
        # JSON strings can contain U+0000. PostgreSQL text cannot store it.
        if [subject, mail, name].compact.any? { |value| !value.valid_encoding? || value.include?("\0") }
          raise ProtocolError
        end
        raise ProtocolError if subject.blank? || subject.bytesize > 255

        mail = mail&.strip&.downcase.presence
        mail = nil unless mail && mail.bytesize <= Identity::EMAIL_MAX_LENGTH && URI::MailTo::EMAIL_REGEXP.match?(mail)
        name = name.to_s.first(User::DISPLAY_NAME_MAX_LENGTH).presence
        Profile.new(subject: subject, email: mail, email_verified: mail.present? && verified == true, name: name, admitted: admitted)
      end
  end
end
