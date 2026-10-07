# Run from agents/rho/rho; copy this same file to a baseline checkout to compare:
#   BUNDLE_FROZEN=true bundle exec ruby -Ilib test/diagnostics/registration_hot_path.rb counts
#   BUNDLE_FROZEN=true bundle exec ruby -Ilib test/diagnostics/registration_hot_path.rb timing
# Counts use TracePoint; timing runs install no instrumentation. Timing covers
# warmed candidate loading and resource retirement, five warmups then 25 samples.
# These fixtures do not start extensions, publish, open a daemon or invoke tools.
# They make no network, database or model requests. MCP curation is not measured.

require "rho"
require "tmpdir"
require "json"

module RegistrationHotPathProbe
  module_function

  def load_candidate(host, extensions, gems, reuse: [])
    loaded = Rho::Extensions.load(host: host, extensions: extensions, gems: gems, reuse: reuse)
    raise loaded.failures.map(&:message).join("; ") unless loaded.ok?

    loaded
  end

  def retire(loaded, keeping: [])
    (loaded.registrations - keeping).reverse_each { |api| api.resources.retire }
  end

  def measure(mode)
    if mode == "counts"
      calls = 0
      trace = TracePoint.new(:call) do |event|
        calls += 1 if event.self == Rho::Runner::InputSchema && event.method_id == :compile
      end
      trace.enable { yield }
      return { compile_calls: calls }
    end

    5.times { yield }
    GC.start
    allocated = GC.stat(:total_allocated_objects)
    durations = Array.new(25) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
    end
    { samples: durations.length, allocations_per_load: (GC.stat(:total_allocated_objects) - allocated).fdiv(durations.length),
      mean_ms: durations.sum.fdiv(durations.length), median_ms: durations.sort[durations.length / 2] }
  end

  def synthetic
    schema = Rho::Runner::Tools::Read::SCHEMA
    profile = Rho::Runner::Tools::Read::EFFECT_PROFILE
    tools = Array.new(100) do |index|
      Class.new do
        const_set(:NAME, "audit_#{index}")
        const_set(:DESCRIPTION, "Audit read #{index}")
        const_set(:SCHEMA, schema)
        const_set(:EFFECT_PROFILE, profile)
        define_method(:initialize) { |env:| }
        define_method(:call) { |_args| raise "the probe never invokes tools" }
      end
    end
    Module.new do
      const_set(:NAME, "audit.synthetic")
      define_singleton_method(:register) { |api| tools.each { |klass| api.register_tool(klass) } }
    end
  end

  def probe(mode, host, extensions, gems, replaced)
    base = load_candidate(host, extensions, gems)
    kept = base.registrations.reject { |api| api.extension_name == replaced }
    reused = load_candidate(host, extensions, gems, reuse: base.registrations)
    old_entries = base.registry.entries.to_h { |entry| [[entry.serves, entry.name], entry] }
    identities = reused.registry.entries.count { |entry| entry.validator.equal?(old_entries.fetch([entry.serves, entry.name]).validator) }
    stages = { fresh: [], reuse_all: base.registrations, replace_owner: kept }.transform_values do |reuse|
      measure(mode) do
        candidate = load_candidate(host, extensions, gems, reuse: reuse)
        retire(candidate, keeping: reuse)
      end
    end
    { tools: base.registry.entries.length, unique_classes: base.registry.entries.map(&:klass).uniq.length,
      owners: base.registrations.length, replaced_owner: replaced,
      replaced_tools: base.registrations.select { |api| api.extension_name == replaced }.sum { |api| api.tools.length },
      reused_identical_validators: identities, stages: stages }
  ensure
    retire(reused, keeping: base.registrations) if reused
    retire(base) if base
  end

  mode = ARGV.fetch(0, "counts")
  abort "usage: registration_hot_path.rb [counts|timing]" unless ARGV.length <= 1 && %w[counts timing].include?(mode)

  Dir.mktmpdir("rho-registration-probe-") do |root|
    host = Rho::Extensions::Host.new(
      home: Rho::Home.resolve(base_url: "https://nexus.example", root: root),
      log: nil, clock: -> { Time.now }, config: Rho::Config.from_hash({ "mode" => "full" }), processes: nil,
      checkpoints: -> { raise "the probe never opens a checkpoint store" }
    )
    default_gems = Rho::Extensions::CONTROL_GEMS + Rho::Extensions::TOOL_GEMS + Rho::Extensions::DEFAULT_GEMS
    cases = {
      full_defaults: probe(mode, host, Rho::Extensions::DEFAULT_EXTENSIONS, default_gems, "rho.todo"),
      synthetic_100: probe(mode, host, [synthetic], [], "audit.synthetic"),
    }
    puts JSON.pretty_generate(ruby: RUBY_DESCRIPTION, mode: mode,
      scope: "warmed candidate loading and retirement only; no startup, publication, network, database or handler execution",
      cases: cases)
  end
end
