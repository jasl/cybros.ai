# A model-free measurement over the real rho control, Nexus and Runner APIs.
# Run from e2e: bundle exec ruby -Itest manual/runner_admission/relay.rb
# Writes JSON only when ADMISSION_OUTPUT names an ignored/local output path.
require_relative "../../test/executor_relay_test"
ARGV.concat(["--name", "test_admission_relay_measurement"])

class ExecutorRelayTest
  def test_admission_relay_measurement
    samples = Integer(ENV.fetch("ADMISSION_SAMPLES", "24"))
    path = File.join(@world.runner_rho_home, "work", "admission-measurement.txt")
    File.write(path, "bounded read fixture\n")
    records = []
    [1, 8].each do |concurrency|
      2.times { measured_call(path) }
      began = monotonic_measurement
      queue = Queue.new
      samples.times { |index| queue << index }
      workers = Array.new(concurrency) do
        Thread.new do
          results = []
          loop do
            queue.pop(true)
            results << measured_call(path)
          rescue ThreadError
            break
          end
          results
        end
      end
      durations = workers.flat_map(&:value)
      elapsed = monotonic_measurement - began
      sorted = durations.sort
      records << { concurrency: concurrency, calls: durations.length,
                   elapsed_seconds: elapsed, throughput_per_second: durations.length / elapsed,
                   p50_ms: sorted.fetch((sorted.length * 0.50).ceil - 1) * 1000,
                   p95_ms: sorted.fetch((sorted.length * 0.95).ceil - 1) * 1000,
                   durations_ms: durations.map { |duration| duration * 1000 } }
    end
    result = { kind: "real_control_nexus_runner", ruby: RUBY_DESCRIPTION, samples: records }
    File.write(ENV.fetch("ADMISSION_OUTPUT"), JSON.pretty_generate(result) + "\n") if ENV["ADMISSION_OUTPUT"]
    puts JSON.generate(result)
  end

  private

    def monotonic_measurement = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def measured_call(path)
      started = monotonic_measurement
      document = @daemon.control(:post, "/runs/call_tool", expected_status: 200,
        body: { "runner_executor_public_id" => @runner_id, "tool" => "read", "input" => { "path" => path } })
      task = document.fetch("call_tool").fetch("task")
      raise "read did not complete: #{task.inspect}" unless task.fetch("status") == "completed"
      raise "read returned the wrong bytes" unless task.fetch("output").include?("bounded read fixture")

      monotonic_measurement - started
    end
end
