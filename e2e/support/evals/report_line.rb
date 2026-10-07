require_relative "trace"

module E2E
  module Evals
    # ONE REPORT LINE PER PAID RUN, printed and recorded:
    #
    #   evals: <task> <model> <style> #<n> reach=<t|f> success=<t|f|—>
    #     pass=<t|f|—> rounds=<n> calls=<n> bytes=<request_bytes>
    #     cost=<amount unit> cache=<hit rate> compactions=<n> (mode/trigger×k)
    #     nudged=<n> swept=<n> seconds=<s> [fb=<n>] [stopped=<why>] [<class>]
    #
    # A pure formatter over the RECORD (the lane's `build_record` shape, `Drawing.record` in the
    # unit test): the evals lane prints it from its record, the four graded live lanes from `lane`'s
    # record built off their own reads — one implementation. `bytes` is the sealed request's
    # entries; `swept` and `nudged` are rho's two runner meters — the sweep passes its inbox reader
    # made and the nudges its socket carried while the run ran (`/status`'s `runner.swept` and
    # `runner.nudged`, `daemon.rb` `runner_facts`; the daemon's life, a retired runner's sweeps
    # carried forward) — each the delta the lane read around the run, `—` where a lane read none.
    # `cache` is the prefix-cache hit rate AFTER ROUND 1 (the first round is cold) — the mainline's
    # rounds 2..n pooled off the per-round series (`Trace.after_first_ round_rate`, the headline
    # number the scorecard and the bar read) — with, in parentheses, the two facts beside it when
    # read: `r1=` the first mainline round's rate (the provider's cross-run prefix, recorded, never
    # gated) and `total=` the loop's rate off the progress spend (`cache_read_tokens` /
    # `input_tokens`, six places; 12a's cache columns — every loop pooled, the cost term). A `—` is
    # "not read" (a lane's record carries no series: `cache=— (total=…)`), `0` is "read, none"; the
    # tail's class is whatever the record's verdict names — the bar's `cache under floor` among
    # them. `fb=<n>` leads the tail when the answerer's declared fallback served n refused steps
    # (`facts.refusals_served`): a fact a green line carries, never a class; a record with none
    # served, and one switched only off an unavailable model, prints no token.
    module ReportLine
      FORMAT = "evals: %s %s %s #%s reach=%s success=%s pass=%s rounds=%s calls=%s bytes=%s bytes_max=%s cost=%s cache=%s " \
               "compactions=%s nudged=%s swept=%s seconds=%s%s".freeze
      DASH = "—".freeze

      module_function

      def render(record)
        verdict = Hash(record["verdict"])
        efficiency = Hash(record["efficiency"])
        format(FORMAT, record["task"], record["model"], record["style"] || "nexus", record["run"] || 1,
          tf(verdict["reached"]), tf(verdict["succeeded"]), tf(verdict["task_pass"]),
          number(efficiency["rounds"]), number(efficiency["calls"]), number(efficiency["request_bytes"]),
          number(Hash(efficiency["request_bytes_series"]).values.max),
          cost(efficiency), cache(efficiency), compactions(efficiency),
          number(efficiency["nudged"]), number(efficiency["swept"]),
          number(record["seconds"]), tail(record))
      end

      # A LIVE LANE'S RECORD, off what every lane already holds: the loop
      # row (its tasks), the feed's items, the progress route's spend, the
      # sealed request when the lane read one, the runner meter, and the
      # verdict the lane's own assertions decide. `events: nil` is a feed
      # the lane never read — `compactions=—`, never a `0` it cannot vouch for.
      def lane(task:, model:, row:, events: nil, spend: nil, sealed: nil, seconds: nil, reached: nil, succeeded: nil,
               task_pass: nil, style: "nexus", run: 1, stopped: nil, swept: nil, nudged: nil)
        trace = Trace.new(loops: [{ "id" => Hash(row)["public_id"], "status" => Hash(row)["status"] }],
          graph: Trace::EMPTY_GRAPH, tasks: Array(Hash(row)["tasks"]), events: Array(events), spend: spend,
          sealed: sealed, facts: { "swept" => swept, "nudged" => nudged })
        efficiency = row.nil? ? {} : trace.efficiency
        efficiency = efficiency.merge("compactions" => nil) if events.nil? && !row.nil?
        { "task" => task, "model" => model, "style" => style, "run" => run,
          "verdict" => { "reached" => reached, "succeeded" => succeeded, "task_pass" => task_pass, "class" => nil },
          "efficiency" => efficiency, "seconds" => seconds, "stopped" => stopped }
      end

      def tf(value) = value.nil? ? DASH : (value ? "t" : "f")

      def number(value) = value.nil? ? DASH : value.to_s

      def cost(efficiency)
        amount = efficiency["cost_amount"]
        amount.nil? ? DASH : "#{amount} #{efficiency["cost_unit"]}".strip
      end

      # The rate after round 1, then in parentheses the first round's and
      # the loop-total — each only when read; no parentheses when neither.
      def cache(efficiency)
        series = efficiency["cache_read_series"]
        beside = { "r1" => Trace.first_round_rate(series), "total" => efficiency["cache_hit_rate"] }.compact
        "#{number(Trace.after_first_round_rate(series))}#{beside.empty? ? "" : " (#{beside.map { |name, value| "#{name}=#{value}" }.join(" ")})"}"
      end

      # The total, then the mode/trigger tally in parentheses when any.
      def compactions(efficiency)
        tally = efficiency["compactions"]
        return DASH if tally.nil?

        total = Hash(tally).values.sum
        total.zero? ? "0" : "#{total} (#{Hash(tally).map { |mode, n| "#{mode}×#{n}" }.join(" ")})"
      end

      def tail(record)
        klass = record.dig("verdict", "class")
        served = record.dig("facts", "refusals_served").to_i
        [(" fb=#{served}" if served.positive?), (record["stopped"] && " stopped=#{record["stopped"]}"), (klass && " [#{klass}]")].compact.join
      end
    end
  end
end
