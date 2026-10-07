require "test_helper"

# THE MODEL-FACING NAME: verbatim when it fits the
# provider floor; else normalized, cut, and hashed so two raw names that
# normalize alike never collapse — deepseek's `publicToolName` byte for byte.
class NamingTest < Minitest::Test
  # The kernel's published skill grammar (`contracts/nexus/v1/memory_documents.json`,
  # rendered by the pack generator from `Nexus::Skills`): the DOCUMENT rule
  # rides it, so its bound and its outputs are pinned to the pack.
  PACK = File.expand_path("../../../../contracts/nexus/v1/memory_documents.json", __dir__)
  PUBLISHED = JSON.parse(File.read(PACK, encoding: Encoding::UTF_8)).freeze
  SKILL_NAME = Regexp.new(PUBLISHED.fetch("skill_name_format")).freeze

  # THE PIN: the document rule's length bound IS the kernel's
  # skill-name bound, and every document name it mints matches the
  # kernel's published grammar — the naming module restates neither.
  def test_the_document_rule_is_pinned_to_the_kernels_published_skill_grammar
    assert_equal PUBLISHED.fetch("skill_name_max_length"), Rho::Mcp::Naming::MAX_LENGTH,
      "rho-mcp's bound mirrors nexus's skill-name bound; update the copy when the kernel moves"
    assert_match SKILL_NAME, Rho::Mcp::Naming.document("fx", "Summarize Notes")
    refute_match SKILL_NAME, "mcp__fx__echo", "a tool name is the other grammar: never a document's"
  end

  def test_a_name_that_fits_is_verbatim_under_the_prefix
    assert_equal "mcp__fx__echo", Rho::Mcp::Naming.tool("fx", "echo")
    assert_equal "mcp__my-server__read_file-2", Rho::Mcp::Naming.tool("my-server", "read_file-2")
  end

  def test_a_lossy_name_is_normalized_cut_and_hashed
    name = Rho::Mcp::Naming.tool("fx", "dotted.name/with space")
    assert_match(/\Amcp__fx__dotted_name_with_space_[0-9a-f]{12}\z/, name)
    assert_equal "mcp__fx__dotted_name_with_space_#{Rho::Mcp::Naming.digest("fx", "dotted.name/with space")}", name
    assert_operator name.length, :<=, 64
    assert_match Rho::Runner::Extensions::Tool::NAME_FORMAT, name
  end

  def test_two_raw_names_that_normalize_alike_stay_apart
    a = Rho::Mcp::Naming.tool("fx", "a.b")
    b = Rho::Mcp::Naming.tool("fx", "a/b")
    refute_equal a, b
    assert_equal a[0, a.length - 13], b[0, b.length - 13], "the normalized halves agree; the hashes differ"
  end

  def test_a_long_name_is_cut_to_leave_room_for_the_hash
    raw = "x" * 100
    name = Rho::Mcp::Naming.tool("fx", raw)
    assert_equal 64, name.length
    assert_equal "mcp__fx__#{"x" * 42}_#{Rho::Mcp::Naming.digest("fx", raw)}", name
    assert_match Rho::Runner::Extensions::Tool::NAME_FORMAT, name
  end

  def test_the_hash_is_sha256_of_server_nul_raw
    assert_equal Digest::SHA256.hexdigest("fx\0a.b")[0, 12], Rho::Mcp::Naming.digest("fx", "a.b")
  end

  # THE DOCUMENT RULE: the skill grammar — lowercase, single
  # hyphens, ≤ 64 — verbatim when the raw name already fits, else folded
  # with the same 12-hex digest; never `mcp__`.
  def test_a_document_rides_the_skill_grammar_with_the_hash_on_a_lossy_fold
    assert_equal "fx-summarize", Rho::Mcp::Naming.document("fx", "summarize")
    assert_equal "fx-deploy-notes", Rho::Mcp::Naming.document("fx", "deploy-notes")
    digest = Rho::Mcp::Naming.digest("fx", "Summarize Notes")
    assert_equal "fx-summarize-notes-#{digest}", Rho::Mcp::Naming.document("fx", "Summarize Notes")
    assert_equal 12, digest.length
    refute_equal Rho::Mcp::Naming.document("fx", "a b"), Rho::Mcp::Naming.document("fx", "a_b"), "two folds never collapse"
    assert_equal "fx-a-b-#{Rho::Mcp::Naming.digest("fx", "--a__b--")}", Rho::Mcp::Naming.document("fx", "--a__b--")
    long = "n" * 70
    named = Rho::Mcp::Naming.document("fx", long)
    assert_equal 64, named.length
    assert_equal "fx-#{"n" * 48}-#{Rho::Mcp::Naming.digest("fx", long)}", named
    cut_on_hyphen = Rho::Mcp::Naming.document("fx", "#{"a" * 47}-#{"b" * 20}")
    assert_match SKILL_NAME, cut_on_hyphen, "a cut that lands on a hyphen never doubles it"
    assert_operator cut_on_hyphen.length, :<=, PUBLISHED.fetch("skill_name_max_length")
    %w[summarize Summarize\ Notes a\ b].each do |raw|
      assert_match SKILL_NAME, Rho::Mcp::Naming.document("fx", raw), raw
    end
  end
end
