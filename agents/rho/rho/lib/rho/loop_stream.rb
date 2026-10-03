module Rho
  # ONE LOOP'S EVENTS, PUSHED. `rho watch` polls the daemon's own snapshot,
  # which is fine for a terminal redrawing a table — and wrong for a page
  # that wants a round's text as it arrives. This is the same events the
  # follower already receives, handed on as they land.
  #
  # SERVER-SENT EVENTS, deliberately, over a WebSocket: the frames only
  # ever travel one way, it needs no new dependency and no upgrade
  # handshake, and it authenticates exactly like every other control route
  # — a bearer header. That last point is why the browser client is
  # `fetch` and a reader rather than `EventSource`, which cannot set a
  # header and would leave this host's shell-granting bearer in a URL.
  #
  # BOUNDED, AND THE SLOW READER LOSES. A consumer that stops reading must
  # not grow the daemon's memory: past the queue's depth the stream closes
  # with a final frame saying so, and the reader reconnects — the durable
  # answer was always the trace, and this is latency sugar over it.
  class LoopStream
    HEARTBEAT_SECONDS = 20
    # THE SETTLE'S GRACE. A host's two feeds end
    # independently: the events feed says the turn is over, the transcript
    # feed delivers what it said. Closing on the first alone ended readers
    # before the reply reached them, so a settled turn is given this long for
    # its transcript half — and never longer, because a settle that is not
    # coming (a lost tail, a host that never streamed) must not hold a
    # terminal open.
    SETTLE_GRACE_SECONDS = 5
    SETTLE_POLL_SECONDS = 0.25

    attr_reader :body

    # THE RESPONSE ALWAYS CARRIES THE REAL BODY; `sink` only redirects
    # where frames are WRITTEN. It is injectable for one reason: the
    # failure path here is "the peer went away", which is only ever
    # observed as a write raising — and a test that has to arrange a real
    # broken socket to see it is a test nobody keeps.
    def initialize(public_id:, log: nil, sink: nil)
      @public_id = public_id
      @log = log
      @body = Protocol::HTTP::Body::Writable.new
      @sink = sink || @body
      @open = true
      @mutex = Mutex.new
    end

    def response
      Protocol::HTTP::Response[200, {
        "content-type" => "text/event-stream",
        # A proxy that buffered this would defeat the point; nothing is
        # cacheable and nothing should be transformed.
        "cache-control" => "no-cache, no-transform",
        "x-accel-buffering" => "no",
      }, @body]
    end

    # ONE EVENT, ONE FRAME. `type` becomes the SSE event name so a browser
    # can add one listener per kind, and the payload is the same JSON the
    # follower saw.
    def deliver(type, payload)
      write("event: #{type}\ndata: #{JSON.generate(payload)}\n\n")
    end

    # A COMMENT FRAME, which SSE ignores: it exists so a dead peer is
    # discovered by a write failing rather than by nothing ever happening
    # on a quiet loop.
    def heartbeat = write(": keep-alive\n\n")

    def close(reason = nil)
      @mutex.synchronize do
        return unless @open

        @open = false
        begin
          @sink.write("event: closed\ndata: #{JSON.generate(reason: reason)}\n\n") if reason
          # `close_write`, NEVER `close`: a Writable body DISCARDS whatever
          # is still queued when it is closed, so ending a settled loop
          # that way throws away the frames the reader has not drained yet
          # — the last round's text and this very goodbye among them.
          @sink.close_write
        rescue StandardError
          nil
        end
      end
    end

    def open? = @mutex.synchronize { @open }

    private

      def write(frame)
        @mutex.synchronize do
          return false unless @open

          # `Writable#write` raises once the peer is gone; that is the only
          # signal a stream gets that nobody is reading, and it must end
          # the stream rather than the daemon.
          @sink.write(frame)
          true
        rescue StandardError => error
          @open = false
          @log&.info("loop_stream.closed", agent_loop: @public_id,
            error_class: error.class.name)
          false
        end
      end
  end
end
