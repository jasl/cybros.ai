module AgentRuns
  # THE REPEAT BRAKE judges NOVELTY, never count. A round is what its
  # reader newly read — each call with its settled result, and the material
  # delivered beside them — and it is stale when the LOOKBACK rounds before
  # it on this chain already brought every element and nothing new reached
  # its reader. A round is refused when the NOVELTY_WINDOW rounds up to the
  # one it just read are all stale and it asks only for calls the lookback
  # made: a rotation whose results never change halts, one call whose
  # result keeps changing never does. Identity is read from rows — text
  # digests, statuses, a branch tip's word — never from rendered prose and
  # never from a key the kernel minted. Bounded by WALK_BOUND, whatever the
  # loop's length.
  class RepeatBrake
    # The closed word on every surface: the round fails
    # `round_expansion_refused` with this detail, which a consumer of a
    # branch reads in its envelope and a halting chain holds for a person.
    REPEAT_LOOP = "repeat_call_loop".freeze
    # How many rounds in a row must bring nothing new: a pure repeat is
    # refused at its tenth identical call.
    NOVELTY_WINDOW = 8
    # How far back "already seen" looks: a rotation over up to sixteen
    # unchanging results is caught, at eight more fans of walk.
    LOOKBACK = 2 * NOVELTY_WINDOW
    # Readers traversed, poll rounds included, so the walk is O(1) in the
    # loop's length; a longer run of polls leaves too few judged rounds and
    # the brake errs toward not refusing.
    WALK_BOUND = 3 * NOVELTY_WINDOW
    # Polling a process the model started is the runner's designed wait
    # (nothing wakes a loop on a process exit): a round of nothing but polls
    # is never stale, never refused, and outside the count — unless
    # something new reached its reader. Read on the RESOLVED name.
    POLL_TOOLS = %w[read_process].freeze
    # The kernel's own launch receipts name the work they started; the
    # launch is the fact, and the work is judged when its result lands.
    LAUNCH_VERBS = %w[delegate_task spawn send].freeze
    LAUNCHED = [:launched].freeze

    # One round, newest first: the reader, the fan it read (the rows the
    # round before it made) and the material delivered beside that fan —
    # nil until the reader's composition is read.
    Round = Data.define(:reader, :rows, :delivered)

    class << self
      def call(node:, calls:) = new(node, calls).refusal
    end

    def initialize(node, calls)
      @node = node
      @calls = calls
      @held = {}
    end

    # Ordered so a healthy loop pays nothing: the asked calls, then the
    # walk over rows alone — a poll round's reader excepted, whose
    # freshness decides whether the round counts — and only a loop asking
    # nothing new reads the results.
    def refusal
      asked = ExpandRound.call_signature(@node, @calls)
      return nil if asked.nil? || poll_only?(asked.map(&:first))

      rounds = judged_rounds
      return nil if rounds.length < NOVELTY_WINDOW
      return nil unless asked.to_set.subset?(calls_of(rounds.first(LOOKBACK)))

      rounds = delivered_beside(rounds)
      identities = identities_of(rounds)
      fresh = fresh_readers(rounds.first(NOVELTY_WINDOW))
      stale = (0...NOVELTY_WINDOW).all? { |position| stale?(rounds, identities, fresh, position) }
      return nil unless stale

      log_refusal(rounds)
      REPEAT_LOOP
    end

    private

      def poll_only?(names) = names.all? { |name| POLL_TOOLS.include?(name) }

      def poll_model_task?(round) = poll_only?(round.rows.map(&:tool_name))

      # The segment the brake judges, newest first: the walk's rounds up to
      # the first whose maker made no call — whatever re-opened the chain
      # past a call-less answer was new — with the rounds of nothing but
      # polls taken out, so they neither extend a stale stretch nor break
      # one. A poll round something new reached is more than polls, and
      # stays.
      def judged_rounds
        segment = walked_rounds.take_while { |round| round.rows.any? }
        counted = counted_polls(segment.select { |round| poll_model_task?(round) })
        segment.filter_map { |round| poll_model_task?(round) ? counted[round.reader.id] : round }
      end

      # Each walked reader beside the fan it read.
      def walked_rounds
        pairs = walk
        fans = RoundReplay.fans_of(pairs.map(&:last))
        pairs.map { |reader, maker| Round.new(reader: reader, rows: fans.fetch(maker.id, {}).values, delivered: nil) }
      end

      # Each reader beside the round that made the fan it read, from this
      # node back along the rounds it continues, never into a loser. A reader whose
      # composition was repaired — a prune mark, an arrived summary — read
      # under a repair whose own words ask for the re-reads that follow, so
      # nothing before it may make them stale; the walk ends there, at the
      # chain's start, or at the bound (the pair count grows by one a step).
      def walk
        pairs = []
        reader = @node
        while pairs.length < WALK_BOUND && !reader.repaired?
          maker = InputComposition.source_round(reader)
          break if maker.nil?

          pairs << [reader, maker]
          reader = maker
        end
        pairs
      end

      # The poll rounds that are more than polls, by reader: a round is its
      # fan AND the material delivered beside it, and a reader something new
      # reached — a person's retry, a landed steer — must not lose that to
      # the fan it happened to read. Such a round counts, and slides out of
      # the window like any other.
      def counted_polls(polls)
        return {} if polls.empty?

        polls = delivered_beside(polls)
        fresh = fresh_readers(polls)
        polls.select { |round| round.delivered.any? || fresh.include?(round.reader.id) }
          .index_by { |round| round.reader.id }
      end

      # The CALL part of an element: the row's own words — the kernel's
      # wire name and the mapped input, canonical — nil when unreadable.
      def call_of(row)
        input = ExpandRound.canonical_arguments(row.tool_input)
        [row.tool_name, input, row.target_executor_public_id.to_s] unless input.nil?
      end

      def calls_of(rounds) = rounds.flat_map(&:rows).filter_map { |row| call_of(row) }.to_set

      # What each reader held beside its fan, as its composition read it:
      # the material delivered to it and the branch tips its paired calls
      # answered with — one batch over the readers not read yet.
      def delivered_beside(rounds)
        unread = rounds.select { |round| round.delivered.nil? }
        @held = @held.merge(InputComposition.readers_by_round(unread.map(&:reader)))
        rounds.map do |round|
          if round.delivered.nil?
            round.with(delivered: @held[round.reader.id]&.delivered_tips.to_a)
          else
            round
          end
        end
      end

      # The tips the readers' paired calls answered with, by the call's key.
      def paired_tips = @paired_tips ||= @held.values.map(&:substituted_tips).reduce({}, :merge)

      # An ask's `<answer>` is a person's words: it makes its reader fresh
      # and is never an element.
      def answer?(tip) = tip.await? && !tip.observing_task?

      # Each round's elements, index-aligned with `rounds`: its fan rows'
      # and its delivered material's, nil for one the brake cannot read.
      def identities_of(rounds)
        delivered = rounds.flat_map(&:delivered).reject { |tip| answer?(tip) }
        origins = delivered.to_h { |tip| [tip.id, TaskResultEnvelope.origin(tip)] }
        rows = rounds.flat_map(&:rows)
        @digests = text_digests(outputs: rows + paired_tips.values + delivered,
          inputs: origins.values.reject(&:tool_call?))
        ActiveRecord::Associations::Preloader.new(
          records: rows, associations: { output_body: { content_uploads: { file_attachment: :blob } } }
        ).call
        rounds.map do |round|
          round.rows.map { |row| row_element(row) } +
            round.delivered.reject { |tip| answer?(tip) }.map { |tip| delivered_element(tip, origins.fetch(tip.id)) }
        end
      end

      def row_element(row)
        call = call_of(row)
        [call, result_of(row)] unless call.nil?
      end

      # THE RESULT the reader actually read: a paired call's branch tip or
      # await; a background launch as the launch; a completed row as its
      # error flag, its text and the pictures the pairing law shows (never
      # its `structured` channel or its links, which carry a fresh upload id
      # per call); any other status as the triple the envelope renders.
      def result_of(row)
        tip = paired_tips[[row.agent_run_id, row.node_key]] if BranchTools::PAIRED_VERBS.include?(row.tool_name)
        return tip_identity(tip) if tip && row.tool_name != "tool_call"
        row = RoundReplay::Pairing.result_node(row, tip)
        return LAUNCHED if launched?(row)

        case row.status
        when "completed" then [row.output_summary["is_error"] == true, digests_of(row, "output"), pictures_of(row)]
        else [row.status, row.error_key, row.error_detail]
        end
      end

      def launched?(row)
        LAUNCH_VERBS.include?(row.tool_name) && row.status == "completed" && row.output_summary["is_error"] != true
      end

      def tip_identity(tip) = [tip.status, tip.error_key, tip.error_detail, digests_of(tip, "output")]

      # A delivered tip by where its envelope says it came from — a tool's
      # call, a flat call's, else the authored brief — and what it said;
      # never its key or a conversation id.
      def delivered_element(tip, origin)
        from = origin.tool_call? ? call_of(origin) : [:brief, digests_of(origin, "input")]
        [from, tip_identity(tip)] unless from.nil?
      end

      def pictures_of(row)
        body = row.output_body
        body ? RoundReplay::Pairing.ordered_pictures(body).map { |upload| upload.file.blob.checksum } : []
      end

      # The content addresses of each body's TEXT entries in entry order,
      # keyed by node and role: equal lists are equal text read.
      def text_digests(outputs:, inputs:)
        ContentBodyEntry.joins(:content_body, :content_fragment)
          .where(content_bodies: { agent_run_task_id: outputs.map(&:id), role: "output" })
          .or(ContentBodyEntry.joins(:content_body, :content_fragment)
            .where(content_bodies: { agent_run_task_id: inputs.map(&:id), role: "input" }))
          .where("content_fragments.payload ? :key", key: Parks::ResultContent::TEXT)
          .order("content_bodies.agent_run_task_id", "content_bodies.role", "content_body_entries.position")
          .pluck("content_bodies.agent_run_task_id", "content_bodies.role", "content_fragments.digest")
          .group_by { |node_id, role, _digest| [node_id, role] }
          .transform_values { |entries| entries.map(&:last) }
      end

      def digests_of(node, role) = @digests.fetch([node.id, role], [])

      # A reader something new reached regardless of its fan: a landed
      # steer or an ask's answer (a person's or a peer's words), an authored
      # brief of its own, or a re-run — a person's retry among them, which
      # must get the call that shows the world they fixed.
      def fresh_readers(rounds)
        readers = rounds.map(&:reader)
        worded = ContentBody.where(agent_run_task_id: readers.map(&:id), role: [Steers::Landed::ROLE, "input"])
          .distinct.pluck(:agent_run_task_id)
        answered = rounds.select { |round| round.delivered.any? { |tip| answer?(tip) } }.map { |round| round.reader.id }
        rerun = readers.select { |reader| reader.execution_generation.positive? }.map(&:id)
        (worded + answered + rerun).to_set
      end

      def stale?(rounds, identities, fresh, position)
        return false if fresh.include?(rounds[position].reader.id)

        elements = identities[position]
        return false if elements.include?(nil)

        lookback = identities[(position + 1), LOOKBACK].to_a
        return false if lookback.empty?

        seen = lookback.flatten(1).compact.to_set
        elements.all? { |element| seen.include?(element) }
      end

      # The window rides the kernel's log, never a model-facing sentence:
      # the readers whose rounds were judged, oldest to newest.
      def log_refusal(rounds)
        Rails.logger.warn(
          "event=agent_run_repeat_refused loop=#{@node.agent_run.public_id} task=#{@node.node_key} " \
          "window_first=#{rounds[NOVELTY_WINDOW - 1].reader.node_key} window_last=#{@node.node_key} " \
          "window=#{NOVELTY_WINDOW} calls=#{@calls.length}"
        )
      end
  end
end
