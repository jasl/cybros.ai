# Run from agents/rho/rho-runner:
#   BUNDLE_FROZEN=true bundle exec ruby -Ilib test/diagnostics/placement_redaction.rb
#   AUDIT_COUNTS=1 BUNDLE_FROZEN=true bundle exec ruby -Ilib test/diagnostics/placement_redaction.rb
# The ordinary run installs no File instrumentation. The counted run records
# Ruby method calls, not syscalls, and omits timing/allocation measurements.
# This is a local component probe: temporary directories, the shipped Coding
# registry, one bound root plus one extra, and synthetic secret values. There
# is no handler execution, network IO, credential access or end-to-end claim.

require "rho/runner"
require "tmpdir"
require "fileutils"
require "json"

module PlacementRedactionProbe
  COUNTS = ENV["AUDIT_COUNTS"] == "1"

  module FileCalls
    class << self
      attr_accessor :counts
    end

    %i[exist? realpath directory?].each do |name|
      define_method(name) do |*args, **kwargs|
        FileCalls.counts[name] += 1 if FileCalls.counts
        super(*args, **kwargs)
      end
    end
  end
  File.singleton_class.prepend(FileCalls) if COUNTS

  class LiveSecrets
    attr_reader :reads

    def initialize
      @values = ["fixture-access-value", "fixture-refresh-value"]
      @reads = 0
    end

    def secret_values
      @reads += 1
      @values.dup.freeze
    end
  end

  Task = Data.define(:conversation_public_id, :parent_public_id, :run_public_id)

  module_function

  def measure(label, iterations:)
    10.times { yield }
    if COUNTS
      FileCalls.counts = Hash.new(0)
      100.times { yield }
      counts = FileCalls.counts
      FileCalls.counts = nil
      { label: label, iterations: 100, file_calls: counts }
    else
      rounds = 5.times.map do
        GC.start
        before = GC.stat(:total_allocated_objects)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        iterations.times { yield }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        { allocations: GC.stat(:total_allocated_objects) - before, elapsed_ms: elapsed * 1000 }
      end
      { label: label, iterations: iterations, rounds: rounds }
    end
  end

  results = []
  Dir.mktmpdir("rho-placement-audit") do |tmp|
    zero_root, root, extra, work = %w[zero root extra work].map { |name| File.join(File.realpath(tmp), name) }
    FileUtils.mkdir_p([zero_root, root, extra, work])
    registry = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Runner::Extensions::Coding]).registry
    zero = Rho::Runner::ToolEnv.new(root: zero_root, artifacts_dir: File.join(work, "captures"))
    binding = Rho::Runner::Environment::Binding.new(root: root, directories: [extra], anchor: "parent")
    task = Task.new(conversation_public_id: "parent", parent_public_id: nil, run_public_id: "run")
    tools = Rho::Runner::Toolsets.new(registry: registry, zero: zero, resolver: ->(*) { binding }, work_dir: work)
    held = tools.for(task)
    results << measure("cached_toolsets_one_root_one_extra", iterations: 1000) do
      value = tools.for(task)
      raise "placement changed" unless value.env.equal?(held.env) && value.toolset.equal?(held.toolset)
    end
  end

  [2, 100].each do |rows|
    live = LiveSecrets.new
    redact = Rho::Runner::Redact.new(["fixture-static-value"], live: live)
    value = { "rows" => rows.times.map { |index| { "key" => "fixture-#{index}", "value" => "fixture-access-value" } } }
    expected = { "rows" => rows.times.map { |index| { "key" => "fixture-#{index}", "value" => "•••" } } }
    raise "redaction changed" unless redact.structure(value) == expected

    result = measure("redact_structure_#{rows}_rows", iterations: 100) { redact.structure(value) }
    reads = live.reads
    redact.structure(value)
    results << result.merge(live_reads_per_structure: live.reads - reads)
  end

  puts JSON.pretty_generate(ruby: RUBY_DESCRIPTION, instrumented: COUNTS, results: results)
end
