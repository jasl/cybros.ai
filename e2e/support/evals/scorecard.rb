require_relative "../gallery/shapes"
require_relative "bench"
require_relative "predicates"
require_relative "records"
require_relative "trace"

module E2E
  module Evals
    module Scorecard
      LANE_BUG = "lane bug".freeze
      MODEL_CONDUCT = "model conduct".freeze
      KERNEL_FINDING = "kernel finding".freeze
      # The reason's head when the task's predicate raised (`EvalsLaneTest#verdict_of`): the
      # harness read nothing of the run.
      PREDICATE_RAISED = "the predicate raised".freeze
      DISAGREEMENT = "disagreement".freeze
      PROVIDER_REFUSED = "provider refused".freeze
      CACHE_UNDER_FLOOR = "cache under floor".freeze
      CLASSES = [LANE_BUG, MODEL_CONDUCT, KERNEL_FINDING, DISAGREEMENT, PROVIDER_REFUSED, CACHE_UNDER_FLOOR].freeze
      ACP_WORK_EVENTS = %w[
        agent_message_chunk agent_thought_chunk tool_call tool_call_update plan
        read_text_file write_text_file request_permission session/request_permission
      ].freeze
      # The one attention each driver scripts; anything else is unscripted.
      SCRIPTED_ATTENTION = {
        "answer_ask" => %w[awaiting_human], "pump" => %w[approval_required],
        "brake" => %w[halt_failure], "halting_loop" => %w[halt_failure],
        "settle_receipts" => [], "memory_scope" => [], "processes" => [],
      }.freeze
      # The brake's refusal is the model's conduct (it repeated what brought nothing new), not the
      # kernel's — the refusal key carrying the brake's own detail; any other detail under it is the
      # kernel's (`kernel_refusals`).
      CONDUCT_ERROR_KEYS = [Gallery::EXPANSION_REFUSED].freeze
      # A PROVIDER'S REFUSAL is the provider's, never the kernel's: the kernel fails a declined step
      # with this key, and the refusal reads as `provider refused` when it stood — a settled race's
      # loser refused after the race had its answer carries the key and reads as nothing.
      PROVIDER_ERROR_KEYS = [Trace::REFUSED].freeze
      # A DESIGNED CANCEL is never a failed round: an any-join cancels its losers
      # (`AgentRuns::CancelLosers::REASON`).
      DESIGNED_CANCEL_KEYS = %w[join_loser_canceled].freeze
      # THE BRAKE'S OWN HALT: the refusal parks the loop `halt_failure` on any driver, and the park
      # is the model's conduct wherever the refusal is on the record — scripted or not.
      BRAKE_ATTENTION = %w[halt_failure].freeze
      # THE HARNESS'S STOPS: the deadline, the cost stop, and the model's question on an unattended
      # run (`MemberPlane::NEEDS_PERSON`, the plain driver's stop on the first unscripted
      # `awaiting_human`); the person's interrupt is read as the lane's.
      DEADLINE = "deadline".freeze
      COST_STOP = "cost_stop".freeze
      NEEDS_PERSON = "needs_person".freeze
      HARNESS_STOPS = [DEADLINE, COST_STOP, NEEDS_PERSON].freeze
      INTERRUPTED = "interrupted".freeze
      # THE ASK A NEEDS_PERSON STOP ENDED ON is the stop's own reason (the
      # harness read the park and acted), never the kernel's signal; so is
      # an ask the harness answered itself (bench version 10), whose item
      # stays on the feed of a run that went on.
      ASKING_ATTENTION = %w[awaiting_human].freeze
      # The kinds, in the breakdown's order (`kind_of`; every red has one).
      VERIFICATION_FAILED = "verification failed".freeze
      COST_STOP_KIND = "cost stop".freeze
      ERROR_KIND = "error".freeze
      OTHER_KIND = "other".freeze
      # A deadline that landed while the model streamed its first round (`mid_model_task?`) reads apart,
      # with the verification's word as every deadline does.
      MID_ROUND = "mid-round".freeze
      KINDS = [VERIFICATION_FAILED, "#{DEADLINE} (verified)", "#{DEADLINE} (failed)", DEADLINE,
               "#{DEADLINE} (#{MID_ROUND}, verified)", "#{DEADLINE} (#{MID_ROUND}, failed)", "#{DEADLINE} (#{MID_ROUND})",
               "#{NEEDS_PERSON} (verified)", "#{NEEDS_PERSON} (failed)", NEEDS_PERSON,
               COST_STOP_KIND, INTERRUPTED, ERROR_KIND, OTHER_KIND].freeze
      # A STREAM IS LIVE when its last delta landed at most this long before the stop, or at or after
      # it: about twice the longest silence seen inside a live stream (28.2 s). A quieter stream is a
      # stall, the lane's.
      STREAM_LIVE_SECONDS = 60
      # The ask's head on the red line: its first line, cut at this many characters.
      ASK_HEAD_LENGTH = 60
      BENCH_SCOPE = "Direct-provider text probes and end-to-end evaluation cells have different prompts, " \
                    "tool sets and execution paths. These evaluations run through rho and score public " \
                    "kernel traces; do not pool their results with text-probe results.".freeze

      module_function

      def classify(record, bench: bench_on_disk)
        return LANE_BUG if record["error"] || record["stopped"] == INTERRUPTED
        return KERNEL_FINDING if kernel_check(record)
        return LANE_BUG if unscored?(record)
        return (work_seen?(record) ? MODEL_CONDUCT : LANE_BUG) if HARNESS_STOPS.include?(record["stopped"])
        return KERNEL_FINDING if kernel_signal(record)
        return DISAGREEMENT if disagreement(record)
        return PROVIDER_REFUSED if provider_refused(record)
        return MODEL_CONDUCT if red?(record)
        return CACHE_UNDER_FLOOR if cache_under_floor(record, bench)

        nil
      end

      def unscored?(record) = record["reason"].to_s.start_with?(PREDICATE_RAISED)

      # DID THE RUN DO ANYTHING BEFORE THE STOP: a stop with no work is the
      # lane's own failure, a stop over work is the model's. The plain
      # driver counts settled rounds; a harbor trial counts model output
      # and tool activity; a round the stop cut is work when the model was
      # still streaming it (`live_stream?`). Connection and session
      # metadata are not work.
      def work_seen?(record)
        facts = record["facts"] || {}
        events = facts["events"] || {}
        facts["rounds_settled"].to_i.positive? || ACP_WORK_EVENTS.any? { |kind| events.fetch(kind, 0).positive? } ||
          live_stream?(record)
      end

      # THE LOOP WAS STREAMING WHEN THE STOP LANDED: the lane's `in_flight` fact (`WorldLog.in_flight`,
      # the model runner's broadcasts for the loop) holds deltas, the last one at most
      # STREAM_LIVE_SECONDS before the stop, or at or after it. No fact (not read), no frame (a hang, a dead runner), a
      # stream gone quiet, or no stop time to age it against is no stream.
      def live_stream?(record)
        stream = Hash(record.dig("facts", "in_flight"))
        age = stream["last_frame_age_s"]
        stream["frames"].to_i.positive? && !age.nil? && age <= STREAM_LIVE_SECONDS
      end

      # A deadline that no round outlived, over a live stream: it cut the model's first round.
      def mid_model_task?(record)
        record["stopped"] == DEADLINE && record.dig("facts", "rounds_settled").to_i.zero? && live_stream?(record)
      end

      def bench_on_disk = (@bench_on_disk ||= Bench.read)

      # THE BAR, in the record's words — the rate after round 1 against the
      # family's floor; nil when nothing is read: no per-round series on the
      # record (a 12a/12b record, a live lane's — the loop-total alone is
      # the cost term, never the bar), fewer measured rounds than
      # `cache_floor_min_rounds`, a family with no floor, a read-only id.
      # The floor itself is green.
      def cache_under_floor(record, bench)
        series = record.dig("efficiency", "cache_read_series")
        rate = Trace.after_first_round_rate(series)
        return nil if rate.nil? || Trace.measured_rounds(series) < bench.cache_floor_min_rounds

        floor = bench.cache_floor_for(record["family"], model: record["model"])
        return nil if floor.nil? || rate >= floor

        "cache #{rate} after round 1 under the #{record["family"]} floor #{floor}"
      end

      # The signal named, in the record's words — nil when the kernel did nothing the driver did not
      # script. The kernel check's finding is read first (`kernel_check`). THE HARNESS'S OWN STOP IS
      # NOT A FAILED ROUND: `rho stop` after the cost stop, the deadline, the model's question or the
      # person's interrupt stamps `Predicates::HARNESS_STOP`'s two keys on the rows it ended, and a
      # stopped record's red line read "a round failed: creator_requested" over its own reason.
      def kernel_signal(record)
        checked = kernel_check(record)
        return checked if checked

        facts = Hash(record["facts"])
        errors = Hash(facts["round_errors"]).keys - CONDUCT_ERROR_KEYS - DESIGNED_CANCEL_KEYS - PROVIDER_ERROR_KEYS
        errors -= Predicates::HARNESS_STOP if (HARNESS_STOPS + [INTERRUPTED]).include?(record["stopped"])
        errors += kernel_refusals(record)
        return "a round failed: #{errors.join(", ")}" unless errors.empty?

        unscripted = Hash(facts["attention_reasons"]).keys - scripted_attention(record)
        return "attention_required outside the scripted step: #{unscripted.join(", ")}" unless unscripted.empty?

        fallback = Hash(record.dig("efficiency", "compactions")).keys.select { |mode| mode.end_with?("/fallback") }
        fallback.empty? ? nil : "a fallback compaction: #{fallback.join(", ")}"
      end

      # THE REFUSALS THAT WERE NOT THE BRAKE, each as `key (detail)`: an expansion refusal is the
      # model's conduct only when its detail is the brake's word (`Gallery::REPEAT_LOOP`); any other
      # detail — an input the kernel could not store — refused a round the model authored, a
      # kernel-path halt. A record from before the details (no `facts.round_error_details`) reads its
      # refusal as the brake, as it always did.
      def kernel_refusals(record)
        details = Hash(record.dig("facts", "round_error_details", Gallery::EXPANSION_REFUSED)).keys - [Gallery::REPEAT_LOOP]
        details.map { |detail| "#{Gallery::EXPANSION_REFUSED} (#{detail})" }
      end

      # THE BRAKE ON THE RECORD: a refusal carrying the brake's detail — or, on a record from before
      # the details, any refusal.
      def braked?(record)
        facts = Hash(record["facts"])
        details = facts["round_error_details"]
        if details.nil?
          Hash(facts["round_errors"]).key?(Gallery::EXPANSION_REFUSED)
        else
          Hash(details[Gallery::EXPANSION_REFUSED]).key?(Gallery::REPEAT_LOOP)
        end
      end

      # THE KERNEL CHECK'S FINDING, in the record's words: the check's own sentence when it found
      # something (`facts.kernel_check` a String — `true` is every read request carrying what its step
      # is owed, nil none read), else the authored steps the kernel handed anything by position
      # (`facts.task_reads[*].positional`); nil otherwise, and on a record from before the facts.
      def kernel_check(record)
        facts = Hash(record["facts"])
        check = facts["kernel_check"]
        positional = Hash(facts["task_reads"]).select { |_key, fact| Array(Hash(fact)["positional"]).any? }.keys
        if check in String
          "the kernel check: #{check}"
        elsif positional.any?
          "a placed model task read by position: #{positional.join(", ")}"
        end
      end

      # The driver's scripted attention, plus the brake's halt when the brake is on the record (a
      # plain run the brake stopped: `braked?`) or a provider's refusal stood (a refused mainline round halts the
      # loop on its compile-default `halt`), plus the ask the harness acted on: the one a
      # `needs_person` stop ended on, or one it answered (`facts.harness_answered`). A record with
      # no answer on it, every record before version 10 among them, reads as it always did.
      def scripted_attention(record)
        halted = braked?(record) || refused?(record)
        SCRIPTED_ATTENTION.fetch(record["driver"].to_s, []) + (halted ? BRAKE_ATTENTION : []) +
          (harness_acted_on_an_ask?(record) ? ASKING_ATTENTION : [])
      end

      def harness_acted_on_an_ask?(record)
        record["stopped"] == NEEDS_PERSON || Array(record.dig("facts", "harness_answered")).any?
      end

      # A PROVIDER'S REFUSAL THAT STOOD, in the record's words — how many steps, the categories and
      # the models the tally names, then the first standing refusal's own sentence (the kernel's,
      # for the reading model: who declined, and why nothing re-ran it) — nil when none stood. A
      # record from before the tally carries the count alone.
      def provider_refused(record)
        return nil unless refused?(record)

        facts = Hash(record["facts"])
        steps = facts["refused_steps"].to_i
        tally = Hash(facts["refusals"])
        categories = tally.values.flat_map(&:keys).uniq.sort
        head = "#{steps} step#{"s" unless steps == 1} refused"
        head += " (#{categories.join(", ")})" unless categories.empty?
        head += " on #{tally.keys.sort.join(", ")}" unless tally.empty?
        [head, facts["refusal_detail"]].compact.join(" — ")
      end

      def refused?(record) = record.dig("facts", "refused_steps").to_i.positive?

      # A RECORD THE DECLARED FALLBACK SERVED: some refused step of it was re-run on the answerer's
      # fallback and answered there.
      def served?(record) = record.dig("facts", "refusals_served").to_i.positive?

      # The succeeded count the model under test earned, then — only when the fallback served any —
      # the records it served: `N` or `N (+M by fallback)`.
      def succeeded_term(rows)
        succeeded = rows.select { |row| row.dig("verdict", "succeeded") == true }
        served = succeeded.count { |row| served?(row) }
        own = succeeded.size - served
        served.zero? ? own.to_s : "#{own} (+#{served} by fallback)"
      end

      # The two scorers apart, in the record's words — nil when they agree
      # (or one of them did not read: a task with no verification).
      def disagreement(record)
        verdict = Hash(record["verdict"])
        case [verdict["task_pass"], verdict["succeeded"]]
        when [true, false] then "the verification passed and the predicate is red"
        when [false, true] then "the predicate is green and the verification failed"
        else nil
        end
      end

      # `reached: nil` is a dimension NOT READ (a family with no reach:
      # terminal-bench, Agents-on-Rails — task pass is its one number), never
      # a red; `false` is the model's.
      def red?(record)
        verdict = Hash(record["verdict"])
        verdict["reached"] == false || verdict["succeeded"] == false || verdict["task_pass"] == false ||
          Hash(record["conduct"]).value?(false) || record["stopped"] == COST_STOP
      end

      # THE KIND: what ended the run, one word per red — nil on a green record. A raised driver is
      # read first (as `classify` reads it); a stop names itself, with the verification's word when
      # one ran and, on a deadline that cut the first round mid-stream, `mid-round`; a verification
      # red with no stop is `verification failed`; every other red is `other`.
      def kind_of(record, bench: bench_on_disk)
        return nil if classify(record, bench: bench).nil?
        return ERROR_KIND if record["error"]

        case record["stopped"]
        when DEADLINE, NEEDS_PERSON then stop_kind(record)
        when COST_STOP then COST_STOP_KIND
        when INTERRUPTED then INTERRUPTED
        else record.dig("verdict", "task_pass") == false ? VERIFICATION_FAILED : OTHER_KIND
        end
      end

      # The stop's word, then in one parenthesis whether it cut a round mid-stream and the
      # verification's word — each when there is one.
      def stop_kind(record)
        words = [(MID_ROUND if mid_model_task?(record)), verified_word(record)].compact
        words.empty? ? record["stopped"] : "#{record["stopped"]} (#{words.join(", ")})"
      end

      def verified_word(record)
        case record.dig("verdict", "task_pass")
        when true then "verified"
        when false then "failed"
        else nil
        end
      end

      # The kind as the line prints it: the brief's kinds by name, a
      # `needs_person` with the ask's head quoted by hand (`inspect` would
      # escape the ellipsis under a US-ASCII default_external), a mid-round
      # deadline with the stream it cut; `error` and `other` say nothing the
      # line's detail does not.
      def kind_line(record, bench: bench_on_disk)
        kind = kind_of(record, bench: bench)
        return nil if kind.nil? || [ERROR_KIND, OTHER_KIND].include?(kind)
        return "#{kind} — #{stream_note(record)}" if mid_model_task?(record)
        return kind unless kind.start_with?(NEEDS_PERSON)

        head = ask_head(record.dig("facts", "asked_prompt"))
        head.empty? ? kind : "#{kind}: \"#{head}\""
      end

      # The stream a mid-round deadline cut: its deltas and the last one's distance from the stop, on
      # whichever side of it the delta landed — the age is signed, and `(-0.04).round(1)` is `-0.0`,
      # so a zero or negative age reads "after" by its magnitude. No round settled to carry a usage,
      # so a record with no cost says the spend is unknown.
      def stream_note(record)
        stream = record.dig("facts", "in_flight")
        unknown = record.dig("efficiency", "cost_amount").nil? ? "; spend unknown" : ""
        age = stream["last_frame_age_s"].to_f
        distance = age > 0 ? "#{stream["last_frame_age_s"]} s before the stop" : "#{age.abs} s after the stop"
        "#{stream["frames"].to_i.to_fs(:delimited)} frames, the last #{distance}#{unknown}"
      end

      # The ask's first line, cut at ASK_HEAD_LENGTH with an ellipsis.
      def ask_head(prompt)
        line = prompt.to_s.lines.first.to_s.strip
        line.length > ASK_HEAD_LENGTH ? "#{line[0, ASK_HEAD_LENGTH].rstrip}…" : line
      end

      # ONE RED LINE: the class, the kind, then the record's own detail —
      # `detail_of`, the reason with what the kind already says left out.
      def red_line(record, bench: bench_on_disk)
        named = [kind_line(record, bench: bench), detail_of(record, bench: bench)].compact
        "- #{record["task"]} #{record["style"]} ##{record["run"]}: #{classify(record, bench: bench)} — " \
          "#{named.empty? ? "red" : named.join(" — ")}"
      end

      # One file per model under the label's dir; refuses to mix digests.
      def write(run_dir, bench: Bench.read)
        records = Records.read(run_dir)
        Records.refuse_mixed_digests!(run_dir, records)
        raise ArgumentError, "no records under #{run_dir}" if records.empty?

        records.group_by { |row| row["model"] }.map do |model, rows|
          path = File.join(run_dir, "scorecard.#{Bench.slug(model)}.md")
          File.write(path, render(rows, model: model, bench: bench, label: File.basename(run_dir)))
          path
        end
      end

      def render(records, model:, bench:, label:)
        tier = bench.tier_of(model)
        lines = header(records, model, bench, tier, label)
        records.group_by { |row| row["family"] }.sort.each { |family, rows| lines.concat(family_section(family, rows, bench: bench)) }
        lines.concat(reds_by_class(records, bench: bench))
        lines.concat(reds_by_kind(records, bench: bench))
        "#{lines.join("\n")}\n"
      end

      def header(records, model, bench, tier, label)
        digest = records.first["bench_digest"].to_s
        lines = ["# evals scorecard — `#{model}` — #{label}", "",
                 "- tier: #{tier || "not in the bench"}#{tier == Bench::FLOOR ? " (read-only: never tuned for)" : ""}",
                 "- bench digest: `#{digest}`" \
                 "#{digest == bench.digest ? "" : " (the bench on disk is `#{bench.digest}`: these records ran under another)"}",
                 "- style rows: #{records.map { |row| row["style"] }.uniq.sort.join(", ")}",
                 "- adaptations: #{adaptations_of(records)}",
                 "- declared fallback: #{fallbacks_of(records)}",
                 "- records: #{records.size} over #{records.map { |row| row["task"] }.uniq.size} tasks", "", BENCH_SCOPE]
        lines
      end

      # The rows the records booted under (`{row, source, tool_style [, candidate]}`), each once; a
      # record from before the fact existed reads `—`.
      def adaptations_of(records)
        records.map do |row|
          fact = Hash(row["adaptations"])
          next "—" if fact.empty?

          "#{fact["row"]} (#{fact["source"]}; #{Array(fact["tool_style"]).join("+")}" \
            "#{fact["candidate"] ? "; candidate #{fact["candidate"]}" : ""})"
        end.uniq.sort.join(", ")
      end

      # The refusal fallback the records declared (`facts.fallback_model`), each once: `none` for a
      # run that declared none, `—` for a record from before the fact.
      def fallbacks_of(records)
        records.map do |row|
          facts = Hash(row["facts"])
          facts.key?("fallback_model") ? (facts["fallback_model"] || "none") : "—"
        end.uniq.sort.join(", ")
      end

      # The reach and success ratios are over the records that READ them (`—` for a family that
      # reads none) — success crediting the model its own work, the fallback's apart
      # (`success_ratio`); task pass over the verified; the cache median — the rate after round 1,
      # over the records carrying the per-round series — against the floor the scorecard's model is
      # read at (`(no floor)` on a read-only id and on a family the bench names none for).
      def family_section(family, rows, bench: bench_on_disk)
        read = rows.reject { |row| row.dig("verdict", "reached").nil? }
        reached = read.count { |row| row.dig("verdict", "reached") }
        verified = rows.reject { |row| row.dig("verdict", "task_pass").nil? }
        passed = verified.count { |row| row.dig("verdict", "task_pass") == true }
        survived = rows.count { |row| row.dig("efficiency", "compactions_survived").to_i.positive? }
        lines = ["", "## #{family} — reach #{ratio(reached, read.size)} · success-when-reached #{success_ratio(read, reached)} · " \
                     "task pass #{ratio(passed, verified.size)} · compactions survived #{survived}/#{rows.size} · " \
                     "#{cache_header(family, rows, bench)}", "",
                 "| task | style | runs | reach | success | pass | fb | rounds | bytes (median / max) | cost | cache hit | cache r1 | conduct |",
                 "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        rows.group_by { |row| [row["task"], row["style"]] }.sort.each do |(task, style), cell|
          lines << table_row(task, style, cell)
        end
        reds = rows.reject { |row| classify(row, bench: bench).nil? }
        unless reds.empty?
          lines << "" << "### reds"
          reds.each { |row| lines << red_line(row, bench: bench) }
        end
        lines
      end

      # `ratio`'s shape over the succeeded records, the percentage the model's OWN: `N (+M by
      # fallback)/R (P%)`, the term apart only when the fallback served any.
      def success_ratio(read, reached)
        return "—" if reached.zero?

        own = read.count { |row| row.dig("verdict", "succeeded") == true && !served?(row) }
        "#{succeeded_term(read)}/#{reached} (#{(100.0 * own / reached).round}%)"
      end

      def cache_header(family, rows, bench)
        median = median(cache_rates(rows))
        floor = bench.cache_floor_for(family, model: rows.first["model"])
        "cache #{median.nil? ? "—" : median} (#{floor.nil? ? "no floor" : "floor #{floor}"})"
      end

      def table_row(task, style, cell)
        read = cell.reject { |row| row.dig("verdict", "reached").nil? }
        reached = read.select { |row| row.dig("verdict", "reached") }
        verified = cell.reject { |row| row.dig("verdict", "task_pass").nil? }
        rounds = median(cell.map { |row| row.dig("efficiency", "rounds") }.compact)
        # The route serves `cost_amount` as a decimal String and the record
        # keeps it so (12a L4: a median over Strings added two of them);
        # every efficiency median is taken over Floats.
        cost = median(floats(cell, "cost_amount"))
        cache = median(cache_rates(cell))
        unit = cell.map { |row| row.dig("efficiency", "cost_unit") }.compact.first
        "| #{task} | #{style} | #{cell.size} | #{read.empty? ? "—" : "#{reached.size}/#{read.size}"} | " \
          "#{read.empty? ? "—" : success_column(reached)} | " \
          "#{verified.empty? ? "—" : "#{verified.count { |row| row.dig("verdict", "task_pass") == true }}/#{verified.size}"} | " \
          "#{served_column(cell)} | " \
          "#{rounds.nil? ? "—" : rounds} | #{bytes_column(cell)} | #{cost.nil? ? "—" : "#{cost} #{unit}".strip} | " \
          "#{cache.nil? ? "—" : cache} | #{cache_r1_column(cell)} | #{conduct_tally(cell)} |"
      end

      # Count the model's own work separately from work served by its declared fallback.
      def success_column(reached) = "#{succeeded_term(reached)}/#{reached.size}"

      # THE `fb` COLUMN: the refused steps the answerer's declared fallback served, summed over the
      # cell's records that carry the fact — `0` read and none, `—` when no record carries it.
      def served_column(cell)
        counted = cell.filter_map { |row| row.dig("facts", "refusals_served") }
        counted.empty? ? "—" : counted.sum.to_s
      end

      def floats(cell, column) = cell.filter_map { |row| row.dig("efficiency", column) }.map { |value| Float(value) }

      # THE `cache hit` COLUMN (bench version 8): each record's rate after
      # round 1 (`Trace.after_first_round_rate`, the mainline's rounds 2..n
      # pooled off the per-round series) — the same number the family
      # header medians, the bar reads and the ledger's ` c` token carries;
      # a record with no series or one round alone feeds none.
      def cache_rates(cell) = cell.filter_map { |row| Trace.after_first_round_rate(row.dig("efficiency", "cache_read_series")) }

      # THE `cache r1` COLUMN: the median of the first mainline round's rate over the cell's records —
      # the provider's cross-run prefix, a provider fact recorded and never gated — against the
      # kernel's per-round input, never 1 − 1/rounds. The mainline's first round is the conversation's
      # first call whatever loops follow, so every record with a series is read; a first round of no
      # input is left out; the dash when none.
      def cache_r1_column(cell)
        rates = cell.filter_map { |row| Trace.first_round_rate(row.dig("efficiency", "cache_read_series")) }
        rates.empty? ? "—" : median(rates)
      end

      # THE BYTES COLUMN: every mainline round's sealed request size, pooled over the cell's records
      # (`efficiency.request_bytes_series`, `{key => bytes}`), as the median and the max — the floor
      # a Long returns to after a prune and the wall it rides, readable off the scorecard. A cell no
      # record of which carries a series prints the dash (not read).
      def bytes_column(cell)
        values = series_values(cell)
        values.empty? ? "—" : "#{median(values)} / #{values.max}"
      end

      def series_values(cell) = cell.flat_map { |row| Hash(row.dig("efficiency", "request_bytes_series")).values }

      def conduct_tally(cell)
        names = cell.flat_map { |row| Hash(row["conduct"]).keys }.uniq
        return "—" if names.empty?

        names.map { |name| "#{name} #{cell.count { |row| row.dig("conduct", name) == true }}/#{cell.size}" }.join("; ")
      end

      def reds_by_class(records, bench: bench_on_disk)
        lines = ["", "## reds by class", ""]
        CLASSES.each do |klass|
          rows = records.select { |row| classify(row, bench: bench) == klass }
          lines << "- #{klass}: #{rows.size}#{names_of(rows)}"
        end
        lines
      end

      # THE REDS BY KIND: every kind, zero or not, as the classes are — the counts the readout
      # separates the stops by.
      def reds_by_kind(records, bench: bench_on_disk)
        lines = ["", "## reds by kind", ""]
        KINDS.each do |kind|
          rows = records.select { |row| kind_of(row, bench: bench) == kind }
          lines << "- #{kind}: #{rows.size}#{names_of(rows)}"
        end
        lines
      end

      def names_of(rows)
        names = rows.map { |row| "#{row["task"]} #{row["style"]} ##{row["run"]}" }
        names.empty? ? "" : " — #{names.join(", ")}"
      end

      # The record's reason, first of: the error, the kernel's signal, the
      # disagreement or the provider's refusal, the predicate's reason, the
      # stop, a failed conduct, the verification, the bar — `red` when none
      # names itself.
      def reason_of(record, bench: bench_on_disk)
        signal = kernel_signal(record) || disagreement(record) || provider_refused(record)
        [record["error"], signal, record["reason"], stopped_note(record), conduct_note(record),
         (record.dig("verdict", "task_pass") == false ? VERIFICATION_FAILED : nil),
         cache_under_floor(record, bench)].compact.first || "red"
      end

      # The detail beside the kind on the red line: `reason_of` with the
      # stop's note and the verification's sentence — what the kind
      # already says — left out.
      def detail_of(record, bench: bench_on_disk)
        signal = kernel_signal(record) || disagreement(record) || provider_refused(record)
        [record["error"], signal, record["reason"], conduct_note(record), cache_under_floor(record, bench)].compact.first
      end

      def stopped_note(record) = record["stopped"] && "stopped: #{record["stopped"]}"

      def conduct_note(record)
        failed = Hash(record["conduct"]).reject { |_name, ok| ok }.keys
        failed.empty? ? nil : "conduct: #{failed.join(", ")}"
      end

      def ratio(part, whole) = whole.zero? ? "—" : "#{part}/#{whole} (#{(100.0 * part / whole).round}%)"

      def median(values)
        sorted = values.sort
        return nil if sorted.empty?

        middle = sorted.size / 2
        sorted.size.odd? ? sorted[middle] : ((sorted[middle - 1] + sorted[middle]) / 2.0).round(4)
      end
    end
  end
end
