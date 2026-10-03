module CybrosAgent
  module Api
    # THE LAWS OF THE LIVE THREAD, IN ONE PLACE: a live thread is three inputs folded
    # by rules a consumer must not re-invent, and rho, a console and the
    # webui share this object rather than each holding a tree.
    #
    # THE LAW. The accumulator is opened on a PAGE (the spine) and follows
    # the SPINE:
    #
    # - a page SEEDS rows by `task_key` in reading order and replaces
    #   whatever was held — the page is the truth, this is a tail over it;
    # - a transcript `round` item UPSERTS its row when `spine` is true and
    #   is DROPPED when false: a branch round's key is loop-global and
    #   carries no link to its root, so it cannot be placed live, and it is
    #   not the thread;
    # - a `call` item upserts a call under the round its NUMBER names
    #   (`r<n>t<i>` is read by `r<n>`: ExpandRound mints both from one
    #   number), creating the round's row `waiting` when it is not known
    #   yet — the fan is born before its reader runs. A call whose key is
    #   not of that grammar (a compose member, a ladder's `check-1`) is a
    #   call of no round and is dropped;
    # - a `progress` frame marks LIVENESS on the row or the call its key
    #   names: `round_started` → the row `running` with `attempt`, `model`,
    #   `request_bytes`; `step_started` → the call's live status, UPSERTED
    # (an approval-gated call starts twice, held then dispatched, and both are news); `step_claimed` → the claimant;
    # - COMPLETION WINS: the settled snapshot replaces the live mark, whole.
    #
    # ONE REFINEMENT THE KEYS FORCE. A call's row is created before its
    # reader has said which thread it is on — a branch round's calls
    # carry the same `r<n>t<i>` spelling as the spine's — so a row born
    # from a call is a GUESS the reader settles: a `round_started` or a
    # `round` whose `spine` is false retracts the guessed row and marks the
    # key a branch's, and anything else under that number is dropped from
    # then on. The transient (a `waiting` row between a branch call's birth
    # and its reader's start) is what a loop-global key costs; a page read
    # is always the truth.
    #
    # It holds no socket and knows no feed: the caller reads `type` and
    # calls the method, exactly as `TranscriptAccumulator` is shaped. Every
    # input is taken in the SDK's shape — the typed object
    # (`AgentLoopTranscript`, `TranscriptItem`, `ProgressFrame`) or its
    # `to_h`, which is the JSON a daemon relays — and every row is held in
    # the WIRE's shape (string keys, `calls: {count, items}`, `branches`),
    # so `snapshot` is bytes a client can pin. Nothing here is durable, and
    # nothing here mutates: every upsert builds the row anew.
    class ThreadAccumulator
      # The kernel's number rule (transcript.rb, ROUND_KEY): a call `r<n>t<i>`
      # is read by `r<n>`. Only the bare spelling — `r2t0-model-1` is a
      # branch's root, never a call.
      CALL_KEY = /\Ar(\d+)t\d+\z/

      def initialize
        @rows = {}
        @live = []
        @branches = []
      end

      # THE PAGE, the truth: rows in reading order, every live mark gone.
      # Answers the rows it now holds. `AgentLoopTranscript` enumerates its
      # rows (its `to_h` is Enumerable's), so the typed page is read by name.
      def seed(page)
        rounds = page.respond_to?(:rounds) ? wire(page.rounds) : wire(page).fetch("rounds", [])
        @rows = rounds.to_h { |row| [row.fetch("task_key"), row] }
        @live = []
        @branches = []
        rows
      end

      # A settled `round` item. Answers the row it placed, nil when the
      # round is a branch's (dropped, and a guessed row retracted).
      def settle_round(item)
        item = wire(item)
        row = item.dig("payload", "round")
        return nil if row.nil?

        key = row.fetch("task_key")
        return retract(key) unless row["spine"] == true

        @rows = @rows.merge(key => row)
        # Its calls settled before it ran (the reader grouping), so every
        # mark under its number is stale with it.
        @live = @live.reject { |live| live == key || round_of(live) == key }
        row
      end

      # A settled `call` item. Answers the round's row it landed on, nil
      # when the key names no round of this thread.
      def settle_call(item)
        item = wire(item)
        call = item.dig("payload", "call")
        return nil if call.nil?

        key = call.fetch("task_key")
        round_key = round_of(key)
        return nil if round_key.nil? || @branches.include?(round_key)

        row = upsert_call(round_key, call, replace: true)
        @live -= [key]
        row
      end

      # An attempt dialled: the row is `running` with what the frame says.
      # A branch's round (`spine` false) is not the thread.
      def round_started(frame)
        frame = wire(frame)
        payload = frame.fetch("payload", {})
        key = frame.fetch("task_key")
        return retract(key) unless payload["spine"] == true

        row = (@rows[key] || new_row(key)).merge(
          "status" => "running", "attempt" => payload["attempt"], "model" => payload["model"],
          "request_bytes" => payload["request_bytes"]
        ).compact
        @rows = @rows.merge(key => row)
        mark(key)
        row
      end

      # A tool row dispatched, run or held: the call's live status, upserted.
      def step_started(frame)
        frame = wire(frame)
        key = frame.fetch("task_key")
        round_key = round_of(key)
        return nil if round_key.nil? || @branches.include?(round_key)

        row = upsert_call(round_key, {
          "task_key" => key, "name" => frame["tool_name"], "status" => frame.dig("payload", "status"),
        }.compact)
        mark(key)
        row
      end

      # An executor took the call: the claimant, on the call.
      def step_claimed(frame)
        frame = wire(frame)
        key = frame.fetch("task_key")
        round_key = round_of(key)
        return nil if round_key.nil? || @branches.include?(round_key)

        row = upsert_call(round_key, {
          "task_key" => key, "name" => frame["tool_name"], "executor_public_id" => frame["executor_public_id"],
        }.compact)
        mark(key)
        row
      end

      # The rows in reading order.
      def rows = @rows.values

      # What is running now, by key, in the order it was marked.
      def live = @live.dup

      def snapshot = { "rows" => rows, "live" => live }

      private

        def round_of(key)
          match = CALL_KEY.match(key)
          match && "r#{match[1]}"
        end

        def new_row(key)
          { "task_key" => key, "spine" => true, "status" => "waiting",
            "calls" => { "count" => 0, "items" => [] }, "branches" => [] }
        end

        # In place when the call is known — a live mark MERGES over the
        # entry, a settle REPLACES it whole (completion wins) — appended when
        # it is not; `count` never reads below what is shown, and never
        # guesses above it.
        def upsert_call(round_key, call, replace: false)
          row = @rows[round_key] || new_row(round_key)
          calls = row.fetch("calls", { "count" => 0, "items" => [] })
          items = calls.fetch("items", [])
          key = call.fetch("task_key")
          known = items.index { |item| item["task_key"] == key }
          items = if known.nil? then items + [call]
          else items.each_with_index.map { |item, index| index == known ? (replace ? call : item.merge(call)) : item }
          end
          row = row.merge("calls" => calls.merge("count" => [calls.fetch("count", 0), items.length].max, "items" => items))
          @rows = @rows.merge(round_key => row)
          row
        end

        # A branch's number: whatever was guessed under it goes, and nothing
        # under it lands again.
        def retract(key)
          @rows = @rows.except(key)
          @live = @live.reject { |live| live == key || round_of(live) == key }
          @branches |= [key]
          nil
        end

        def mark(key)
          @live = @live.include?(key) ? @live : @live + [key]
        end

        # The SDK's shape to the wire's: a typed object is its `to_h`, and
        # every key is a string — what a daemon's JSON relay carries.
        def wire(value)
          case value
          when Hash then value.to_h { |key, entry| [key.to_s, wire(entry)] }
          when Array then value.map { |entry| wire(entry) }
          when Data then wire(value.to_h)
          else value
          end
        end
    end
  end
end
