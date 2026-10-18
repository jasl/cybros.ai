require "time"
require_relative "../gallery/shapes"
require_relative "../printed_envelope"
require_relative "claims"
require_relative "task_reads"
require_relative "race_losers"
require_relative "sealed_request"

module E2E
  module Evals
    # THE KERNEL'S TRACE OF ONE RUN, read the gallery's way
    # (`live_gallery_test.rb:307-317`): the graph route's JSON (`nodes`,
    # `edges`, `mermaid`), the loop row's task rows with each tool call's
    # `tool_input` joined from the single-task read, the feed's four item
    # types — plus the loop's `progress.spend`, the sealed request of the
    # last completed round (`SealedRequest`: `{task_key, entries,
    # request_options}`; nil when no round completed), and the FACTS the driver
    # recorded (what it saw the model do that no route serves: which tools
    # turn 1 called, whether the watch printed its background line, the
    # reply `rho result` printed, the style the daemon ran under, the
    # summaries' bodies). Every structural read delegates to
    # `E2E::Gallery`'s functions — the trace re-implements none of them.
    # `loops` lists every loop the run backed, the primary first, each
    # `{id, status}`.
    Trace = Data.define(:loops, :graph, :tasks, :events, :spend, :sealed, :facts)

    class Trace
      EMPTY_GRAPH = { "nodes" => [], "edges" => [], "mermaid" => "" }.freeze
      # The kernel's wire names for the graph verbs: an aliased call
      # (`Workflow`, `Agent`) resolves to its canonical NAME on the task row
      # (`expand_round.rb:165-175`, the alias kept beside it), so one
      # spelling reads every style row.
      TASK = "delegate_task".freeze
      # The calls that read — a shell command counted whatever it runs. The mainline's carry the text
      # they returned (`output_of`): what a later brief's names are read against.
      READ_CLASS = %w[read ls find grep glob bash].freeze

      def self.empty(facts: {})
        new(loops: [], graph: EMPTY_GRAPH, tasks: [], events: [], spend: nil, sealed: nil, facts: facts)
      end

      def self.draw(graph, tasks, events, facts: {}, loops: [{ "id" => "loop-1", "status" => "completed" }], spend: nil, sealed: nil)
        new(loops: loops, graph: graph, tasks: tasks, events: events, spend: spend, sealed: sealed,
          facts: facts.transform_keys(&:to_s))
      end

      def self.mainline_keys(graph) = Gallery.mainline_keys(Hash(graph))

      def triple = [graph, tasks, events]

      def loop_id = loops.first&.fetch("id")
      def status = loops.first&.fetch("status")
      def fact(name) = facts[name.to_s]
      def with_facts(more) = with(facts: facts.merge(more.transform_keys(&:to_s)))

      # ── the gallery's functions, over this trace ─────────────────────────
      def nodes_of(kind:) = Gallery.nodes_of(graph, kind: kind)
      def node(key) = Gallery.node(graph, key)
      def edge?(from, to) = Gallery.edge?(graph, from, to)
      def edges_into(key) = Gallery.edges_into(graph, key)
      def edges_out_of(key) = Gallery.edges_out_of(graph, key)
      def task(key) = Gallery.task(tasks, key)
      def tool_rows(name) = Gallery.tool_rows(tasks, name)
      def events_of(type) = Gallery.events_of(events, type)
      def payloads(type) = Gallery.payloads(events, type)
      def fan_under(call) = Gallery.fan_under(graph, call)
      def continuations(call) = Gallery.continuations(graph, call)
      def reachable?(from, to) = Gallery.reachable?(graph, from, to)
      def fan_signature(round_key) = Gallery.fan_signature(tasks, round_key)

      # ── the reads every family shares ────────────────────────────────────
      def task_rows = tool_rows(TASK)
      def input_of(row) = Hash(row["tool_input"])
      # The text a call returned, where the trace read joined it — a mainline round's read-class call
      # (`MemberPlane#join_task_detail`) — else "".
      def output_of(row) = row["output"].to_s
      # The rows one round fanned: `after` names the round (`shapes.rb:343`).
      def fanned_by(round_key) = calls.select { |row| Array(row["after"]).include?(round_key) }
      def first_round_rows = fanned_by("r1")
      # `rho result`'s text, as the driver recorded it; "" when none.
      def reply = fact(:reply).to_s
      # The nodes a call placed (`Gallery.placed_by`): its steps and what its stages placed, never a
      # member's own rounds.
      def under(call) = Gallery.placed_by(graph, call)

      # ── the counts the record prints (never asserted) ────────────────────
      def rounds = tasks.select { |row| row["kind"] == "model_task" }

      # The rounds the graph marks `mainline: true` (`Trace.mainline_keys`); a
      # task row carries no mark. A trace with NO graph — a lane's record
      # (`ReportLine.lane`) reads none — has nothing to read and counts
      # every round, as the lanes always printed.
      def mainline_rounds
        return rounds if Array(graph["nodes"]).empty?

        keys = self.class.mainline_keys(graph)
        rounds.select { |row| keys.include?(row["key"]) }
      end

      def calls = tasks.select { |row| row["kind"] == "tool_task" }

      # THE MAINLINE'S OWN CALLS: the calls a round the kernel marks the mainline's made (`after` names the
      # round that made a call). A task branch's root and its own rounds make calls keyed `rNtM` on
      # the same counter, and those are the branch's.
      def mainline_calls
        keys = self.class.mainline_keys(graph)
        calls.select { |row| Array(row["after"]).intersect?(keys) }
      end
      def called = calls.map { |row| row["tool_name"].to_s }.tally
      def rounds_settled = rounds.count { |row| Gallery::TERMINAL_TASK_STATUSES.include?(row["status"]) }
      def compactions = payloads("context_compacted")
      def compaction_tally = compactions.map { |p| "#{p["mode"]}/#{p["trigger"]}" }.tally
      # THE ATTENTION IS THE TRACED LOOPS': an `attention_required` on a loop the run never traced —
      # a receipt-woken turn that outlived the driver, appended after the run's stop marked
      # `traced: false` (`EvalsLaneTest#loops_after_stop`; 12a L7 stops it by design) — is the
      # model's word to nobody, kept apart as `untraced_attention_reasons` and never a kernel signal;
      # an event naming no loop is the run's.
      def attention_reasons = reasons_of(payloads("attention_required").reject { |p| untraced?(p) })
      def untraced_attention_reasons = reasons_of(payloads("attention_required").select { |p| untraced?(p) })
      def untraced_loop_ids = loops.select { |row| row["traced"] == false }.map { |row| row["id"] }
      def round_errors = rounds.filter_map { |row| row.dig("error", "key") }.tally

      # Each failed round's error DETAIL under its key, `{key => {detail => n}}`: the brake's refusal
      # and the refusal of an input the kernel could not store share one key and differ by the detail
      # alone (`Scorecard.kernel_refusals`). An error with no detail is its key's tally alone.
      def round_error_details
        errors = rounds.filter_map { |row| row["error"] }.select { |error| error["detail"] }
        errors.group_by { |error| error["key"] }.transform_values { |same| same.map { |error| error["detail"] }.tally }
      end

      # ── a provider's refusals, off the task rows ─────────────────────────
      # A step's summary (`result`) carries a DECLINED finish — a classifier's refusal or a content
      # block — as `finish_quality`, the provider's category beside it as `refusal_category`; a step
      # re-run on another model carries `model_change {from, reason[, category]}`, the row's own
      # model naming the one it moved to. The kernel's failure word for a refusal that stood is
      # `model_refused`, which is also a refused switch's `reason`.
      DECLINED = %w[refused blocked].freeze
      REFUSED = "model_refused".freeze
      # The one tally key for a row with no category: the provider named none, or the row predates
      # the refusal_category column (a record the old kernel wrote). Never inferred from logs.
      NO_CATEGORY = "none".freeze

      # THE REFUSALS THAT STOOD: every model row whose summary carries a declined finish, whatever
      # its status — the kernel fails such a step, and a record from before it did carries the row
      # `completed` with the quality — less a settled race's losers (`RaceLosers.of`):
      # a refusal that beat its race's loser cancel settled after the race had its answer, and
      # nothing waited for it. The traced loop's rows, as every structural fact: a spawned child
      # conversation's own loops are not read.
      def refused_rows
        losers = RaceLosers.of(graph, tasks)
        rounds.select { |row| DECLINED.include?(row.dig("result", "finish_quality")) && !losers.include?(row["key"]) }
      end

      # The steps a declared fallback SERVED: re-run after a refusal and answered there — the row
      # completed. One the fallback declined too failed (a refusal that stood), and one a stop cut
      # before it answered was served nothing.
      def served_rows
        rounds.select { |row| row.dig("result", "model_change", "reason") == REFUSED && row["status"] == "completed" }
      end

      # `{model => {category => n}}`: each refusal that stood under the row's own model, and each
      # refused switch under the model it moved from — a step whose fallback declined too counts both.
      def refusals
        stood = refused_rows.map { |row| [row.dig("model", "model"), row.dig("result", "refusal_category")] }
        switched = rounds.filter_map do |row|
          change = row.dig("result", "model_change")
          [change["from"], change["category"]] if change && change["reason"] == REFUSED
        end
        (stood + switched).group_by(&:first).transform_values { |pairs| pairs.map { |_, category| category || NO_CATEGORY }.tally }
      end

      def model_switches = rounds.count { |row| row.dig("result", "model_change") }

      # The first refusal that stood, in the kernel's own words for the reading model; nil when
      # none carries one.
      def refusal_detail = refused_rows.filter_map { |row| row.dig("error", "detail") }.first

      # The kernel's own mail on the feed — a task's receipt, a child's
      # reply; a person's or a peer's word names its kind and is no receipt.
      KERNEL_ORIGINS = %w[task_result child].freeze
      def receipts = payloads("input_accepted").count { |p| KERNEL_ORIGINS.include?(p["origin"]) }

      # WHEN THE RUN WAS STOPPED, off the feed: the primary loop's first `canceling`/`canceled`
      # status — a harness stop cancels the conversation before the trace is salvaged, so its item is
      # on the feed read after it — else the latest turn_status, else nil. The record's `started_at +
      # seconds` is never the stop: `seconds` covers the settle, the verification and the artifact.
      STOPPING_STATUSES = %w[canceling canceled].freeze
      def stopped_at
        statuses = events_of("turn_status")
        stop = statuses.find do |item|
          item.dig("payload", "run_public_id") == loop_id && STOPPING_STATUSES.include?(item.dig("payload", "run_status"))
        end
        (stop || statuses.last)&.fetch("occurred_at", nil)
      end

      def efficiency
        spend = Hash(self.spend)
        { "rounds" => mainline_rounds.size, "calls" => calls.size, "request_bytes" => SealedRequest.bytes(sealed),
          "request_bytes_series" => request_bytes_series, "cache_read_series" => cache_read_series,
          "cost_amount" => spend["cost_amount"], "cost_unit" => spend["cost_unit"],
          "input_tokens" => spend["input_tokens"], "output_tokens" => spend["output_tokens"],
          "cache_read_tokens" => spend["cache_read_tokens"], "cache_hit_rate" => spend["cache_hit_rate"],
          "cost_by_model" => spend["by_model"],
          "compactions" => compaction_tally, "nudged" => fact(:nudged), "swept" => fact(:swept) }
      end

      # THE PER-ROUND CACHE SERIES (measured-2, the cache audit of
      # 2026-09-16): each mainline round's usage as the transcript served it
      # (the kernel's per-round receipt — `input_tokens`, `cache_read_
      # tokens`; a wire that reported no cache read on a round reads 0
      # there), `{key => [input, read]}` in row order, so a cold first
      # round, a compaction's designed miss and a prefix that moved at
      # round k are readable off the record instead of one loop-total
      # median; the bytes series' rules — a round with no usage left out,
      # nil when none carries one ("not read", never an empty series). A
      # SWITCHED round is left out too, a designed miss: its row's
      # `model_change` says it ran on another model than the prefix before
      # it, so its usage is that model's cold write, never the prefix's.
      def cache_read_series
        series = mainline_rounds.reject { |row| row.dig("result", "model_change") }.filter_map do |row|
          usage = Hash(row["usage"])
          [row["key"], [Integer(usage["input_tokens"]), Integer(usage["cache_read_tokens"] || 0)]] if usage.key?("input_tokens")
        end.to_h
        series.empty? ? nil : series
      end

      # The first mainline round's hit rate records provider reuse from earlier runs or sibling loops;
      # it is not gated. Return nil without usable input and use this one derivation for both the
      # report and scorecard.
      def self.first_round_rate(series)
        input, read = Hash(series).values.first
        return nil if input.to_i.zero?

        (read.to_f / input).round(4)
      end

      # Pool cache-read tokens over input tokens for mainline rounds after the cold first round. A mean
      # of per-round percentages would weight tiny and large rounds equally despite token-based
      # cost. Branch rounds belong to their branches; loop-total spend remains a separate metric.
      # Return nil when no usable post-first-round series exists.
      def self.after_first_round_rate(series)
        rest = Hash(series).values.drop(1)
        input = rest.sum { |tokens, _read| tokens.to_i }
        return nil if input.zero?

        (rest.sum { |_tokens, read| read.to_i }.to_f / input).round(4)
      end

      # The rounds the bar reads: every mainline round after the first (a
      # 2-round run has one); 0 with no series.
      def self.measured_rounds(series) = [Hash(series).size - 1, 0].max

      # THE PER-ROUND SEALED SIZES: each mainline round's `request_bytes` as its task read served it
      # (the kernel's stored `content_bodies.byte_size` of the sealed request — the wall's own
      # number, never re-derived here), `{key => bytes}` in row order; a round never scheduled has
      # none and is left out; nil when no round carries one (a lane's record reads no round detail;
      # a trace before the column) — "not read", never an empty series.
      def request_bytes_series
        series = mainline_rounds.filter_map { |row| [row["key"], row["request_bytes"]] if row.key?("request_bytes") }.to_h
        series.empty? ? nil : series
      end

      # ── the envelope's `<call>` line, watched ────────────────────────────
      # A tool result a model reads names the call that produced it on a `<call>` line — the
      # element's one harness spelling is `PrintedEnvelope::CALL`, which the journeys check against
      # the kernel's bytes. Two ways a model can misread that line, each a count on every record: it
      # writes the line as the call it meant to make — a leaked call — or it runs a delivered call
      # again instead of reading its result.
      LEAKED_CALL = /\A\s*#{Regexp.escape(PrintedEnvelope::CALL)}.*#{Regexp.escape(PrintedEnvelope::CALL_END)}\s*\z/
      # What may change the files between a result and its call made again: an edit, a write, or a
      # shell command other than the one repeated.
      MUTATING_TOOLS = %w[edit write].freeze
      SHELL = "bash".freeze

      # The settled model rounds — the mainline's and every member's — that made no tool call and whose
      # own text writes the element as a call: on a line of its own, outside a code fence. A reply
      # QUOTING the delivered line as its evidence — inside a sentence, in backticks, in a fence — is
      # no leak. nil when no round's text was read (a drawing, a record from before the join).
      def leaked_calls
        read = rounds.select { |row| row.key?("output") }
        read.empty? ? nil : read.count { |row| leaked?(row) }
      end

      # The tool calls a model made that run again an authored tool step its own thread READ, with
      # that step's name and input, after the step completed and with nothing that may change the
      # files settled in between: a delivered result run again rather than read. A step the thread
      # never read, and a call made again after an edit, a write or another command — verifying a
      # change — are not counted.
      def reissued_calls
        authored = Array(graph["nodes"]).select { |node| node["kind"] == "tool_task" && self.node(node["expansion_parent"])&.fetch("kind", nil) == "tool_task" }
          .filter_map { |node| task(node["key"]) }
        placed = authored.map { |row| row["key"] }
        calls.reject { |row| placed.include?(row["key"]) }.count do |row|
          read = thread_reads(node(row["key"])&.fetch("expansion_parent", nil))
          authored.any? do |step|
            read.include?(step["key"]) && same_call?(step, row) && later?(row["created_at"], step["completed_at"]) &&
              !changed_between?(step, row)
          end
        end
      end

      def structure_facts
        owed = TaskReads.owed(self)
        { "round_errors" => round_errors, "round_error_details" => round_error_details,
          "attention_reasons" => attention_reasons, "untraced_attention_reasons" => untraced_attention_reasons,
          "rounds_settled" => rounds_settled, "receipts" => receipts, "called" => called,
          "run_status" => status, "leaked_calls" => leaked_calls, "reissued_calls" => reissued_calls,
          "refused_steps" => refused_rows.size, "refusals" => refusals, "refusals_served" => served_rows.size,
          "model_switches" => model_switches, "refusal_detail" => refusal_detail,
          "task_reads" => owed, "kernel_check" => TaskReads.check(owed, fact(:task_requests)) }
      end

      private

        def untraced?(payload) = untraced_loop_ids.include?(payload["run_public_id"])
        def reasons_of(payloads) = payloads.map { |p| p["reason"].to_s }.tally
        def same_call?(one, other) = one["tool_name"] == other["tool_name"] && input_of(one) == input_of(other)

        # `stamp` after `than`, both ISO 8601 off the loop row; a row without a stamp is never after.
        def later?(stamp, than) = !stamp.nil? && !than.nil? && Time.iso8601(stamp) > Time.iso8601(than)

        def leaked?(round)
          Gallery::TERMINAL_TASK_STATUSES.include?(round["status"]) && fanned_by(round["key"]).empty? &&
            Claims::Namings.lines(round["output"].to_s).any? { |line| LEAKED_CALL.match?(line) }
        end

        # What a thread read: the round that made a call, and each round it continues
        # (`expansion_parent`, while that is a round) — its history — each round's `input_from` and
        # `result_from`. A fresh model step starts a thread of its own, so a step read by a sibling
        # it follows is not read by it.
        def thread_reads(key)
          round = node(key)
          return [] unless round && round["kind"] == "model_task"

          Array(round["input_from"]) + Array(round["result_from"]) + thread_reads(round["expansion_parent"])
        end

        # A call that may change the files settled after `step` completed and by the time `again` was
        # made. A canceled one was stopped, never finished; ties at a stamp's second are read as
        # before the step, so a sibling finishing beside it is never between.
        def changed_between?(step, again)
          calls.any? do |other|
            other["status"] != "canceled" && later?(other["completed_at"], step["completed_at"]) &&
              !later?(other["completed_at"], again["created_at"]) && changes_files?(other, again)
          end
        end

        def changes_files?(other, again)
          MUTATING_TOOLS.include?(other["tool_name"]) || (other["tool_name"] == SHELL && input_of(other) != input_of(again))
        end
    end
  end
end
