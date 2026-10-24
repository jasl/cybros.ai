# Controlled measurements of the shipped Runner with an in-process executor.
# Run from e2e: bundle exec ruby manual/runner_admission/local.rb
# The fixture uses the real Runner/Pool with fake Nexus IO and synthetic 50 ms handlers.
require "json"
require "rho/env"

module RunnerAdmissionMeasurement
  Task = CybrosAgent::Api::InboxTask
  Page = Data.define(:items, :next_after)
  class Lane
    attr_reader :claims, :commits, :done, :lists
    attr_accessor :rows

    def initialize
      @rows = []
      @claims = []
      @commits = Hash.new(0)
      @done = Thread::Queue.new
      @lists = 0
    end

    def inbox = self
    def list(after: nil, limit: nil)
      @lists += 1
      Page.new(items: rows.reject { |row| @claims.include?(row.task_key) }, next_after: nil)
    end

    def inbox_task(run_public_id:, task_key:) = Door.new(lane: self, key: task_key)
    Door = Data.define(:lane, :key) do
      def claim
        # A recovery scan may claim before the matching push arrives.
        if lane.claims.include?(key)
          raise CybrosAgent::Api::Conflict.new("already claimed", code: "already_claimed")
        end

        lane.claims << key
        CybrosAgent::Api::ClaimedTask.new(task: lane.rows.find { |row| row.task_key == key },
          claim_token: "token-#{key}", deadline_at: nil)
      end

      def commit(**fields)
        raise "wrong claim token" unless fields.fetch(:claim_token) == "token-#{key}"
        raise "failed handler" unless fields.fetch(:outcome) == "completed"

        lane.commits[key] += 1
        lane.done << key
      end
    end
  end

  class Log
    attr_reader :warnings

    def initialize = @warnings = []
    def info(*) = nil
    def warn(*fields) = @warnings << fields
  end

  def self.now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def self.run(mode, count: 12, workers: 2)
    lane = Lane.new
    log = Log.new
    ended = {}
    handlers = Hash.new(0)
    active = Hash.new(0)
    peaks = Hash.new(0)
    mutex = Mutex.new
    names = mode.start_with?("mixed_") ? %w[desktop files] : %w[files]
    tools = names.to_h do |name|
      options = {}
      if name == "desktop" && Rho::Env.const_defined?(:Admission, false)
        options[:admission] = Rho::Env::Admission::Rule.new(resource: "desktop")
      end
      tool = Rho::Env::Toolset::Tool.new(name: name, description: name, parameters: { "type" => "object" }, **options,
        handler: lambda do |_arguments, context|
          mutex.synchronize do
            handlers[context.task_key] += 1
            active[name] += 1
            peaks[name] = [peaks[name], active[name]].max
          end
          if mode.start_with?("mixed_")
            sleep 0.05
          else
            Fiber.blocking { sleep 0.05 }
          end
          mutex.synchronize do
            active[name] -= 1
            ended[context.task_key] = now
          end
          Rho::Env::Result.ok("done")
        end)
      [name, tool]
    end
    rows = Array.new(count) do |index|
      Task.new(workspace_public_id: "workspace", kind: "tool_call", run_public_id: "run",
        conversation_public_id: nil, task_key: index.to_s, tool_name: names[index % names.length],
        tool_input: {}, tool_call_id: index.to_s, started_at: nil, deadline_at: nil, timeout_ms: nil,
        claimed: false, addressed_to: CybrosAgent::Api::AddressedTo.new(role: "runner", executor_public_id: "runner"))
    end
    runner = Rho::Env::Executor.new(executor: lane, toolsets: Rho::Env::Toolsets.fixed(toolset: Rho::Env::Toolset.new(tools)),
      pool: Rho::Env::Pool.new(worker_threads: workers), log: log)
    Async do |scope|
      lane.rows = rows unless %w[overflow mixed_push].include?(mode)
      started = now
      follower = scope.async { runner.follow }
      nudges = []
      if %w[overflow mixed_push].include?(mode)
        lane.rows = rows
        rows.each do |row|
          nudges << scope.async { runner.nudged(run_public_id: "run", task_key: row.task_key, tool_name: row.tool_name) }
          sleep(0.005) if mode == "mixed_push"
        end
      end
      scope.with_timeout(30) do
        nudges.each(&:wait)
        count.times { lane.done.pop }
      end
      elapsed = now - started
      expected = rows.to_h { |row| [row.task_key, 1] }
      raise "unexpected Runner warnings: #{log.warnings.inspect}" unless log.warnings.empty?
      raise "handler counts differ: #{handlers.inspect}" unless handlers == expected
      raise "commit counts differ: #{lane.commits.inspect}" unless lane.commits == expected
      durations = ended.values.map { |at| (at - started) * 1000 }.sort
      { mode: mode, calls: count, workers: workers, elapsed_seconds: elapsed,
        throughput_per_second: count / elapsed, p50_ms: durations[(count * 0.50).ceil - 1],
        p95_ms: durations[(count * 0.95).ceil - 1], peak_active: peaks, inbox_reads: lane.lists,
        last_file_ms: rows.select { |row| row.tool_name == "files" }.map { |row| (ended.fetch(row.task_key) - started) * 1000 }.max }
    ensure
      runner.stop
      follower&.stop
    end.wait
  end
end

results = 3.times.flat_map { %w[recovery overflow mixed_resources mixed_push].map { |mode| RunnerAdmissionMeasurement.run(mode) } }
document = { kind: "in_process_executor_fixture", ruby: RUBY_DESCRIPTION, samples: results }
File.write(ENV.fetch("ADMISSION_OUTPUT"), JSON.pretty_generate(document) + "\n") if ENV["ADMISSION_OUTPUT"]
puts JSON.pretty_generate(document)
