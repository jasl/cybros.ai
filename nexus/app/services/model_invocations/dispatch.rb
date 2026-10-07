module ModelInvocations
  # The send: connection context and IO for the one request compiled before
  # the claim. It records rather than concludes — the HTTP client's verdict
  # is the answer (no proof machinery).
  class Dispatch
    SENT = :sent

    # What the send hands settlement and never stores on the Attempt: the two
    # measurements only a live send can take.
    Timing = Data.define(:started_monotonic, :first_token_monotonic, :finished_monotonic) do
      def duration_ms = (finished_monotonic - started_monotonic).in_milliseconds.round
      def time_to_first_token_ms
        return if first_token_monotonic.nil?

        (first_token_monotonic - started_monotonic).in_milliseconds.round
      end
    end

    # `result` is present exactly when the provider succeeded, `error`
    # otherwise — the adapter's own exception class is the whole record of
    # what the client did; `profile` is retained only for terminal apply and
    # settlement.
    Result = Data.define(:outcome, :result, :error, :timing, :profile, :request_id) do
      def sent? = outcome == SENT
      def succeeded? = !result.nil?
    end

    # NOT the house `(...)` forward: that spelling hands the block to `new`
    # and the chained `.call` never sees it — the per-event seam existed for
    # a whole package while `block_given?` stayed false (item-5 catch).
    def self.call(**kwargs, &block) = new(**kwargs).call(&block)

    # `context` is the ephemeral send context the start claim returned;
    # `request` the CompiledRequest built before that claim.
    def initialize(attempt:, context:, request:)
      @attempt = attempt
      @context = context
      @request = request
    end

    def call
      started = monotonic
      first_token = nil

      # The pool sizes for state-transition bursts, not in-flight streams, so
      # the lease is released before provider IO; inside an open transaction
      # there is nothing safe to release.
      release_database_connections

      result =
        if @request.stream?
          stream = client.execute(@request)
          stream.each do |event|
            # First token, not first event: administrative frames arrive
            # before any token, and the column means tokens.
            first_token ||= monotonic if token_bearing?(event)
            yield event if block_given?
          end
          stream.final_result
        else
          client.execute(@request)
        end

      record(result: result, response: result.provider_response, timing: timing(started, first_token))
    rescue SimpleInference::HTTPError => e
      # The provider ANSWERED — with a refusal, but an answer is an answer,
      # and it carries the response the request id is read from.
      record(error: e, response: e.response, timing: timing(started, first_token))
    rescue SimpleInference::Error => e
      record(error: e, timing: timing(started, first_token))
    end

    private

      def release_database_connections
        return if ApplicationRecord.connection_pool.active_connection?&.transaction_open?

        ApplicationRecord.connection_handler.clear_active_connections!
      end

      def record(result: nil, error: nil, response: nil, timing:)
        Result.new(outcome: SENT, result: result, error: error, timing: timing,
                   profile: @context.profile, request_id: request_id(response))
      end

      # Absent is a truthful answer. Bounded at the column's width: the
      # header is wire-controlled, and one hostile header costs its tail,
      # never the apply of an observed response.
      REQUEST_ID_LIMIT = 128

      def request_id(response)
        headers = response&.headers || {}
        value = headers["x-request-id"] || headers["X-Request-Id"] || headers["request-id"]
        return nil if value.nil?

        # Scrubbed as well as sliced: obs-text bytes crash the UTF-8 column,
        # and NUL is valid UTF-8 PostgreSQL still refuses. An all-garbage
        # header is an absent one.
        value.dup.force_encoding(Encoding::UTF_8).scrub("").delete("\u0000")
          .slice(0, REQUEST_ID_LIMIT).presence
      end

      # The context is the same bounded value returned by the start claim.
      def client
        @client ||= ModelCatalog::AssembleClient.call(
          profile: @context.profile,
          base_url: @context.base_url,
          credential: @context.credential,
          host: @context.host,
          streaming: @request.stream?,
          invocation: @attempt.model_invocation
        )
      end

      def token_bearing?(event)
        case event
        when SimpleInference::Responses::Events::TextDelta,
             SimpleInference::Responses::Events::ReasoningDelta
          true
        else
          false
        end
      end

      def timing(started, first_token)
        Timing.new(started_monotonic: started, first_token_monotonic: first_token,
                   finished_monotonic: monotonic)
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
