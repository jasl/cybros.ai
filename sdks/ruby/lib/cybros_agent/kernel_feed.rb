module CybrosAgent
  # ONE ORDERED, AT-LEAST-ONCE STREAM OF A RESOURCE'S DURABLE EVENTS.
  #
  # The durable replay window is the authority and the socket is an
  # accelerator that may miss, duplicate, or reorder — so following a run
  # correctly is not "subscribe and apply what arrives". It is a barrier:
  #
  #   drain to a frozen head → subscribe → drain the gap → live
  #
  # and the same sequence again after every disconnect. Nothing here treats
  # one page, or a subscribe confirmation, as proof that the gap is closed.
  #
  # THE SOCKET IS OPTIONAL AND THAT IS THE POINT. With `subscribe: nil` this
  # is a REST follower that needs no websocket at all, which is both a
  # supported way to use the API and what makes the pump testable without
  # one. A consumer that never subscribes still gets every durable event, in
  # order, exactly through the code path a subscribing one uses.
  #
  # BOTH SIDES ARE INJECTED, as ducks:
  #   replay:    callable(after_cursor) → a page responding to `items`,
  #              `next_after` and `watermark`. Items respond to `sequence`
  #              and `cursor`. `CybrosAgent::Api::OneShotEventPage` is one.
  #   subscribe: callable() → a subscription responding to `each` (yielding
  #              `{"event" => …}` frames and raising
  #              `Realtime::ConnectionLostError` on loss) and `unsubscribe`.
  #
  # AT LEAST ONCE, BY CONSTRUCTION: the position advances only after the
  # consumer's block returns, so a crash mid-handler replays that event.
  # Consumers must project idempotently — by event `public_id`, which is
  # stable across both transports.
  class KernelFeed
    # A resumable place in a stream. It carries BOTH values because the wire
    # has both and they do different jobs: the cursor is opaque and is handed
    # back to a replay read, the sequence is what orders and dedupes. Keeping
    # them in one object is what stops a caller persisting one and inventing
    # the other — inventing the cursor from the sequence would mean encoding
    # it, which is the hidden contract the server publishes the sequence to
    # make unnecessary.
    Position = Data.define(:cursor, :sequence) do
      def self.start = new(cursor: nil, sequence: 0)
    end

    # Transient survival for a kernel blip during a deploy or a restart. The
    # budget is spent per pump, and exhaustion ends the pump CLEANLY rather
    # than raising out of it — a supervisor restarts a finished feed, and a
    # fire-and-forget task that dies with an exception tells nobody.
    DEFAULT_MAX_TRANSIENT_RETRIES = 8
    DEFAULT_RETRY_BACKOFF_SECONDS = 0.5
    DEFAULT_MAX_BACKOFF_SECONDS = 5.0

    # ONLY THESE ARE WORTH RETRYING. The predecessor retried every
    # `CybrosAgent::Error`, which spends the whole budget on a 404 that will
    # answer 404 eight more times. A refusal is an answer; a transport failure
    # is a missing one.
    TRANSIENT_ERRORS = [
      TransportError, Api::RateLimited, Api::ServerError,
    ].freeze

    # Subscribing can fail transiently in a way a REST read cannot: the socket
    # never came up. A REJECTION is deliberately not in this set — the server
    # said no, and it will say no again, so it travels out to the caller
    # instead of being spent against a retry budget.
    TRANSIENT_SUBSCRIBE_ERRORS = (TRANSIENT_ERRORS + [Realtime::ConnectionLostError]).freeze

    # Feed transport failures and a consumer raising the same typed SDK error
    # are different facts. This private wrapper carries the latter through the
    # feed's own retry rescue so the caller sees its original exception and
    # the event remains uncommitted.
    class ConsumerFailure < StandardError
      attr_reader :error

      def initialize(error)
        @error = error
        super(error.message)
      end
    end
    private_constant :ConsumerFailure

    attr_reader :position

    def initialize(replay:, subscribe: nil, position: Position.start, after_replay: nil,
                   sleeper: ->(seconds) { sleep(seconds) },
                   max_transient_retries: DEFAULT_MAX_TRANSIENT_RETRIES,
                   retry_backoff: DEFAULT_RETRY_BACKOFF_SECONDS,
                   max_backoff: DEFAULT_MAX_BACKOFF_SECONDS)
      @replay = replay
      @subscribe = subscribe
      @position = position
      @after_replay = after_replay
      @stopped = false
      @subscription = nil
      @subscription_generation = 0
      @subscription_mutex = Mutex.new
      @sleeper = sleeper
      @max_transient_retries = max_transient_retries
      @retry_backoff = retry_backoff
      @max_backoff = max_backoff
    end

    # Blocking consumption. Returns when `stop` is called, when the stream is
    # drained and there is no subscription to wait on, or when the transient
    # budget is spent — never by raising a transport failure at the caller.
    def each(&block)
      drain_with_retry(&block)
      return self if subscription_intent.first.nil?

      loop do
        subscribe, generation = subscription_intent
        # DETACHED WHILE RUNNING. The pump leaves rather than dying: a drained
        # feed with no socket is exactly the REST follower this class starts
        # as, and the caller's own loop is what keeps polling.
        break if subscribe.nil?

        subscription = with_transient_retry(TRANSIENT_SUBSCRIBE_ERRORS) { subscribe.call }
        unless install_subscription(subscription, subscribe, generation)
          subscription.unsubscribe
          next
        end

        begin
          # The gap between the drain above and the subscription being live.
          drain_with_retry(&block)
          # A clean end belongs to the current intent. Rebind, detach or a
          # detach/attach handoff changes the generation, so it ends this
          # subscription rather than the pump.
          outcome = consume_live(subscription, &block)
          break if outcome == :closed && subscription_intent_current?(subscribe, generation)
        ensure
          # Without this every resubscribe leaks a socket.
          subscription.unsubscribe
          clear_subscription(subscription)
        end
      end
      self
    rescue ConsumerFailure => failure
      raise failure.error
    rescue *TRANSIENT_SUBSCRIBE_ERRORS
      # The budget is spent. Ending quietly is deliberate: a clean `stop`
      # unwinds without raising, so a raise here would be the only difference
      # between "asked to stop" and "gave up", and callers that forget to
      # rescue would lose the distinction anyway.
      self
    end

    # ROTATION IS A PUSH, AND A SOCKET CANNOT HEAR IT. A WebSocket pins the
    # bearer it presented for the life of the connection, so a credential that
    # rotates mid-stream leaves a subscription authenticated by something the
    # server will eventually stop accepting — and the pump has no reason to
    # reconnect, because from where it stands nothing is wrong yet.
    #
    # This is that reason. It ends the CURRENT subscription without ending the
    # pump: the loop comes round, asks the credential source again — which is
    # what makes the rotated value take effect — and drains whatever the gap
    # held before going live. Losing nothing across it is the property a
    # dropped cable already exercises; this one just arrives on purpose.
    #
    # Answers false when there was nothing to rebind, so a caller sweeping
    # several followers can tell which ones were actually listening.
    def rebind
      subscription = @subscription_mutex.synchronize do
        next if @subscription.nil?

        @subscription_generation += 1
        @subscription
      end
      return false if subscription.nil?

      subscription.unsubscribe
      true
    end

    # THE SOCKET IS A DECISION THE CONSUMER CAN CHANGE, which is the whole
    # point of it being optional. A follower of many resources wants one only
    # for what someone is looking at, and both directions are free of
    # correctness cost because the replay window is the authority and the
    # position carries across.
    #
    # ATTACHING LATE COSTS NO NEW ALGORITHM. `each` re-enters through the same
    # barrier it always did — drain to a frozen head, subscribe, drain the gap,
    # go live — so a consumer that attaches after a run is half over gets what
    # already landed and then continues from where it stopped. That is the
    # sequence, not a special resume path.
    #
    # Both answer whether they changed anything, so a caller sweeping several
    # followers can tell which ones moved.
    def attach(subscribe)
      return false if subscribe.nil?

      @subscription_mutex.synchronize do
        next false if @stopped || !@subscribe.nil?

        @subscribe = subscribe
        @subscription_generation += 1
        true
      end
    end

    # Ends the pump's socket loop without ending the pump. The current
    # subscription goes through `rebind`'s door — end the subscription, not
    # the run — and the loop then finds no callable and leaves.
    def detach
      subscription, changed = @subscription_mutex.synchronize do
        next [nil, false] if @subscribe.nil?

        @subscribe = nil
        @subscription_generation += 1
        [@subscription, true]
      end
      subscription&.unsubscribe
      changed
    end

    def stop
      subscription = @subscription_mutex.synchronize do
        @stopped = true
        @subscription_generation += 1
        @subscription
      end
      subscription&.unsubscribe
      self
    end

    private

      def drain_with_retry(&block)
        with_transient_retry { drain(&block) }
      end

      # The opener does network IO and therefore never runs under this mutex.
      # Its generation is checked only after it returns: detach+attach may
      # install even the same callable again, and the counter is what prevents
      # that old in-flight opener from becoming the new subscription.
      def subscription_intent
        @subscription_mutex.synchronize do
          [@stopped ? nil : @subscribe, @subscription_generation]
        end
      end

      def install_subscription(subscription, subscribe, generation)
        @subscription_mutex.synchronize do
          next false if @stopped || !@subscribe.equal?(subscribe) ||
            @subscription_generation != generation

          @subscription = subscription
          true
        end
      end

      def clear_subscription(subscription)
        @subscription_mutex.synchronize do
          @subscription = nil if @subscription.equal?(subscription)
        end
      end

      def subscription_intent_current?(subscribe, generation)
        @subscription_mutex.synchronize do
          @stopped || (@subscribe.equal?(subscribe) && @subscription_generation == generation)
        end
      end

      def stopped?
        @subscription_mutex.synchronize { @stopped }
      end

      # ONE REST PASS, BOUNDED BY A HEAD FROZEN AT ITS FIRST PAGE.
      #
      # The predecessor drained "until a page comes back empty", which is not
      # a termination condition on a stream that is still producing — the
      # target moves as fast as the writer. Freezing the head once and paging
      # until the position reaches it is what makes this finite. Later pages
      # report a higher head; this drain deliberately ignores it, because
      # whatever arrived after it started is the next drain's business or the
      # socket's.
      def drain(&block)
        head = nil
        loop do
          page = @replay.call(@position.cursor)
          head ||= page.watermark
          page.items.each { |event| deliver(event, &block) }
          # A reader that publishes no head (a fake, an older door) gets one
          # pass: there is nothing to reach, and comparing with nothing
          # raised inside the reactor as a warning no test failed on.
          break if head.nil? || @position.sequence >= head
          # A page with nothing on it cannot move the position, so continuing
          # would spin forever. The predecessor could reach exactly this state
          # and did loop.
          break if page.items.empty?
        end
        # State recovery belongs to this same consumer, after the entire
        # bounded replay and before subscribing. The head can exceed the
        # position when items expired; recovery never invents consumed events.
        consume { @after_replay.call(head) } if @after_replay && !stopped?
      end

      # Live items, ALREADY TYPED — the subscription hands over the same kind of
      # object the replay page does, because a pump that could tell them apart
      # would be comparing things it should not be able to see.
      #
      # A FORWARD GAP IS A REPLAY SIGNAL, never permission to
      # advance past durable events that have not been seen — the socket can
      # deliver out of order whenever two appends commit on different threads.
      #
      # If the re-drain does not close the gap, the event is DROPPED rather
      # than delivered. That is the predecessor's one real bug fixed: it
      # delivered anyway and moved the floor, so an item that never arrived on
      # the socket was silently skipped forever. Dropping loses nothing — the
      # item is durable, and the next drain yields it in order.
      def consume_live(subscription, &block)
        subscription.each do |event|
          if gap?(event)
            drain_with_retry(&block)
            next if gap?(event)
          end
          deliver(event, &block)
        end
        :closed
      # Backpressure is one of these by inheritance, which is the whole
      # charter's catch-up path for free: a subscription whose bounded buffer
      # overflowed is lost, so the pump discards it, re-drains from the last
      # committed position and resubscribes.
      rescue Realtime::ConnectionLostError
        stopped? ? :closed : :lost
      end

      def deliver(event, &block)
        return unless fresh?(event)

        consume { block.call(event) }
        # AFTER the consumer returns, so a raise leaves the event eligible.
        @position = Position.new(cursor: event.cursor, sequence: event.sequence)
      end

      def consume
        yield
      rescue StandardError => error
        raise ConsumerFailure.new(error)
      end

      def fresh?(event) = event.sequence > @position.sequence

      def gap?(event) = event.sequence > @position.sequence + 1

      def with_transient_retry(errors = TRANSIENT_ERRORS)
        attempts = 0
        begin
          yield
        rescue *errors => error
          raise if stopped?

          attempts += 1
          raise if attempts > @max_transient_retries

          @sleeper.call(backoff_for(attempts, error))
          retry
        end
      end

      # A throttle names its own delay, and honouring it is the difference
      # between backing off and hammering a server that just said not to.
      def backoff_for(attempts, error)
        return error.retry_after if error.retry_after

        [@retry_backoff * (2**(attempts - 1)), @max_backoff].min
      end
  end
end
