require_relative "../bench_records"
require_relative "../provider_lanes"
require_relative "job"
require_relative "records"

module E2E
  module Screen
    # THE SMOKE, before the stamp: one draw per (smoke lane, arm) through the real probe, and on a
    # cache lane two draws in one job, drawn serially, so the second reads the prefix the first
    # wrote. It is a FAULT AND CACHE CHECK, never a pricer: two draws of one objective cannot price a
    # heavy-tailed lane, so the screen is sized from registered rates and the smoke only says the
    # lanes run. It fails on a non-zero exit, a missing draw, a draw with no usage, a harness-fault
    # class, or a cache lane whose second draw read less than nine tenths of the first draw's prompt
    # (`input_tokens` is the prompt with the cache classes folded in, as the receipt counts it). A
    # failed smoke stamps nothing and spends no relaunch.
    module Smoke
      CACHE_SHARE = 0.9

      # The outcome: `ok`, the stamp's lines, the priced spend, and the draws' ids.
      Result = Data.define(:ok, :lines, :spend_usd, :ids)

      module_function

      def jobs(definition)
        spec = definition.smoke
        models = spec.fetch("models")
        cached = spec.fetch("cache_check", [])
        definition.arms.flat_map { |arm| models.map { |model| [arm, model] } }.each_with_index.map do |(arm, model), position|
          Job.new(index: position + 1, arm: arm.id, instrument: spec.fetch("instrument"), model: model,
            objectives: [spec.fetch("objective")], n: cached.include?(model) ? 2 : 1, sample_first: 1,
            dir: ["smoke", arm.id, spec.fetch("instrument"), model.tr("/", "_")].join("/"),
            lane: ProviderLanes.provider_of(model), row: (arm.row if spec.fetch("instrument") == "compose"), style: definition.style)
        end
      end

      def log(home, job) = File.join(home, "smoke", "logs", "#{job.index}.log")

      # Reads what each smoke job left: its exit, its draws, their usage and error classes.
      def read(home, jobs, pricer:)
        readings = jobs.map { |job| reading(job, exit_of(home, job), Records.written(job, home)) }
        draws = readings.flat_map { |job, _, taken| taken.map { |record| [job, record] } }
        Result.new(ok: readings.all? { |_, lines, _| lines.all? { |_, ok| ok } },
          lines: readings.flat_map { |_, lines, _| lines.map(&:first) },
          spend_usd: draws.sum { |_, record| Float(pricer.call(record)) },
          ids: draws.map { |job, record| "#{job.index}:#{record["objective"]}##{record["sample"]}" })
      end

      def cache_holds?(first, second) = second.fetch("cache_read_tokens", 0) >= CACHE_SHARE * first.fetch("input_tokens")

      # One job's `[job, [[line, ok]…], records]`.
      def reading(job, status, records)
        key = "smoke.#{job.arm}.#{job.slug}"
        usages = records.map { |record| usage_of(job, record) }
        problem = problem_of(job, status, records, usages)
        return [job, [["#{key}=FAIL #{problem}", false]], records] if problem

        first = usages.first
        line = "#{key}=ok exit=0 draws=#{records.size} in=#{first["input_tokens"]} out=#{first["output_tokens"]} " \
               "cache_read=#{first.fetch("cache_read_tokens", 0)} cache_creation=#{first.fetch("cache_creation_tokens", 0)}"
        return [job, [[line, true]], records] unless job.n == 2

        held = cache_holds?(first, usages.last)
        cache = "smoke.cache.#{job.slug}.#{job.arm}=#{usages.last.fetch("cache_read_tokens", 0)} ≥ #{CACHE_SHARE} × #{first["input_tokens"]} #{held ? "ok" : "FAIL"}"
        [job, [[line, true], [cache, held]], records]
      end

      def problem_of(job, status, records, usages)
        if status != 0 then "exit=#{status.inspect}"
        elsif records.size != job.n then "#{records.size} draws of #{job.n}"
        elsif (fault = BenchRecords.faults(records).first)
          "a harness fault: #{fault[0, 120]}"
        elsif usages.any?(&:nil?) then "a draw with no usage"
        end
      end

      # The first call's usage, where each instrument records it.
      def usage_of(job, record)
        case job.instrument
        when "compose" then record["usage"]
        when "task" then Array(record["messages"]).first&.fetch("usage", nil)
        else raise ArgumentError, "no smoke reading for #{job.instrument}"
        end
      end

      def exit_of(home, job)
        path = log(home, job)
        File.exist?(path) ? File.read(path, encoding: Encoding::UTF_8)[/^exit=(-?\d+)$/, 1]&.then { |status| Integer(status) } : nil
      end
      private_class_method :reading, :problem_of, :usage_of, :exit_of
    end
  end
end
