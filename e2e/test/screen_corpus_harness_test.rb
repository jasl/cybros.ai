$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "minitest/autorun"
require "support/screen/corpus"

# Authored cases keep offline replay independent of saved model runs.
class ScreenCorpusHarnessTest < Minitest::Test
  C = E2E::Screen::Corpus
  NUL = "\u0000".freeze

  def test_the_corpus_reads_only_its_authored_fixtures
    assert_equal File.expand_path("../support/fixtures/screen/corpus", __dir__), C::DIR
    C::FILES.each_value do |name|
      path = File.join(C::DIR, name)
      assert File.file?(path), "#{name} is missing"
      refute_includes File.expand_path(path), "/artifacts/"
    end
    %w[unknown door declarations].each { |id| assert_raises(KeyError) { C.read(id) } }
  end

  def test_scripts_group_by_their_declared_set
    groups = C.read("declared")
    entries = groups.flat_map(&:entries)
    assert_equal %w[single-model joined-models malformed-script custom-tool], entries.map(&:id)
    groups.each do |group|
      assert_equal group.tool_names.sort, group.tool_names
      assert group.entries.all? { |entry| entry.tool_names.sort == group.tool_names }
      assert_includes group.tool_names, "compose"
    end
    assert_equal({ "path" => "fixture.txt" }, entries.last.params)
  end

  def test_gzipped_json_lines_preserve_the_bench_cases_and_declarations
    group = C.read("bench").fetch(0)
    assert_equal %w[parameterized-tool tool-result nul-literal nul-comment], group.entries.map(&:id)
    assert_equal %w[bash edit grep probe_host read_file], group.tool_names
    assert_equal group.entries.length, group.scripts.length
    assert_equal({ "script" => group.entries.first.script, "params" => group.entries.first.params }, group.scripts.first)
    assert_equal E2E::ComposeBench::Tools.function_definitions, group.declarations
  end

  def test_held_declarations_preserve_their_wire_order
    C.read("declared").each do |group|
      assert_equal group.tool_names.reverse, group.declarations.map { |entry| entry.dig("function", "name") }
      group.declarations.each do |entry|
        assert_equal %w[function type], entry.keys.sort
        assert_equal "function", entry.fetch("type")
        assert_equal "object", entry.dig("function", "parameters", "type")
      end
    end
    assert_equal C.read("declared").map(&:tool_names).sort, C.declared_sets.map { |row| row.fetch("tool_names") }.sort
  end

  def test_an_unheld_declared_set_is_refused_by_name
    held = C.read("declared").first.tool_names
    short = assert_raises(E2E::Screen::Refused) { C::Group.new(tool_names: held - ["ask"], entries: []).declarations }
    assert_includes short.message, "compose"
    past = assert_raises(E2E::Screen::Refused) { C::Group.new(tool_names: (held + ["web_fetch"]).sort, entries: []).declarations }
    assert_includes past.message, "web_fetch"
    assert_includes past.message, "the corpus holds no declarations"
  end

  def test_the_nul_cases_each_hold_one_nul_and_are_present_in_the_bench_corpus
    entries = C.read("nul").flat_map(&:entries)
    assert_equal %w[nul-literal nul-comment], entries.map(&:id)
    bench = C.read("bench").flat_map(&:entries).to_h { |entry| [entry.id, entry.script] }
    entries.each do |entry|
      assert_equal 1, entry.script.count(NUL), entry.id
      assert_equal bench.fetch(entry.id), entry.script
    end
  end

  def test_door_records_carry_up_to_three_rounds_of_calls
    records = C.door_records
    assert_equal 13, records.length
    assert_equal %w[task workflow], records.map { |record| record.fetch("family") }.uniq.sort
    assert_equal ["synthetic"], records.map { |record| record.fetch("bench") }.uniq
    records.each do |record|
      assert_equal %w[bench family model rounds run style task], record.keys.sort
      assert_operator record.fetch("rounds").length, :<=, 3
      record.fetch("rounds").flatten.each { |call| assert_equal %w[input name], call.keys.sort }
    end
  end

  def test_each_corpus_file_has_the_sha_a_stamp_carries
    shas = C::FILES.keys.map { |id| C.sha256(id) }
    assert shas.all? { |sha| sha.match?(/\A\h{64}\z/) }
    assert_equal shas.uniq, shas
  end
end
