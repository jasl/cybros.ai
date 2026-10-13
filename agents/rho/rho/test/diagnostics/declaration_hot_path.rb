# Run from agents/rho/rho:
#   BUNDLE_FROZEN=true bundle exec ruby -Ilib test/diagnostics/declaration_hot_path.rb
#   AUDIT_COUNTS=1 BUNDLE_FROZEN=true bundle exec ruby -Ilib test/diagnostics/declaration_hot_path.rb
# Timing runs omit the operation counters; the fake request recorder remains.
# Each metric uses five
# warmups and 100 iterations; the counted run records one additional call.
# The fixture uses the shipped default tools plus 100 Agent MCP tools, one
# named definition, two editor anchors and one discovered Runner. Changed
# and rejected cases add a second Runner. API responses are in-process test
# doubles, so timings include SDK projection/fixture cost, not network or Nexus.
# Remote open/say request counts are pinned by declaration_hot_path_test.rb.

require "rho"
require "tmpdir"
require "fileutils"
require_relative "../support/nexus_doubles"

module DeclarationHotPathProbe
  module AuditCounts
    class << self
      attr_accessor :active, :fake, :counts
      def add(key, n = 1)
        counts[key] += n if active && !fake
      end
    end
    self.counts = Hash.new(0)
  end
  module AuditLowering
    def function_entry(tool)
      AuditCounts.add(:function_entry)
      super
    end
  end
  CybrosAgent::Api::ToolLowering.singleton_class.prepend(AuditLowering) if ENV["AUDIT_COUNTS"] == "1"
  module AuditDeclaration
    def served_entries(served)
      AuditCounts.add(:served_entries_calls)
      AuditCounts.add(:served_entries_items, Array(served).length)
      super
    end
    def digest(entries)
      AuditCounts.add(:digest_calls)
      super
    end
  end
  Rho::RunDeclaration.singleton_class.prepend(AuditDeclaration) if ENV["AUDIT_COUNTS"] == "1"
  module AuditEntry
    def announcement
      AuditCounts.add(:entry_announcement)
      super
    end
  end
  Rho::Runner::Extensions::Registry::Entry.prepend(AuditEntry) if ENV["AUDIT_COUNTS"] == "1"
  module AuditJSON
    def generate(*args, **options)
      AuditCounts.add(:json_generate)
      super
    end
  end
  JSON.singleton_class.prepend(AuditJSON) if ENV["AUDIT_COUNTS"] == "1"
  module AuditTransport
    attr_reader :audit_requests
    def call(path, **options)
      (@audit_requests ||= []) << [options.fetch(:method, :get), path]
      AuditCounts.fake = true
      super
    ensure
      AuditCounts.fake = false
    end
  end
  NexusDoubles::FakeAgentApi.prepend(AuditTransport)

  Log = Class.new do
    def info(*) = nil
    def warn(*) = nil
    def error(*) = nil
  end
  Context = Data.define(:environment) do
    def own_runner?(id) = false
  end
  Servers = Struct.new(:own, :foreign) do
    def announcement = own + foreign
    def announcement_for(anchor) = anchor == "anchor" ? own : []
    def names = announcement.map { |entry| entry.fetch("name") }
    def names_for(anchor) = announcement_for(anchor).map { |entry| entry.fetch("name") }
  end

  ROOT = Dir.mktmpdir("rho-ab-audit")
  HOME_ROOT = File.join(ROOT, "home")
  WORK_ROOT = File.join(ROOT, "work")
  FileUtils.mkdir_p(File.join(WORK_ROOT, ".agents", "agents"))
  File.write(File.join(WORK_ROOT, ".agents", "agents", "reviewer.md"), "---\ndescription: Reviews a diff.\ntools: read, grep\n---\nReview the change.\n")
  HOME_OBJECT = Rho::Home.resolve(base_url: "https://nexus.example", root: HOME_ROOT)
  CONFIG = Rho::Config.from_hash({})
  HOST = Rho::Extensions::Host.new(home: HOME_OBJECT, log: nil, clock: -> { Time.now }, config: CONFIG,
    processes: nil, checkpoints: -> { raise "probe never opens a checkpoint store" })
  PROFILE = Rho::Runner::Tools::Read::EFFECT_PROFILE
  SCHEMA = { "type" => "object", "properties" => {
    "query" => { "type" => "string", "description" => "The text to find in the selected project." },
    "paths" => { "type" => "array", "items" => { "type" => "string" } },
    "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 1000 },
  }, "required" => ["query"], "additionalProperties" => false }
  FIXTURE = Module.new do
    const_set(:NAME, "audit.fixture")
    define_singleton_method(:register) do |api|
      100.times do |index|
        klass = Class.new do
          const_set(:NAME, "mcp__audit__find_#{index.to_s.rjust(3, "0")}")
          const_set(:DESCRIPTION, "Search indexed project documents and return matching paths with excerpts.")
          const_set(:SCHEMA, SCHEMA)
          const_set(:EFFECT_PROFILE, PROFILE)
          define_method(:initialize) { |env:| }
          define_method(:call) { |args| raise "probe never invokes tools" }
        end
        api.register_tool(klass, serves: :agent)
      end
    end
  end
  CATALOG = CONFIG.kernel_tools.map do |canonical|
    name = case canonical
    when /nexus\.memory\./ then "memory_#{canonical.split(".").last}"
    when "nexus.skill.load" then "skill"
    when "nexus.tools.search" then "tool_search"
    when "nexus.tools.call" then "tool_call"
    when "nexus.runners.list" then "runners_list"
    when "nexus.conversation.search" then "session_search"
    when "nexus.conversation.read" then "session_read"
    else canonical.split(".").last
    end
    { "canonical_name" => canonical, "name" => name, "effect_profile" => {}, "definition" => {
      "type" => "function", "function" => { "name" => name, "description" => "The #{name} capability.", "parameters" => { "type" => "object", "properties" => {} } },
    } }
  end
  AuditBinding = Data.define(:anchor, :root, :directories)
  BINDING = AuditBinding.new(anchor: "anchor", root: nil, directories: [])

  module_function

  # Baseline schema rendering and the accepted names projection, both recomputed.
  def current_names(registry, servers)
    Rho::RunDeclaration.tool_entries(Rho::RunDeclaration.announcement(registry: registry.serving(:agent), extras: servers.announcement_for("anchor")))
      .map { |entry| entry.dig("function", "name") }
  end

  def projected_names(registry, servers)
    ((registry.serving(:agent).names + servers.names_for("anchor")).uniq - Rho::RunDeclaration.undeclared - [Rho::Runner::Tools::Skill::NAME]).sort
  end

  def statistics(label, warmups: 5, iterations: 100)
    warmups.times { yield }
    GC.start
    before = GC.stat(:total_allocated_objects)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    iterations.times { yield }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    allocations = GC.stat(:total_allocated_objects) - before
    AuditCounts.counts = Hash.new(0)
    AuditCounts.active = true
    result = yield
    AuditCounts.active = false
    { label: label, iterations: iterations, allocations_per_op: allocations.fdiv(iterations), ms_per_op: elapsed * 1000 / iterations,
      counts: AuditCounts.counts, result: (result in Rho::Daemon::HostFollowers::Refused) ? result.code : result }
  end

  def rig(loaded)
    runner_tools = Rho::RunDeclaration.announcement(registry: loaded.registry.serving(:runner))
    api = NexusDoubles::FakeAgentApi.new(tools: CATALOG, executors: [NexusDoubles.remote_runner("runner-a", tools: runner_tools)])
    client = CybrosAgent::Client.new(base_url: "https://nexus.example", credential: NexusDoubles::MEMBER_TOKEN, transport: api)
    servers = Servers.new([NexusDoubles.served_tool("mcp__editor__query", schema: SCHEMA)], [NexusDoubles.served_tool("mcp__foreign__query", schema: SCHEMA)])
    followers = Rho::Daemon::HostFollowers.new(lineage: Data.define(:identity).new(Data.define(:user_public_id).new("0199-user")),
      home: HOME_OBJECT, config: CONFIG, wire: nil, loaded: loaded, log: Log.new,
      context: Context.new(Data.define(:root).new(WORK_ROOT)), environments: Data.define(:servers).new(servers))
    [followers, client, api, servers]
  end

  def measured_edge(label, followers, client, api, **options)
    from = api.audit_requests&.length || 0
    AuditCounts.counts = Hash.new(0)
    AuditCounts.active = true
    result = followers.send(:declare_locked, client, **options)
    AuditCounts.active = false
    { label: label, outcome: (result in Rho::Daemon::HostFollowers::Refused) ? result.code : result, counts: AuditCounts.counts,
      requests: api.audit_requests.drop(from).tally }
  end

  begin
    outputs = []
    [0, 100].each do |count|
      loaded = Rho::Extensions.load(host: HOST, extensions: Rho::Extensions::DEFAULT_EXTENSIONS + (count.zero? ? [] : [FIXTURE]), gems: Rho::Extensions::TOOL_GEMS)
      raise loaded.failures.inspect unless loaded.failures.empty?
      followers, client, api, servers = rig(loaded)
      row = { fixture: count.zero? ? "defaults" : "defaults_plus_100_agent_mcp", registry: { all: loaded.registry.names.length,
        agent: loaded.registry.serving(:agent).names.length, runner: loaded.registry.serving(:runner).names.length }, edges: [], timings: [] }
      row[:edges] << measured_edge("cold", followers, client, api)
      row[:edges] << measured_edge("unchanged", followers, client, api)
      row[:timings] << statistics("unchanged_declaration") { followers.send(:declare_locked, client) }
      row[:timings] << statistics("names_current") { current_names(loaded.registry, servers).length }
      row[:timings] << statistics("names_projection") { projected_names(loaded.registry, servers).length }
      raise "names changed" unless current_names(loaded.registry, servers) == projected_names(loaded.registry, servers)
      followers.send(:turn_surface, client, "runner-a", binding: BINDING)
      row[:timings] << statistics("turn_surface_and_selection_fake_api") do
        surface = followers.send(:turn_surface, client, "runner-a", binding: BINDING)
        followers.send(:tool_selection, client, surface: surface).tools.length
      end
      # A changed eligible Runner list must change declaration membership.
      api.reannounce_executor(NexusDoubles.remote_runner("runner-b", tools: [NexusDoubles.served_tool("mcp__remote__write", schema: SCHEMA)]))
      row[:edges] << measured_edge("candidate_added", followers, client, api)
      # Changed remote schemas must move self-modification rules without copying schemas into Agent declarations.
      moved_schema = SCHEMA.merge("properties" => SCHEMA.fetch("properties").merge("command" => { "type" => "string" }))
      api.reannounce_executor(NexusDoubles.remote_runner("runner-b", tools: [NexusDoubles.served_tool("mcp__remote__write", schema: moved_schema)]))
      row[:edges] << measured_edge("remote_mcp_property_changed", followers, client, api)
      # A descriptive-only remote change refreshes discovery but leaves profile bytes equal.
      api.reannounce_executor(NexusDoubles.remote_runner("runner-b", tools: [NexusDoubles.served_tool("mcp__remote__write", description: "Changed description", schema: moved_schema)]))
      row[:edges] << measured_edge("remote_description_changed", followers, client, api)
      alternatives = ["Changed description one", "Changed description two"].map { |description| [NexusDoubles.served_tool("mcp__editor__query", description: description, schema: SCHEMA)] }
      alternator = 0
      row[:timings] << statistics("changed_editor_declaration") do
        servers.own = alternatives[alternator % 2]
        alternator += 1
        followers.send(:declare_locked, client)
      end
      old_accepted = followers.instance_variable_get(:@declared)
      servers.own = [NexusDoubles.served_tool("mcp__editor__query", description: "Changed editor description", schema: SCHEMA)]
      api.instance_variable_set(:@configuration, CybrosAgent::Response.new(status: 422, body: { "error" => { "code" => "validation_failed", "message" => "probe refusal" } }, headers: {}))
      row[:edges] << measured_edge("editor_change_rejected", followers, client, api)
      raise "refused bytes became accepted" unless old_accepted == followers.instance_variable_get(:@declared)
      row[:timings] << statistics("rejected_declaration") { followers.send(:declare_locked, client) }
      row[:edges] << measured_edge("rejected_retry", followers, client, api)
      api.instance_variable_set(:@configuration, :accept)
      row[:edges] << measured_edge("retry_accepted", followers, client, api)
      row[:edges] << measured_edge("post_accept_unchanged", followers, client, api)
      outputs << row
    end
    puts JSON.pretty_generate(ruby: RUBY_DESCRIPTION,
      instrumented: ENV["AUDIT_COUNTS"] == "1",
      scope: "in-process rho and SDK using FakeAgentApi; no TCP, database, real Nexus assembly or model requests; counts exclude fake server internals",
      outputs: outputs)
  ensure
    FileUtils.remove_entry(ROOT) if defined?(ROOT) && File.directory?(ROOT)
  end
end
