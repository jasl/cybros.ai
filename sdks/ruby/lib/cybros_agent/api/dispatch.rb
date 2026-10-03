module CybrosAgent
  module Api
    # Credential-bearing transport dispatch is deliberately an internal
    # collaborator. Public clients expose only typed resources for their
    # authority plane; they never become a raw path client that can be pointed
    # at another API family.
    class Dispatch
      def initialize(credential_provider:, transport:, request_timeout:)
        @credential_provider = credential_provider
        @transport = transport
        @request_timeout = request_timeout
      end

      # One request on this plane: the credential attached, the failure ladder
      # applied, the endpoint's expected success status enforced, and the
      # parsed body returned. Only typed resources receive this object.
      def call(path, method: :get, body: nil, form: nil, params: nil, headers: {}, success: 200)
        call_accepting(
          path, method: method, body: body, form: form, params: params, headers: headers,
          success: success
        ).body
      end

      # THE SAME REQUEST, WITH THE STATUS KEPT. A few endpoints answer with
      # more than one success status and the status itself is the answer: a
      # OneShot create is 202 when it accepted new work and 200 when it
      # recognized the Idempotency-Key from an earlier one, and a caller that
      # cannot tell those apart cannot tell whether it just spent money.
      # `call` above is this method with the status thrown away.
      def call_accepting(path, method: :get, body: nil, form: nil, params: nil, headers: {},
                         success: 200)
        expected = Array(success)
        # `form:` IS PASSED ONLY WHEN THERE IS ONE. A transport is somebody
        # else's object — this is a published duck — and one written before
        # uploads existed answers no such keyword. Sending it unconditionally
        # would break every custom transport in the world to serve the one
        # call that uploads; sending it only when a caller uploads means only
        # an uploading caller needs a transport that understands it.
        call = {
          method: method, credential: @credential_provider.call, body: body, params: params,
          headers: headers, timeout: @request_timeout,
        }
        call[:form] = form unless form.nil?
        response = @transport.call(path, **call)
        if expected.include?(response.status)
          Answer.new(status: response.status, body: response.body, replayed: response.idempotency_replayed?)
        elsif (200..299).cover?(response.status)
          raise MalformedResponse,
            "expected status #{expected.join(" or ")}, got #{response.status}"
        else
          raise failure(response)
        end
      end

      # BYTES, NOT STRUCTURE. The failure ladder is the same one every other
      # read answers to — a 404 for a file that is not there is still NotFound —
      # but the success is the file itself rather than a parsed envelope.
      # With a `sink:` the bytes stream INTO it (the transport's own
      # streaming, passed only when a caller streams) and the answer is the
      # transport's Response — its status and headers, no body: the
      # attachment reads project the status and the ETag from it; `success`
      # names the statuses a caller accepts — a `Range` read is 206, never
      # 200, and a conditional read accepts the 304 it asked for.
      def download(path, headers: {}, sink: nil, success: 200)
        call = { credential: @credential_provider.call, timeout: @request_timeout, accept: ANY_MEDIA, headers: headers }
        call[:sink] = sink unless sink.nil?
        response = @transport.call(path, **call)
        return sink.nil? ? response.body.to_s : response if Array(success).include?(response.status)
        # A 200 where 206 was asked for is a server that ignored the Range,
        # a 304 where no tag was sent is a server answering a condition
        # nobody set: malformed for THIS request, never silently a whole
        # file and never an empty one.
        raise MalformedResponse, "expected status #{Array(success).join(" or ")}, got #{response.status}" if
          (200..299).cover?(response.status) || response.status == 304

        raise failure(response)
      end

      include Redacted

      def inspect = redacted(hidden: %i[credential])

      private

        # The envelope's three facts ride every typed failure: the code, the
        # message, and the members beside them (`details`) — so an extended
        # envelope reaches the caller whole, never trimmed to two keys.
        def failure(response)
          code = error_code(response)
          details = error_details(response)
          case response.status
          when 401 then Unauthorized.new("credential not accepted on this plane", code: code, details: details)
          when 403 then Forbidden.new(error_message(response), code: code, details: details)
          when 404 then NotFound.new(code: code, details: details)
          when 409 then Conflict.new(error_message(response), code: code, details: details)
          when 413 then ContentTooLarge.new(error_message(response), code: code, details: details)
          when 429
            RateLimited.new(retry_after: response.retry_after, code: code || "rate_limited", details: details)
          when 400..499 then InvalidRequest.new(error_message(response), code: code, details: details)
          else ServerError.new("server failure (status #{response.status})", code: code, details: details)
          end
        end

        def error_envelope(response)
          body = response.body
          return {} unless body.is_a?(Hash)

          error = body["error"]
          error.is_a?(Hash) ? error : {}
        end

        def error_code(response)
          value = error_envelope(response)["code"]
          value if value.is_a?(String) && !value.empty?
        end

        def error_message(response)
          value = error_envelope(response)["message"]
          value if value.is_a?(String) && !value.empty?
        end

        ENVELOPE_KEYS = %w[code message].freeze

        def error_details(response)
          error_envelope(response).reject { |key, _value| ENVELOPE_KEYS.include?(key) }
        end
    end

    # A success whose status or receipt replay matters. Deliberately not a public projection —
    # it is what one private collaborator hands another.
    Answer = Data.define(:status, :body, :replayed)

    private_constant :Dispatch
    private_constant :Answer
  end
end
