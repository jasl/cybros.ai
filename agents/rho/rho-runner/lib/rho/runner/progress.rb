module Rho
  # Reopened by `rho/runner.rb`, which holds the loop itself.
  class Runner
    # WHAT A RUNNING TOOL SAYS WHILE IT RUNS (executor.md "Progress"), posted as ephemeral frames under the task's claim — a `bash`
    # tail, say — for whoever is watching, never for the model. The model of
    # it is `DeadlineExtension`'s: a handler on its worker thread HANDS IN
    # the latest tail (`tail`), and the pool's wait — on the reactor's fiber,
    # where the kernel call belongs — POSTS it when the cadence allows
    # (`flush`); a handler never posts. Only the newest tail is kept: a frame
    # is droppable by construction, and the last one is what a watcher wants.
    # ONE REFUSAL STOPS THE POSTING — a typed refusal (`not_claimant` after
    # a cancel, a stopped loop) or a transport the door could not cross —
    # exactly as one refusal ends the extension's asking: the work goes on,
    # the frames do not.
    class Progress
      # THE SERVER'S OWN BOUND, MIRRORED — the runner is a separate gem and
      # cannot read nexus's size registry, so this is a copy and says so.
      # Nexus admits ONE frame per key per `MIN_INTERVAL_MS` per kernel
      # process (`Executors::Progress::MIN_INTERVAL_MS`; published as
      # `size_bounds.json#/progress_min_interval_ms`, which the suite pins
      # this equal to) and DROPS a faster poster's frames with a 202, never
      # a refusal — so posting faster than this buys nothing and costs a
      # request; posting at it is the floor of the cadence.
      MIN_INTERVAL_MS = 250

      attr_reader :interval_ms

      # `post` takes the tail text and answers true when the kernel took the
      # frame (broadcast or dropped for cadence alike — both are 202), false
      # on a refusal; `clock` is the run's monotonic clock.
      def initialize(post:, clock:, interval_ms: MIN_INTERVAL_MS)
        raise ArgumentError, "interval_ms must be positive" unless interval_ms.positive?

        @post = post
        @clock = clock
        @interval_ms = interval_ms
        @mutex = Mutex.new
        @pending = nil
        @posted = nil
        @next_at = clock.call
        @stopped = false
      end

      def stopped? = @stopped

      # FROM THE WORKER: the latest tail replaces whatever was waiting; a
      # tail already posted, or an empty one, is nothing new.
      def tail(text)
        text = text.to_s
        @mutex.synchronize { @pending = text unless text.empty? || text == @posted }
        nil
      end

      def pending? = @mutex.synchronize { !@pending.nil? }

      # How long the pool may wait before it must look here again: the
      # time until the pending tail may go out, or — with nothing pending —
      # one interval, because a tail arrives from the worker at any moment
      # and the reactor's wait is the only place that posts it (the
      # extension's ask has a due time of its own; a tail does not). nil
      # once the posting stopped: then the wait is the clamp's alone.
      def wait(now = @clock.call)
        return nil if @stopped
        return @interval_ms / 1000.0 unless pending?

        [@next_at - now, 0.0].max
      end

      def due?(now = @clock.call) = !@stopped && pending? && now >= @next_at

      # ON THE REACTOR: post the pending tail when the cadence allows, and
      # re-arm the cadence from the post. Answers whether a frame went out.
      def flush(now = @clock.call)
        return false unless due?(now)

        text = @mutex.synchronize do
          taken = @pending
          @pending = nil
          taken
        end
        return false if text.nil?

        @next_at = now + (@interval_ms / 1000.0)
        if @post.call(text)
          @posted = text
          true
        else
          @stopped = true
          false
        end
      end
    end
  end
end
