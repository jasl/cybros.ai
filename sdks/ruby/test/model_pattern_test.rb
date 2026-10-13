require "test_helper"

# A MODEL PATTERN, on demand: the reference a kernel ref carries (its lane stripped), an entry's
# grammar with the reason a stranger is refused, and the specificity that ranks the entries matching
# one reference — exact above every prefix, a longer stem above a shorter one.
class ModelPatternTest < Minitest::Test
  Pattern = CybrosAgent::ModelPattern

  def test_the_reference_is_the_text_after_the_refs_first_slash
    assert_equal "acme/mdl-5.3", Pattern.reference("gateway/acme/mdl-5.3")
    assert_equal "acme/mdl-5.3", Pattern.reference("or/acme/mdl-5.3"), "the lane is the operator's word"
    assert_equal "sample-wide-5-5", Pattern.reference("exampleco/sample-wide-5-5")
    assert_equal "exampleco/sample-narrow-5:exacto", Pattern.reference("gateway/exampleco/sample-narrow-5:exacto"),
      "the vendor segment and the variant are the upstream id's own bytes"
    assert_nil Pattern.reference(nil), "no model is no reference"
    error = assert_raises(ArgumentError) { Pattern.reference("mdl-5.3") }
    assert_equal '"mdl-5.3" carries no lane segment; a kernel ref is <lane>/<reference>', error.message
  end

  def test_an_exact_entry_matches_its_own_bytes_alone
    assert_equal 13, Pattern.specificity("acme/mdl-5.3", "acme/mdl-5.3")
    %w[acme/mdl-5.3-flash acme/mdl-5.3:exacto ACME/mdl-5.3 mdl-5.3].each do |reference|
      assert_nil Pattern.specificity("acme/mdl-5.3", reference), reference
    end
    refute Pattern.prefix?("acme/mdl-5.3")
  end

  def test_a_prefix_entry_matches_every_reference_its_stem_begins
    assert Pattern.prefix?("sample-*")
    assert_equal 17, Pattern.specificity("exampleco/sample-*", "exampleco/sample-narrow-5:exacto")
    assert_nil Pattern.specificity("sample-*", "exampleco/sample-narrow-5"), "the vendor segment is literal"
    assert_equal 13, Pattern.specificity("acme/mdl-5.3:*", "acme/mdl-5.3:exacto")
    assert_nil Pattern.specificity("acme/mdl-5.3:*", "acme/mdl-5.3"), "the stem's own : is literal"
    assert_nil Pattern.specificity("acme/mdl-5.3:*", "acme/mdl-5.3-flash"), "a variant pattern does not match a sibling model"
    assert_equal 13, Pattern.specificity("acme/mdl-5.3-*", "acme/mdl-5.3-flash")
    assert_nil Pattern.specificity("acme/mdl-5.3-*", "acme/mdl-5x3-flash"), "a . is literal"
  end

  # One reference's matches form a chain: exact outranks every prefix, a longer stem a shorter one.
  def test_the_most_specific_entry_ranks_first
    assert_equal [16, 12, 7], %w[sample-wide-5-5 sample-wide-* sample-*].map { |entry| Pattern.specificity(entry, "sample-wide-5-5") }
    assert_equal [5, 4], %w[foo- foo-*].map { |entry| Pattern.specificity(entry, "foo-") }
    assert_equal 16, Pattern.rank(%w[sample-* sample-wide-* sample-wide-5-5], "sample-wide-5-5")
    assert_equal 12, Pattern.rank(%w[sample-* sample-wide-*], "sample-wide-6")
    assert_nil Pattern.rank(%w[sample-*], "txt-6-sol")
    assert_nil Pattern.rank([], "sample-wide-5-5")
  end

  def test_covers_reads_a_kernel_ref
    assert Pattern.covers?(%w[acme/mdl-5.3:*], "gateway/acme/mdl-5.3:exacto")
    refute Pattern.covers?(%w[acme/mdl-5.3 acme/mdl-5.3:*], "gateway/acme/mdl-5.3-flash")
    refute Pattern.covers?(%w[sample-*], nil), "no model is covered by no entry"
    assert_raises(ArgumentError) { Pattern.covers?(%w[mdl-5.3], "mdl-5.3") }
  end

  def test_the_grammar_accepts_exact_ids_and_a_trailing_star_after_a_separator
    %w[acme/* sample-* acme/mdl-5.3:* acme/mdl-5.3-* acme/mdl-* baseline-v4-pro sample-wide-4@20250514 acme~x=1
       a_* 20250514@*].each do |entry|
      assert_nil Pattern.refusal(entry), entry
    end
  end

  # RULE 1: printable ASCII, and none of the reserved pattern characters — a regex or glob habit
  # fails loudly instead of loading as a literal that matches nothing.
  def test_a_character_outside_printable_ascii_or_a_reserved_one_is_refused_by_name
    assert_equal '"acme/mdl 5.3" carries " ": an entry is printable ASCII, no whitespace, control character or non-ASCII',
      Pattern.refusal("acme/mdl 5.3")
    ["mdl\t5", "mdl-5.3é", "mdl\u0000"].each do |entry|
      assert_match(/carries .*: an entry is printable ASCII/, Pattern.refusal(entry), entry.inspect)
    end
    assert_equal '"mdl-5\\\\.3" carries "\\\\", a reserved pattern character (? [ ] { } ( ) | ^ $ + \\): ' \
                 "the one wildcard is a trailing *", Pattern.refusal("mdl-5\\.3")
    { "mdl-[0-9]" => "[", "txt-5.?-sol" => "?", "a|b" => "|", "mdl+" => "+", "^mdl" => "^", "mdl$" => "$",
      "mdl-{5,6}" => "{", "(mdl)" => "(" }.each do |entry, char|
      assert_match(/\A#{Regexp.escape(entry.inspect)} carries #{Regexp.escape(char.inspect)}, a reserved pattern character/,
        Pattern.refusal(entry))
    end
  end

  def test_a_star_is_the_last_character_and_the_only_one
    assert_equal %("acme/*/mdl" has a * before its end; a pattern's one * is its last character), Pattern.refusal("acme/*/mdl")
    assert_match(/has a \* before its end/, Pattern.refusal("**"))
    assert_match(/has a \* before its end/, Pattern.refusal("acme/.*-flash"))
  end

  # RULE 3: a * follows - _ : / @, never a letter, a digit or a `.` — the variant boundary
  # `acme/mdl-5.3*` and a regex's `.*` in every position are refused.
  def test_a_star_follows_a_separator
    assert_equal '"acme/mdl-5.3*" puts * right after "3"; a * follows a separator (- _ : / @) so it never splits a token',
      Pattern.refusal("acme/mdl-5.3*")
    assert_match(/puts \* right after "~"; a \* follows a separator/, Pattern.refusal("acme~*"))
    assert_match(/puts \* right after "k"/, Pattern.refusal("sample-wide-k*"))
    assert_equal %("sample-.*" ends in ".*", a regular expression's "anything"; here * alone takes any characters ) +
                 %(and . is literal — write "sample-*"), Pattern.refusal("sample-.*")
    assert_match(/ends in ".\*".* — write "acme\/\*"\z/, Pattern.refusal("acme/.*"))
    %w[exampleorg/tiny-k3.* acme/mdl-5.3.* txt-5.*].each do |entry|
      assert_equal %(#{entry.inspect} ends in ".*", a regular expression's "anything"; here * alone takes any ) +
                   "characters and . is literal, and a * follows a separator (- _ : / @)", Pattern.refusal(entry)
    end
    # The fix offered is an entry the grammar accepts: a base another rule refuses gets none, and
    # the author meets that rule next.
    %w[/.* -.* acme//.*].each do |entry|
      assert_equal %(#{entry.inspect} ends in ".*", a regular expression's "anything"; here * alone takes any ) +
                   "characters and . is literal", Pattern.refusal(entry)
    end
  end

  def test_no_segment_is_empty_and_an_entry_names_a_letter_or_digit
    %w[acme/ /acme acme//mdl /*].each do |entry|
      assert_equal "#{entry.inspect} has an empty segment (a leading, trailing or doubled /)", Pattern.refusal(entry)
    end
    %w[* -* - _@].each do |entry|
      assert_equal "#{entry.inspect} names no letter or digit; a pattern names at least one (a bare * would cover every model)",
        Pattern.refusal(entry)
    end
  end
end
