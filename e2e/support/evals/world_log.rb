require "fileutils"
require "json"
require "time"
require_relative "../secret_hygiene"

module E2E
  module Evals
    # THE WORLD'S LOG PER PAID RUN: after every run the lane copies, REDACTED
    # (`E2E::SecretHygiene.redact`), into
    # `e2e/artifacts/evals/<label>/invocation-*/logs/<task>.<model>.<style>.<n>/`, each as the RUN'S WINDOW
    # (`windows`): the world's `*.log` under the operator handle's `log_dir` (the run root:
    # `server.log`, `model_runner.log`, `jobs.log`, `rails_db_prepare.log`, …), the daemon's
    # `daemon.log` and `log/rho.log` (`RhoDaemon#log_path`, `#rho_log_path`), the runner-mode home's
    # pair when the run had one, and each world process's own Rails log (`rails.log`,
    # `jobs.rails.log`, `model_runner.rails.log`, the files the world's `RAILS_LOG_FILE` env names;
    # never the checkout's shared, rotating `nexus/log/development.log`). One world and one daemon
    # home serve one invocation and none of those files rotates — the hosts write their stdout for
    # the world's life, the daemon opens `daemon.log` in append mode — so a whole copy of run N
    # would repeat runs 1..N. The run's cut is a byte offset taken before its turn opens (`mark`),
    # and a file shorter than its mark at the end was reopened by a restarted host and is copied
    # from its top. A log written once at the world's boot (`rails_db_prepare.log`) is an empty
    # window in every run. The failure dump (`NexusServer#failure_dump!`) stays as it is — whole
    # files of the run root alone, never a daemon home (`sources` is that list plus the homes for a
    # caller that wants every line); this copy is per run and on the success path too.
    #
    # WHAT NO RUN'S WINDOW HOLDS IS COPIED ONCE, beside the runs' dirs: the world booted before the
    # lane's process, so its logs as the first group opens are its boot — copied whole, once, as
    # `logs/boot.world/` (`world_sources`); a group's opening — the hosts' start in the first
    # group, the ceremony's and the keys' requests, the daemon's and the runner's boot (the
    # settings and adaptation rows read then) — lands before its first run's marks, so it is copied
    # as `logs/boot.<configuration>/` from the world's marks taken before the group opened
    # (`world_windows`, then `since`: a log that appeared inside the opening, from its top) and
    # the homes' pair whole (`home_sources`: each home is the group's own). A green world removes
    # its run root and the homes, so these copies are the boot's one record.
    #
    # Pure over paths: the lane names the sources, the unit test writes
    # its own. A source that does not exist is skipped and listed as such
    # in `MANIFEST`, never a raised lane.
    #
    # THE STREAM UNDER A STOP (`in_flight`): the model runner's window holds every frame the kernel
    # broadcast while the run's rounds ran — Solid Cable writes each one as an INSERT whose payload
    # is the frame, hex-escaped — so a stop before any round settled can be read as a model still
    # streaming or a loop that sent nothing. The lane reads it off the live file under a harness
    # stop; a re-score reads the same window off the copy, through the same reader.
    module WorldLog
      MANIFEST = "MANIFEST".freeze
      # The per-process Rails logs under a run root, by their one suffix.
      RAILS_LOG_SUFFIX = "rails.log".freeze
      Window = Data.define(:name, :path, :from)
      # The window whose lines carry the model runner's broadcasts, by the name the copy gives it.
      MODEL_RUNNER_LOG = "nexus.model_runner.rails.log".freeze
      # The line Solid Cable writes per broadcast. Its VALUES are the channel, the channel's hash,
      # the row's `created_at` (UTC, written with no zone) and the payload — the two text columns
      # hex-escaped. The `[ActionCable] Broadcasting` line beside it truncates the frame and is
      # never read.
      CABLE_INSERT = 'INSERT INTO "solid_cable_messages"'.freeze
      CABLE_VALUES = /VALUES \('\\x[0-9a-f]*', -?\d+, '([^']+)', '\\x([0-9a-f]*)'\)/
      # The transcript stream's deltas (`Conversations::TranscriptStream`), what a round streams
      # while it runs, beside the progress stream's `round_started` (an attempt dialled) and the
      # transcript's `stream_reset` (a stream the kernel restarted).
      DELTAS = %w[text_delta reasoning_delta tool_call_started tool_call_arguments_delta].freeze
      ROUND_STARTED = "round_started".freeze
      STREAM_RESET = "stream_reset".freeze

      module_function

      # A window opened NOW on every log a run copies, named as its whole
      # copy would be: the sources in their order, then the Rails logs —
      # taken before the run's turn opens, so each copy is the run's own
      # lines. A container runner writes its container's stdout into its
      # `daemon.log` when it stops, and the restart that opens the next
      # run stops it, so that window holds the previous run's container.
      def windows(handle:, daemon:, runner: nil)
        sources(handle: handle, daemon: daemon, runner: runner).map { |name, path| mark(name, path) } +
          rails_windows(handle: handle)
      end

      # `name => path`, in the order they are written: the world's own logs
      # first, then the daemon's, then the runner's. The names stay flat
      # so two homes' `daemon.log` cannot collide. The Rails logs are not
      # here: they ride as windows (`rails_windows`).
      def sources(handle:, daemon:, runner: nil)
        world_sources(handle: handle).reject { |_name, path| rails_log?(path) }
          .merge(home_sources(daemon: daemon, runner: runner))
      end

      # Every one of the world's logs under the run root, its Rails logs
      # too, by the name every copy gives it: the world's boot, whole.
      def world_sources(handle:) = world_logs(handle).to_h { |path| [source_name(path), path] }

      # Both homes' pair: the daemon's, then the runner-mode home's when
      # the group has one.
      def home_sources(daemon:, runner: nil)
        { "daemon.log" => daemon.log_path, "rho.log" => daemon.rho_log_path,
          **(runner ? { "runner.daemon.log" => runner.log_path, "runner.rho.log" => runner.rho_log_path } : {}) }
      end

      # A window opened NOW on every one of the world's logs, the Rails logs
      # too: a group's opening, marked before its daemon and the hosts start.
      def world_windows(handle:) = world_sources(handle: handle).map { |name, path| mark(name, path) }

      # The world's every log NOW as a window from its mark among `marks`,
      # or from its top when it appeared after them — the hosts' own logs,
      # opened by their start inside the group's opening.
      def since(marks, handle:)
        from = marks.to_h { |window| [window.path, window.from] }
        world_sources(handle: handle).map { |name, path| Window.new(name: name, path: path, from: from.fetch(path, 0)) }
      end

      # A window opened NOW on each of the world's Rails logs — taken before
      # the run's turn opens, so the copy is the run's own lines.
      def rails_windows(handle:)
        world_logs(handle).select { |path| rails_log?(path) }.map { |path| mark(source_name(path), path) }
      end

      # A window opened NOW on a file: its size, or 0 when it is not there yet.
      def mark(name, path)
        Window.new(name: name, path: path, from: (File.file?(path) ? File.size(path) : 0))
      end

      # Writes every source whole and every window from its mark; answers
      # the files written, and leaves a MANIFEST naming each source, its
      # bytes, and what was skipped.
      def copy(into:, sources:, windows: [], redact: SecretHygiene.method(:redact))
        FileUtils.mkdir_p(into)
        lines = []
        written = sources.filter_map do |name, path|
          next skip(lines, name, path) unless File.file?(path)

          write(into, name, redact.call(read(path, 0)), lines, path)
        end
        written += Array(windows).filter_map do |window|
          next skip(lines, window.name, window.path) unless File.file?(window.path)

          from = from_of(window)
          lines << "#{window.name}: window from byte #{from}#{from.zero? && window.from.positive? ? " (reopened under its mark)" : ""}"
          write(into, window.name, redact.call(read(window.path, from)), lines, window.path)
        end
        File.write(File.join(into, MANIFEST), "#{lines.join("\n")}\n")
        written
      end

      # The loop's frames on the model runner's window: `{task_key, frames, by_type, first_frame_at,
      # last_frame_at, last_frame_age_s, attempts, stream_resets, unparsed}` — `frames` the deltas,
      # `task_key` the round the last `round_started` dialled and `attempts` its dials, the age the
      # seconds from the last delta to `stopped_at` (ISO 8601; nil without one). A line that does not
      # parse — a live file's partial last INSERT, a payload that is not JSON — is skipped and
      # counted. nil ("not read") when there is no such window or it holds no INSERT at all: logging
      # off or a raised log level, never a loop that sent nothing.
      def in_flight(windows:, loop_id:, stopped_at:)
        window = Array(windows).find { |candidate| candidate.name == MODEL_RUNNER_LOG }
        return nil if window.nil? || !File.file?(window.path)

        inserts = read(window.path, from_of(window)).each_line.select { |line| line.include?(CABLE_INSERT) }
        return nil if inserts.empty?

        parsed = inserts.map { |line| cable_frame(line) }
        stream_of(parsed.compact.select { |_at, frame| frame["run_public_id"] == loop_id },
          stopped_at: stopped_at, unparsed: parsed.count(&:nil?))
      end

      # `[created_at, frame]` off one INSERT — the frame the transcript's `event` or the progress
      # stream's `frame`, `{}` for a payload that carries neither — or nil when the line does not parse.
      def cable_frame(line)
        match = CABLE_VALUES.match(line)
        return nil if match.nil?

        payload = JSON.parse([match[2]].pack("H*").force_encoding(Encoding::UTF_8))
        [Time.iso8601("#{match[1].tr(" ", "T")}Z"), payload["event"] || payload["frame"] || {}]
      rescue JSON::ParserError, ArgumentError, TypeError
        nil
      end

      def stream_of(frames, stopped_at:, unparsed:)
        deltas = frames.select { |_at, frame| DELTAS.include?(frame["type"]) }
        dials = frames.map(&:last).select { |frame| frame["type"] == ROUND_STARTED }
        task_key = dials.last&.fetch("task_key", nil)
        last = deltas.last&.first
        { "task_key" => task_key, "frames" => deltas.size, "by_type" => deltas.map { |_at, frame| frame["type"] }.tally,
          "first_frame_at" => deltas.first&.first&.iso8601(6), "last_frame_at" => last&.iso8601(6),
          "last_frame_age_s" => (last && stopped_at ? (Time.iso8601(stopped_at) - last).round(1) : nil),
          "attempts" => (task_key.nil? ? 0 : dials.count { |frame| frame["task_key"] == task_key }),
          "stream_resets" => frames.count { |_at, frame| frame["type"] == STREAM_RESET }, "unparsed" => unparsed }
      end

      # A window's first byte: its mark, or the top of a file shorter than its mark — reopened under
      # it by a restarted host.
      def from_of(window) = File.size(window.path) < window.from ? 0 : window.from

      def world_logs(handle) = Dir.glob(File.join(handle.fetch("log_dir"), "*.log")).sort

      def rails_log?(path) = File.basename(path).end_with?(RAILS_LOG_SUFFIX)

      def source_name(path) = "nexus.#{File.basename(path)}"

      # Listed, not written: nil so `filter_map` drops it.
      def skip(lines, name, path)
        lines << "#{name}: skipped (#{path} is not a file)"
        nil
      end

      def read(path, from)
        File.open(path, "rb") do |file|
          file.seek(from)
          file.read.to_s.force_encoding(Encoding::UTF_8).scrub
        end
      end

      def write(into, name, text, lines, source)
        target = File.join(into, name)
        File.write(target, text, encoding: Encoding::UTF_8)
        lines << "#{name}: #{text.bytesize} bytes from #{source}"
        target
      end
    end
  end
end
