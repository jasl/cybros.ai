require "json"
require "time"
require_relative "../bench_records"
require_relative "job"

module E2E
  module Screen
    # THE DRAWS A SCREEN READS. Each job appends one JSON line per draw to its directory's
    # `records.jsonl`: the record its probe wrote plus the envelope the record stream adds (`arm
    # process recorded_at pid`). A draw is that record tagged with its job's `instrument`, the one
    # fact the record does not carry; the two instruments' records differ in shape, and every read
    # of a record's calls goes through this module, keyed by the instrument.
    module Records
      # The record stream's own file (`BenchRecords`), under the one name every reader uses.
      FILE = BenchRecords::RECORDS
      INSTRUMENTS = %w[compose task].freeze
      # A call's token classes, as every bench records its usage.
      TOKENS = %w[input_tokens output_tokens cache_read_tokens cache_creation_tokens].freeze
      # THE LOST CLASS, a relaunch trigger and never a verdict: a (model, arm) whose lost draws,
      # pooled over the instruments, are more than `share` of its draws AND at least `draws` of
      # them — a share alone would call one lost draw of sixteen a fault. Its two values are the
      # screen's registered watch parameters (`WatchRules::Params#lost_rule`), read from the stamp.
      Lost = Data.define(:share, :draws) do
        def over?(lost, total) = lost >= draws && lost > share * total
      end
      LostCell = Data.define(:model, :arm, :lost, :draws)

      module_function

      def read(path)
        File.readlines(path, encoding: "UTF-8", chomp: true).reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
      end

      # Every registered job's draws, read from its directory (relative to the screen's home, or
      # absolute). A job whose file is missing ended before its first draw, so the batch is not the
      # registered one.
      def load(jobs, home)
        empty = jobs.find { |job| !File.file?(path_of(job, home)) }
        raise Refused, "job #{empty.index} (#{empty.arm} #{empty.instrument} #{empty.model}): no #{path_of(empty, home)}" if empty

        landed(jobs, home)
      end

      # The draws that landed, a job that ended before its first draw holding none: what a stopped
      # batch drew. A record of another arm is not its job's.
      def landed(jobs, home)
        jobs.flat_map do |job|
          written(job, home).map do |record|
            unless record["arm"] == job.arm
              raise Refused, "job #{job.index}: a record of arm #{record["arm"].inspect} in #{job.arm}'s directory"
            end

            record.merge("instrument" => job.instrument)
          end
        end
      end

      # One job's records as its probe wrote them, none when it ended before its first draw.
      def written(job, home)
        path = path_of(job, home)
        File.file?(path) ? read(path) : []
      end

      def path_of(job, home) = File.join(File.expand_path(job.dir, home), FILE)

      # A pair's draws for a dry run: `<dir>/<instrument>/**/records.jsonl`, the arm each record's own.
      def pair(dir)
        INSTRUMENTS.flat_map do |instrument|
          Dir[File.join(dir, instrument, "**", FILE)].sort.flat_map do |path|
            read(path).map { |record| record.merge("instrument" => instrument) }
          end
        end
      end

      # THE BATCH IS THE REGISTERED ONE, or nothing is read: no harness fault, no draw read twice, no
      # record written before the launch, and exactly the draws the job table registers — each job's
      # own objectives and samples, never every objective.
      def check!(draws, jobs:, launched_at:)
        refuse("a harness fault, not a draw", draws.select { |draw| fault?(draw) })
        twice = draws.group_by { |draw| key(draw) }.select { |_key, same| same.length > 1 }.keys
        raise Refused, "#{twice.length} draw(s) read twice: #{twice.first(6).map { |k| k.join(" ") }.join("; ")}" unless twice.empty?

        since = Time.iso8601(launched_at)
        refuse("recorded before launched_at #{launched_at}", draws.select { |draw| Time.iso8601(draw.fetch("recorded_at")) < since })
        registered = jobs.flat_map { |job| registered(job) }
        drawn = draws.map { |draw| key(draw) }
        missing = registered - drawn
        beyond = drawn - registered
        unless missing.empty? && beyond.empty?
          raise Refused, "not the registered batch: #{missing.length} missing (#{missing.first(6).map { |k| k.join(" ") }.join("; ")}), " \
                         "#{beyond.length} beyond it (#{beyond.first(6).map { |k| k.join(" ") }.join("; ")})"
        end
      end

      def registered(job)
        samples = (job.sample_first...(job.sample_first + job.n)).to_a
        job.objectives.product(samples).map { |objective, sample| [job.arm, job.instrument, job.model, objective, job.style, sample] }
      end

      def key(draw) = draw.values_at("arm", "instrument", "model", "objective", "style", "sample")

      def id(draw) = "#{draw["arm"]} #{draw["instrument"]} #{draw["model"]} #{draw["objective"]} ##{draw["sample"]}"

      def refuse(why, draws)
        raise Refused, "#{why}: #{draws.first(6).map { |draw| "#{id(draw)} #{errors(draw).join(" / ")}".strip }.join("; ")}" unless draws.empty?
      end

      # The (model, arm) cells over the lost-draw floor, pooled over the instruments.
      def over_lost(draws, rule:)
        draws.group_by { |draw| draw.values_at("model", "arm") }.filter_map do |(model, arm), cell|
          lost = cell.count { |draw| lost?(draw) }
          LostCell.new(model: model, arm: arm, lost: lost, draws: cell.length) if rule.over?(lost, cell.length)
        end
      end

      def select(draws, arm:, instrument: nil, models: nil, objectives: nil)
        draws.select do |draw|
          draw["arm"] == arm && (instrument.nil? || draw["instrument"] == instrument) &&
            (models.nil? || models.include?(draw["model"])) && (objectives.nil? || objectives.include?(draw["objective"]))
        end
      end

      # ── one record's calls, by its instrument ────────────────────────────
      # A compose draw is one call and, when its script was refused, one repair call; a task draw is
      # the messages it ran (up to three), the failing message's error on the record.

      # Every error the draw carries, as every reader of a record reads them (`BenchRecords.errors`).
      def errors(draw) = BenchRecords.errors(draw)

      # A draw carrying a harness fault (`BenchRecords.harness_fault?`, the one rule) is refused with
      # its batch, never read as lost.
      def fault?(draw) = errors(draw).any? { |error| BenchRecords.harness_fault?(error) }

      # LOST: a call ended in an error left after the client's retries — a failed call, never a
      # harness fault. A compose draw is lost on its first call (a failed repair still reached the
      # model); a task draw on ANY of its messages, since its scored message may be the second or
      # the third.
      def lost?(draw) = losing(draw).any? { |error| !BenchRecords.harness_fault?(error) }

      def losing(draw)
        case draw.fetch("instrument")
        when "compose" then [draw["error"].to_s].reject(&:empty?)
        when "task" then errors(draw)
        else raise ArgumentError, "no instrument #{draw["instrument"].inspect}"
        end
      end

      def usages(draw) = calls_of(draw).filter_map { |call| call["usage"] }

      def calls(draw) = [calls_of(draw).length, 1].max

      def retries(draw) = calls_of(draw).sum { |call| Array(call["retries"]).length }

      def seconds(draw) = calls_of(draw).sum { |call| call["seconds"].to_f }

      # Each call's own facts under one set of names: a compose draw's repair call carries its facts
      # under `repaired_*`.
      def calls_of(draw)
        case draw.fetch("instrument")
        when "compose"
          repaired = draw.select { |name, _| name.start_with?("repaired_") }.transform_keys { |name| name.delete_prefix("repaired_") }
          [draw, *(draw.key?("repaired") ? [repaired] : [])]
        when "task" then messages(draw)
        else raise ArgumentError, "no instrument #{draw["instrument"].inspect}"
        end
      end

      def messages(draw) = Array(draw["messages"])

      private_class_method :path_of, :registered, :refuse, :losing, :calls_of, :messages
    end
  end
end
