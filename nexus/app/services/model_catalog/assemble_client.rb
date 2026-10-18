module ModelCatalog
  # The catalog's final output is a configured `SimpleInference::Client`: profile + endpoint +
  # credential. A host that keeps the wire is a catalog fact; one that changes it is transport
  # work, never composition.
  module AssembleClient
    # The codex backend's consumer headers (codex-rs pin 883af106): the
    # credential's account id (bearer_auth_provider.rs, only for `Some`),
    # the request's own id and the cache-affinity pair keyed on the prompt
    # cache key (codex-api/src/endpoint/responses.rs, requests/headers.rs).
    # Every one is a CONSUMER fact the gem's Config headers carry and merge
    # at execution; the protocol emits only its body-derived markers.
    ACCOUNT_HEADER = "ChatGPT-Account-ID".freeze
    SESSION_HEADER = "session-id".freeze
    THREAD_HEADER = "thread-id".freeze
    REQUEST_HEADER = "x-client-request-id".freeze
    CODEX_LANE = "codex_responses".freeze

    class << self
      # `credential` is the row the start claim validated, used by reference;
      # `host` picks the process-wide adapter; `streaming` decides the idle
      # bound; `invocation` is the row being sent, nil for a compile without one.
      def call(profile:, base_url:, credential:, host:, streaming:, invocation: nil)
        SimpleInference::Client.new(
          execution_profile: profile,
          base_url: base_url,
          adapter: ModelInvocations::ExecutionAdapter.for(host),
          # Both axes, from the lane's own declaration. The total bounds the
          # exchange; the idle bound is what makes a provider that accepts
          # and then goes silent cost seconds instead of the whole deadline.
          timeout: profile.total_execution_deadline_seconds,
          **idle_bound(profile, streaming),
          **credential_options(credential),
          headers: consumer_headers(profile, credential, invocation)
        )
      end

      private

        # Only a stream carries the idle bound: a unary call is one
        # indivisible exchange bounded by its total deadline.
        def idle_bound(profile, streaming)
          streaming ? { read_timeout: profile.stream_idle_timeout_seconds } : {}
        end

        # The gem spells each lane's credential header itself; a
        # credentialless lane passes nothing rather than an empty string.
        def credential_options(credential)
          secret = credential&.secret
          secret.present? ? { api_key: secret } : {}
        end

        # The codex lane alone: every other wire carries none of these,
        # and a compile without a credential or an invocation carries none.
        def consumer_headers(profile, credential, invocation)
          return {} unless profile.adapter_profile == CODEX_LANE

          account_header(credential).merge(invocation_headers(invocation))
        end

        # Mirrors codex exactly: the header rides when the token carried
        # the `chatgpt_account_id` claim, and is omitted — never failed
        # closed — when it did not.
        def account_header(credential)
          return {} unless codex_credential?(credential)

          identity = credential.provider_account_identity
          identity.present? ? { ACCOUNT_HEADER => identity } : {}
        end

        def codex_credential?(credential)
          credential.present? &&
            credential.provider_id == ModelProviders::CodexAuthorization::PROVIDER_ID &&
            credential.material_kind == "oauth_tokens"
        end

        # "ChatGPT derives cache affinity from the Responses session-id
        # header" (client.rs): session = thread = the prompt cache key
        # Build also sends in the body; the request id is the invocation's.
        def invocation_headers(invocation)
          return {} if invocation.nil?

          key = invocation.prompt_cache_key
          affinity = key.nil? ? {} : { SESSION_HEADER => key, THREAD_HEADER => key }
          affinity.merge(REQUEST_HEADER => invocation.public_id)
        end
    end
  end
end
