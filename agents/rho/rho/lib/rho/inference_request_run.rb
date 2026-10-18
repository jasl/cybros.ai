require "monitor"
# The socket half of the SDK is opt-in and consumer-supplied; rho declares
# `async-websocket` itself and requires it beside the files that need it.
require "cybros_agent/realtime"

module Rho
  # One run this daemon placed and what following it has learned. Deltas are
  # the live preview; the terminal item is only a wake to fetch the
  # authoritative InferenceRequest. Followers on the reactor, read under one monitor.
  class InferenceRequestRun
    # One second is the API's guidance for a single followed run. REST also
    # bounds terminal detection when an open socket loses its last wake.
    POLL_SECONDS = 1.0

    # The narrowing a run subscribes to while nobody is reading its output.
    LIFECYCLE_ITEMS = "lifecycle".freeze

    # `text` is a preview until terminality, then the authoritative output;
    # `result` is nil until terminal; `live` false means lifecycle-only, not
    # disconnected — both subscriptions may ride the one shared socket.
    Snapshot = Data.define(:public_id, :status, :text, :sequence, :complete, :result, :live) do
      def to_h
        { public_id: public_id, status: status, text: text, sequence: sequence,
          complete: complete, result: result, live: live }
      end
    end

    attr_reader :public_id, :realtime

    # Not watching is not not listening: a run nobody reads still subscribes
    # to the LIFECYCLE narrowing on the daemon's shared socket. The result
    # follower reads REST independently of whether this subscription is quiet.
    def initialize(inference_requests:, public_id:, realtime: nil, live: true, logger: nil,
                   sleeper: ->(seconds) { sleep(seconds) })
      @public_id = public_id
      @logger = logger
      @inference_requests = inference_requests
      @realtime = realtime
      @live = live && !realtime.nil?
      @feed = inference_requests.feed(
        public_id, realtime: realtime, items: (@live ? nil : LIFECYCLE_ITEMS)
      )
      @sleeper = sleeper
      @monitor = Monitor.new
      @text = +""
      @status = "queued"
      @complete = false
      @result = nil
      @stopped = false
    end

    def inference_request? = true

    def host? = false

    # A one-shot backs no turn; its own id is the lineage's direct answer.
    def backs?(_public_id) = false

    # The one door a follower is started through, the same verb its run
    # sibling answers.
    def start(spawner)
      spawner.call { follow }
      spawner.call { follow_result }
      self
    end

    # One pass is a full barrier with no socket (the sleep is the latency);
    # with one it stays live until the terminal item, and a feed that spent
    # its transient budget on a down kernel is resurrected by the next pass.
    def follow
      until stopped_or_complete?
        begin
          @feed.each { |event| apply(event) }
        rescue *CybrosAgent::KernelFeed::TRANSIENT_ERRORS => error
          # A terminal wake may win a brief GET failure. The feed did not
          # advance its position because apply raised, so the next pass asks
          # for the same durable event and fetches again.
          @sleeper.call(error.retry_after || POLL_SECONDS)
          next
        end
        break if stopped_or_complete?

        @sleeper.call(POLL_SECONDS)
      end
      self
    rescue StandardError => error
      # Fire-and-forget: without this line a dead follower is a turn that
      # looks like it is still working.
      @logger&.warn("inference_request.follow_failed", inference_request: @public_id,
                    error_class: error.class.name,
                    error: CybrosAgent::Redaction.call(error.message))
      raise
    ensure
      stop
    end

    # No later event can expose a missing final frame as a sequence gap.
    # Poll the authoritative resource alongside the feed, on its same cadence.
    def follow_result
      until stopped_or_complete?
        begin
          inference_request = @inference_requests.fetch(@public_id)
          result = inference_request.result
          commit_result(inference_request, result) unless result.nil?
        rescue *CybrosAgent::KernelFeed::TRANSIENT_ERRORS => error
          @sleeper.call(error.retry_after || POLL_SECONDS) unless stopped_or_complete?
          next
        end
        break if stopped_or_complete?

        @sleeper.call(POLL_SECONDS)
      end
      self
    rescue StandardError => error
      @logger&.warn("inference_request.result_follow_failed", inference_request: @public_id,
                    error_class: error.class.name,
                    error: CybrosAgent::Redaction.call(error.message))
      raise
    ensure
      stop
    end

    # The output subscription follows attention: attaching re-enters the SDK's
    # barrier so a lifecycle-only follower hands over everything that landed;
    # detaching keeps the durable position. Both answer whether they changed anything.
    def attach_socket
      return false if @realtime.nil? || @monitor.synchronize { @live }

      @feed.detach
      return false unless @feed.attach(@inference_requests.realtime_opener(@public_id, @realtime))

      @monitor.synchronize { @live = true }
      true
    end

    def detach_socket
      return false unless @monitor.synchronize { @live }

      @feed.detach
      @feed.attach(@inference_requests.realtime_opener(@public_id, @realtime, items: LIFECYCLE_ITEMS))
      @monitor.synchronize { @live = false }
      true
    end

    # Called on the owning control reactor: stopping a live logical
    # subscription reaches the shared Async client. Snapshot reads remain
    # monitor-protected for control callers on other threads.
    def stop
      @monitor.synchronize { @stopped = true }
      @feed.stop
      self
    end

    def snapshot
      @monitor.synchronize do
        Snapshot.new(public_id: @public_id, status: @status, text: @text.dup,
                     sequence: @feed.position.sequence, complete: @complete,
                     result: @result, live: @live)
      end
    end

    private

      def stopped_or_complete? = @monitor.synchronize { @stopped || @complete }

      # An event type this daemon predates advances the position and means
      # nothing here; `rollback` is not in that class — it says reset and
      # replay, or a retry's answer concatenates onto the discarded half.
      def apply(event)
        return finish if event.type == "result"

        @monitor.synchronize do
          return if @stopped || @complete

          case event.type
          when "text_delta"
            text = event.payload["text"]
            @text << text unless text.nil?
          when "rollback" then @text.clear
          when "run_status"
            status = event.payload["status"]
            @status = status unless status.nil?
          else nil
          end
        end
      end

      # The run stops its own feed here: a subscribed pump would hold the
      # socket forever. The event is a wake, not the result — the resource
      # holds the full projection, which does not belong in a broadcast.
      def finish
        return if stopped_or_complete?

        inference_request = @inference_requests.fetch(@public_id)
        result = inference_request.result
        if result.nil?
          raise CybrosAgent::Api::MalformedResponse,
            "terminal event for #{@public_id} preceded its authoritative result"
        end

        commit_result(inference_request, result)
      end

      def commit_result(inference_request, result)
        @monitor.synchronize do
          return if @stopped || @complete

          @status = result.status
          @result = result.to_h
          @text = +inference_request.output_text.to_s
          @complete = true
        end
        @feed.stop
      end
  end
end
