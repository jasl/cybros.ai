require "test_helper"
require "prism"

# THE API IS THE ONLY DOOR.
# An extension sees its `api` at register time and a `ctx` per call, and
# nothing else of the daemon: not the collaborators behind the facade, not
# the Lineage, not another extension's module or the library it wraps. Two
# value types are allowed through, because a value is not state: `Rho::Daemon::Refusal` and `Rho::Daemon::HostFollowers::Draft`.
# The guard parses every file under lib/rho/extensions rather than
# trusting a comment.
class ExtensionBoundaryTest < Minitest::Test
  EXTENSIONS_TREE = File.expand_path("../../lib/rho/extensions", __dir__)

  # What each extension owns: its module, and the library it is the door
  # to. A reference to any of these from another extension's file is the
  # coupling the Api exists to forbid.
  OWNERS = {
    "agents" => %w[Rho::Extensions::Agents Rho::Agents],
    "compaction" => %w[Rho::Extensions::Compaction],
    "console_link" => %w[Rho::Extensions::ConsoleLink],
    "conventions" => %w[Rho::Extensions::Conventions Rho::Conventions],
    "default_runner" => %w[Rho::Extensions::DefaultRunner],
    "environment" => %w[Rho::Extensions::Environment],
    "guard" => %w[Rho::Extensions::Guard],
    "images" => %w[Rho::Extensions::Images],
    "memory_review" => %w[Rho::Extensions::MemoryReview Rho::MemoryReview],
    "ops" => %w[Rho::Extensions::Ops],
    "packages" => %w[Rho::Extensions::Packages Rho::Packages],
    "processes" => %w[Rho::Extensions::Processes Rho::Processes],
    "schedules" => %w[Rho::Extensions::Schedules],
    "setup" => %w[Rho::Extensions::Setup Rho::Cli::Setup],
    "todo" => %w[Rho::Extensions::Todo],
    "until" => %w[Rho::Extensions::Until Rho::Until],
  }.freeze
  VALUE_TYPES = %w[Rho::Daemon::Refusal Rho::Daemon::HostFollowers::Draft].freeze
  CONTEXT_INTERNALS = %i[lineage runs loaded].freeze

  class Guard
    Violation = Data.define(:line, :text)

    def initialize(source, extension)
      @program = Prism.parse(source).value
      @foreign = OWNERS.reject { |name, _| name == extension }.values.flatten
      @violations = []
    end

    def violations
      walk(@program)
      @violations
    end

    private

      # A constant path is judged whole and not descended into: the parent
      # of `Rho::Daemon::Refusal` is `Rho::Daemon`, which alone would be a
      # false hit on an allowed value type.
      def walk(node)
        case node
        when Prism::ConstantPathNode, Prism::ConstantReadNode
          check_constant(node)
          return
        when Prism::InstanceVariableReadNode, Prism::InstanceVariableWriteNode
          flag(node) if node.name.start_with?("@ceremony")
        when Prism::CallNode
          flag(node) if CONTEXT_INTERNALS.include?(node.name) && node.receiver&.slice == "ctx"
        else nil
        end
        node.compact_child_nodes.each { |child| walk(child) }
      end

      def check_constant(node)
        name = node.full_name
        flag(node) if forbidden?(name)
      rescue Prism::ConstantPathNode::DynamicPartsError, Prism::ConstantPathNode::MissingNodesError
        nil
      end

      # A bare or relative name resolves lexically under `Rho::Extensions`,
      # so it is judged under both prefixes as well as as written.
      def forbidden?(name)
        return true if name.split("::").include?("Lineage")

        candidates = [name, "Rho::#{name}", "Rho::Extensions::#{name}"]
        return !within?(candidates, VALUE_TYPES) if within?(candidates, ["Rho::Daemon"])

        within?(candidates, @foreign)
      end

      def within?(candidates, namespaces)
        candidates.any? { |candidate| namespaces.any? { |ns| candidate == ns || candidate.start_with?("#{ns}::") } }
      end

      def flag(node)
        @violations << Violation.new(line: node.location.start_line, text: node.slice)
      end
  end

  def read(path) = File.read(path, encoding: "UTF-8")

  def files = Dir.glob(File.join(EXTENSIONS_TREE, "**", "*.rb")).sort

  # The first path segment under the tree names the extension: `ops.rb`
  # and `ops/run_routes.rb` are both Ops'.
  def extension_of(path) = path.delete_prefix("#{EXTENSIONS_TREE}/").split("/").first.delete_suffix(".rb")

  def test_every_extension_file_has_an_owner_row
    assert_equal OWNERS.keys, files.map { |path| extension_of(path) }.uniq.sort,
      "a new extension needs its row in OWNERS so the guard knows what it owns"
  end

  def test_no_extension_reaches_past_the_api_and_the_context
    offenders = files.flat_map do |path|
      Guard.new(read(path), extension_of(path)).violations.map do |violation|
        "#{path.delete_prefix("#{EXTENSIONS_TREE}/")}:#{violation.line} #{violation.text}"
      end
    end
    assert_empty offenders
  end

  FIXTURE = <<~RUBY
    module Rho
      module Extensions
        module Planted
          def self.register(api)
            api.register_route("POST", "/planted") { |request, ctx| handle(request, ctx) }
          end

          def self.handle(request, ctx)
            ctx.lineage.adopt(identity: nil, credentials: nil)
            Rho::Daemon::Lineage::Workspace.adopted(public_id: "w", name: "W")
            Daemon::STOP_CONTROL_DRAIN_DEADLINE
            Rho::Until::Policy.from_h({})
            Extensions::Ops::RunRoutes.attach(request, ctx)
            @ceremony_mutex.synchronize { nil }
            Rho::Daemon::HostFollowers::Draft.new(body: {}, environment: nil, lead: "", notes: {}, tools: [])
            Rho::Daemon::Refusal.malformed("x")
            Rho::Processes::Registry.new
            ctx.runs_for(nil, "w")
          end
        end
      end
    end
  RUBY

  # THE POSITIVE CASE, planted as the Until extension: the facade's
  # internals, the Lineage, a daemon constant, Ops' module, the ceremony's
  # ivar and the Processes library are caught; the two value types, the
  # extension's own library (`Rho::Until`) and the facade's verbs are not.
  def test_the_guard_catches_planted_reaches_and_allows_the_value_types
    texts = Guard.new(FIXTURE, "until").violations.map(&:text)

    assert_equal [
      "ctx.lineage", "Rho::Daemon::Lineage::Workspace", "Daemon::STOP_CONTROL_DRAIN_DEADLINE",
      "Extensions::Ops::RunRoutes", "@ceremony_mutex", "Rho::Processes::Registry",
    ], texts
  end
end
