require "test_helper"
require "prism"

# `db/schema.rb` has to be what BOTH paths that produce it produce: `db:migrate`
# through the migrations (one schema-creating migration at each fold, one per
# change between folds) and `db:schema:load` of the committed file.
#
# PostgreSQL does not store an index predicate as written. It stores a parsed
# expression and deparses it on request, and that deparse is what Rails writes
# into the schema. Three texts are involved and only two of them match:
#
# spelled status IN ('a', 'b') its deparse ((status)::text = ANY ((ARRAY['a'::character
# varying,...])::text[])) THAT re-parsed ((status)::text = ANY (ARRAY[('a'::character
# varying)::text,...]))
#
# So a predicate spelled `IN` makes the two paths dump different files, and the
# ordinary developer sequence dirties the tree with no source change. The rule:
# a migration spells membership in the deparsed `= ANY (ARRAY[...])` form.
#
# The assertion that matters is the one below: each surviving index's predicate
# must deparse to a string the committed schema actually carries. It is
# measured against a temporary table inside this test's own transaction, so it
# depends on no database state and races nothing.
class SchemaRoundTripTest < ActiveSupport::TestCase
  MIGRATIONS = Rails.root.glob("db/migrate/*.rb").sort.freeze
  SCHEMA = Rails.root.join("db/schema.rb")

  # The current migrations declare named indexes in `change`. Track those
  # declarations, not rollback metadata on `remove_index`; this is deliberately
  # not an interpreter for arbitrary migration Ruby.
  class IndexPredicates < Prism::Visitor
    def initialize
      @indexes = {}
    end

    def predicates = @indexes.values.compact

    def visit_call_node(node)
      if %i[index add_index remove_index].include?(node.name)
        case node.arguments.arguments.last
        in Prism::KeywordHashNode[elements:]
          options = elements.to_h { |entry| [entry.key.unescaped, entry.value] }
          if options.key?("name") || options.key?("where") || node.name == :remove_index
            record(node.name, options)
          end
        else
          raise "remove_index needs an explicit name for the predicate inventory" if node.name == :remove_index
        end
      end
      super
    end

    private

      def record(operation, options)
        name = literal(options.fetch("name"))
        predicate = literal(options.fetch("where")) if options.key?("where")
        if operation == :remove_index
          @indexes.delete(name) { raise "removing an unknown index: #{name}" }
        else
          raise "duplicate index declaration: #{name}" if @indexes.key?(name)

          @indexes[name] = predicate
        end
      end

      def literal(node)
        case node
        in Prism::StringNode | Prism::SymbolNode
          node.unescaped
        else
          raise "index names and predicates must be literals in the predicate inventory"
        end
      end
  end

  # Case-insensitive: PostgreSQL does not care how the keyword is spelled and
  # neither may this.
  IN_PREDICATE = /where:\s*"([^"]*\bIN\s*\([^"]*)"/i

  # ARRAY-MEMBERSHIP PREDICATES ONLY, because they are the class with the
  # hazard: PostgreSQL normalizes list membership several ways and the
  # normalizations are not each other. A `col IS NULL` or `col = 'x'` predicate
  # deparses to itself. Scoping keeps the probe table below to the columns
  # these actually use; a future predicate that normalizes some other way
  # would need its own case here, and that is the known limit of this test.
  MEMBERSHIP = /ARRAY\[|\bIN\s*\(/i

  # A predicate long enough to need `"a" \\ "b"` is still one predicate, and
  # reading the fragments separately is how a line-continued `IN (` slipped
  # past the check below: the keyword sat in one fragment and its paren in
  # the next. Collapse the continuation first, then scan.
  def source(path) = path.read.gsub(/"\s*\\\s*\n\s*"/, "")

  def migration_predicates
    index_predicates(MIGRATIONS.map { |path| source(path) })
  end

  def index_predicates(sources)
    inventory = IndexPredicates.new
    sources.each do |text|
      parsed = Prism.parse(text)
      assert parsed.success?, parsed.errors.map(&:message).join("\n")
      parsed.value.accept(inventory)
    end
    inventory.predicates.grep(MEMBERSHIP)
  end

  def schema_predicates
    SCHEMA.read.scan(/where: "([^"]+)"/).flatten.grep(MEMBERSHIP)
  end

  test "no partial index predicate is spelled IN, which does not round-trip" do
    offenders = MIGRATIONS.select { |path| source(path).match?(IN_PREDICATE) }

    assert_empty offenders.map { |path| path.basename.to_s },
      "spell these `column = ANY (ARRAY[...])`: PostgreSQL deparses `IN` to a form whose " \
      "re-parse differs, so db:migrate and db:schema:load dump different schema.rb files"
  end

  test "the predicate inventory follows named index removals and preserves multiplicity" do
    predicate = "status = ANY (ARRAY['running'::text])"
    replacement = "status = ANY (ARRAY['paused'::text])"
    original = "t.index [:id], name: 'old', where: #{predicate.inspect}"
    remove = "remove_index :items, name: :old"
    scenarios = {
      "same name replacement" => [
        [original, remove, "add_index :items, :id, name: :old, where: #{replacement.inspect}"],
        { replacement => 1 },
      ],
      "different name with the same predicate" => [
        [original, "#{remove}, where: #{predicate.inspect}",
          "add_index :items, :id, name: :new, where: #{predicate.inspect}"],
        { predicate => 1 },
      ],
      "two surviving indexes with the same predicate" => [
        [original, "add_index :items, :id, name: :other, where: #{predicate.inspect}"],
        { predicate => 2 },
      ],
      "removal without rollback predicate" => [[original, remove], {}],
      "replacement without a predicate" => [
        [original, remove, "add_index :items, :id, name: :old"], {},
      ],
    }

    scenarios.each do |label, (sources, expected)|
      assert_equal expected, index_predicates(sources).tally, label
    end
    assert_raises(RuntimeError) { index_predicates([original, original]) }
    assert_raises(RuntimeError) { index_predicates([remove]) }
    assert_raises(RuntimeError) { index_predicates(["add_index :items, :id, name: :dynamic, where: predicate"]) }
  end

  # THE ONE WITH TEETH: what the migrations deparse to and what the schema
  # carries are the SAME MULTISET, compared in both directions and by count.
  #
  # Membership alone is not enough, and the reason is specific: fewer distinct
  # predicate texts than index sites carry them, so "does this text appear
  # somewhere" stays true after a whole index line is deleted, after one is
  # narrowed to a subset that still matches elsewhere, and after a phantom
  # index nothing produces is added. All three leave `db:migrate` rewriting
  # the committed file, which is the thing being tested. Counting both sides
  # catches all three, and it is free — the two multisets are equal today.
  test "the migrations and the committed schema carry the same predicates" do
    from_migrations = migration_predicates.map { deparse(_1) }.tally
    assert_operator from_migrations.length, :>, 0, "there are partial indexes to check"

    assert_equal from_migrations, schema_predicates.tally,
      "db/schema.rb is not what these migrations produce, so `db:migrate` from an empty " \
      "database rewrites the committed file with no source change behind it. A count that is " \
      "low means an index went missing from the dump; high means one is in the dump that no " \
      "migration creates."
  end

  # And each committed predicate survives its own re-parse, so `schema:load`
  # reproduces the file it was loaded from.
  test "every committed predicate is a fixed point of its own re-parse" do
    unstable = schema_predicates.reject { |predicate| deparse(predicate) == predicate }

    assert_empty unstable,
      "loading this schema and dumping it again produces different text for these predicates"
  end

  private

    # What PostgreSQL will render for this predicate, read back the same way
    # the schema dumper reads it. The probe table carries the column names and
    # types the real partial indexes use and dies with this test's
    # transaction, so this depends on no database state and races nothing.
    def deparse(predicate)
      @deparsed ||= {}
      return @deparsed[predicate] if @deparsed.key?(predicate)

      name = "zz_idx_#{@deparsed.length}"
      connection.execute("CREATE INDEX #{name} ON #{probe_table} (id) WHERE #{predicate}")
      @deparsed[predicate] = connection.select_value(<<~SQL)
        SELECT pg_get_expr(i.indpred, i.indrelid)
        FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid
        WHERE c.relname = '#{name}'
      SQL
    end

    def probe_table
      @probe_table ||= "zz_schema_probe".tap do |name|
        connection.execute(<<~SQL)
          CREATE TEMPORARY TABLE #{name} (
            id bigint, status character varying(16), state character varying(16),
            terminal_event_recorded_at timestamp, inference_request_id bigint,
            -- The agent-loop plane's predicate vocabulary, plus the
            -- park deadline: its predicate joined this test's scope the
            -- day the park sweep stopped naming one status.
            agent_run_id bigint, await_started_at timestamp, type character varying,
            detached boolean, result_delivered_at timestamp,
            -- The conversation plane's predicate vocabulary (2026-08-28).
            deleted_at timestamp, tombstoned_at timestamp,
            visibility character varying(24), operation character varying(32),
            parent_conversation_id bigint, forked_from_turn_public_id uuid,
            sender_run_public_id uuid,
            conversation_id bigint, model_invocation_id bigint,
            conversation_input_id bigint, conversation_turn_variant_id bigint,
            details_pruned_at timestamp, sealed_at timestamp, role character varying,
            -- The executor plane's vocabulary: the live-identity index
            -- names both machine kinds; the inbox row names its addressee.
            executor_kind character varying(20), addressed_executor_id bigint
          ) ON COMMIT DROP
        SQL
      end
    end

    def connection = ApplicationRecord.connection
end
