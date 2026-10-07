module CybrosAgent
  module Api
    # One Workspace's nested InferenceRequest surface: a single direct model call, from
    # the Agent's side.
    #
    # CREATION IS ASYNCHRONOUS BY CONTRACT. The server answers 202 with a
    # queued resource and the answer arrives later, so `create` returns
    # something unfinished and it is the caller's job to follow it — by
    # polling `fetch`, or by reading `events`, which is the durable replay
    # window a stream consumer resumes from. There is no blocking spelling
    # here: hiding a poll loop inside a method would hide the deadline, the
    # backoff and the rate limit from the only code that can choose them.
    #
    # `workload` is a member of the payload rather than a lane of its own —
    # one resource, five workloads.
    class InferenceRequestsContext
      include InferenceRequestProjections
      include Fields

      attr_reader :workspace_public_id

      def initialize(dispatch:, workspace_public_id:)
        @dispatch = dispatch
        @workspace_public_id = required_string_snapshot(workspace_public_id, "workspace_public_id")
      end

      def list(workload: nil, after: nil, limit: nil)
        page(InferenceRequestSummary, @dispatch.call(path, params: query(workload:, after:, limit:)), "inference_requests")
      end

      # Estimate the submitted text locally against the currently selected
      # model. This creates no InferenceRequest and contacts no Provider; callers may
      # use the result to compact or trim before `create`.
      def estimate_input(workload:, model:, input:,
                         reasoning_effort: UNSET, reasoning_enabled: UNSET, configuration: UNSET,
                         upload_public_ids: UNSET)
        fields = input_fields(
          workload: workload, model: model, input: input,
          reasoning_effort: reasoning_effort, reasoning_enabled: reasoning_enabled, configuration: configuration,
          upload_public_ids: upload_public_ids
        )

        answer = @dispatch.call(
          "#{path}/input_estimate",
          method: :post,
          body: { "input_estimate" => fields }
        )
        shape(InferenceRequestInputEstimate, answer, "input_estimate")
      end

      # Creation demands the caller's own Idempotency-Key — the SDK never
      # silently mints one, because a retry that the caller cannot recognize
      # as a retry is how one prompt becomes two bills.
      #
      # A REPLAY IS A 200, NOT A 202, so both are accepted here: an exact
      # repeat returns the standing resource rather than refusing, which is
      # the whole point of the receipt. `replayed?` on the answer is how a
      # caller tells the two apart when it matters.
      def create(workload:, model:, input:, idempotency_key:,
                 reasoning_effort: UNSET, reasoning_enabled: UNSET, configuration: UNSET,
                 upload_public_ids: UNSET, billing_subject: UNSET)
        required_string(idempotency_key, "idempotency_key")
        body = input_fields(
          workload: workload, model: model, input: input,
          reasoning_effort: reasoning_effort, reasoning_enabled: reasoning_enabled, configuration: configuration,
          upload_public_ids: upload_public_ids
        ).merge(fields(billing_subject:))

        accepted(
          @dispatch.call_accepting(
            path,
            method: :post,
            body: { "inference_request" => body },
            headers: { "Idempotency-Key" => idempotency_key },
            success: [202, 200]
          )
        )
      end

      def fetch(public_id)
        shape(InferenceRequest, @dispatch.call(inference_request_path(public_id)), "inference_request")
      end

      # The durable replay window: strictly after `after`, ascending. The limit
      # is a hard reject on the server rather than a clamp, so asking for more
      # than it serves raises instead of quietly returning less.
      def events(public_id, after: nil, limit: nil)
        shape(InferenceRequestEventPage, @dispatch.call("#{inference_request_path(public_id)}/events", params: query(after:, limit:)))
      end

      # Total and idempotent: cancelling work that already finished matches
      # nothing and answers the standing state, so a caller racing a terminal
      # transition never has to handle a refusal it cannot prevent.
      def cancel(public_id)
        answer = @dispatch.call("#{inference_request_path(public_id)}/cancellation", method: :post, success: 200)
        shape(InferenceRequest, answer, "inference_request")
      end

      # FOLLOWING A RUN, done correctly, without having to know how.
      #
      # The events endpoint is the authority and this wires it into the pump
      # that drains it properly — a frozen head per pass, dedupe by sequence,
      # a position that advances only after the caller's block returns. With
      # no `subscribe:` it needs no socket at all, which is a supported way to
      # use this API rather than a lesser one.
      #
      # `limit` is the page size, not a bound on what arrives: the feed pages
      # until it reaches the head it froze.
      # `realtime:` is a shared `Realtime::Client`; give it one and the feed
      # opens a logical subscription on that client's multiplexed socket.
      # Leave it out and the feed is a REST follower, which is complete.
      #
      # The channel, its params and the projection are all THIS resource's
      # knowledge, which is why the socket is wired here rather than by the
      # caller: a consumer assembling those by hand is one typo away from a
      # subscription that confirms and delivers nothing.
      def feed(public_id, position: KernelFeed::Position.start, limit: nil,
               realtime: nil, items: nil, **options)
        KernelFeed.new(
          replay: ->(cursor) { events(public_id, after: cursor, limit: limit) },
          subscribe: realtime && realtime_opener(public_id, realtime, items: items),
          position: position,
          **options
        )
      end

      # THE CALLABLE A FEED SUBSCRIBES THROUGH, public because attaching a
      # socket is a decision a consumer makes over time rather than once. A
      # follower that started without one — because nobody was looking at this
      # run — hands the result of this to `KernelFeed#attach` when someone is,
      # and the pump re-enters through its usual barrier.
      # `items: "lifecycle"` narrows the subscription to where the run GOT TO —
      # `run_status` and `result` — for a consumer that is not reading the
      # output and only needs to know when it finished. The narrowing is a
      # different broadcasting on the server, so an uninterested subscriber
      # receives nothing rather than filtering deltas it will discard.
      def realtime_opener(public_id, client, items: nil)
        params = { workspace_id: @workspace_public_id, inference_request_id: public_id }
        params[:items] = items unless items.nil?
        Realtime::FeedSubscription.opener(
          client: client,
          channel: EVENTS_CHANNEL,
          params: params,
          # The same projection the replay page applies, so an item is the
          # same object whichever transport carried it.
          event: ->(message) { shape(InferenceRequestEvent, message, "event") }
        )
      end

      # THE BYTES A NON-TEXT WORKLOAD PRODUCED, streamed through the API rather
      # than fetched from storage: `index` is the ordinal from
      # `result.files`, and the answer is the file itself as a binary String.
      #
      # No `to_file` convenience and no streaming block, deliberately — where
      # the bytes go is the caller's decision, and a gem that guessed would
      # have to guess about filenames, overwrites and partial writes too.
      def download(public_id, index)
        @dispatch.download("#{inference_request_path(public_id)}/files/#{Integer(index)}")
      end

      # Delete is a TERMINAL-ONLY tombstone, not a cancel: running work refuses
      # with Conflict and is expected to be cancelled first. Cleanup never
      # stops anything on the caller's behalf.
      def delete(public_id)
        @dispatch.call(inference_request_path(public_id), method: :delete, success: 204)
        nil
      end

      EVENTS_CHANNEL = "AgentAPI::V1::InferenceRequestEventsChannel".freeze

      private

        def input_fields(workload:, model:, input:, reasoning_effort:, reasoning_enabled:,
                         configuration:, upload_public_ids:)
          fields(
            workload:, model: fields(model:, reasoning_effort:, reasoning_enabled:), input:, configuration:,
            upload_public_ids:
          )
        end

        def accepted(result)
          Accepted.new(inference_request: shape(InferenceRequest, result.body, "inference_request"), replayed: result.status == 200)
        end

        def path
          "#{Workspaces::PATH}/#{path_segment(@workspace_public_id, "workspace_public_id")}/inference_requests"
        end

        def inference_request_path(public_id)
          "#{path}/#{path_segment(public_id, "public_id")}"
        end

      # What `create` answers: the queued resource, and whether the server
      # recognized this Idempotency-Key from an earlier request. It delegates
      # the InferenceRequest's own readers so the common case reads as one object.
      Accepted = Data.define(:inference_request, :replayed) do
        def replayed? = replayed

        def public_id = inference_request.public_id
        def status = inference_request.status
        def workload = inference_request.workload
        def model = inference_request.model
        def finished? = inference_request.finished?
      end
    end
  end
end
