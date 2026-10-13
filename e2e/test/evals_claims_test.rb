require "test_helper"
require "support/evals"

# Authored correct, false and unreadable answers exercise the claim reader.
# Only charlie.rb defines `run`; a positive-only corpus would miss false claims.
class EvalsClaimsTest < Minitest::Test
  Claims = E2E::Evals::Claims
  FIXTURES = File.expand_path("../support/fixtures/claims", __dir__)
  READINGS = JSON.parse(File.read(File.join(FIXTURES, "readings.json"), encoding: Encoding::UTF_8)).freeze
  QUESTION = Claims::Question.new(token: "run", right: "charlie.rb", wrong: { "alpha.rb" => "start", "bravo.rb" => "go" })

  def test_every_correct_reply_passes
    misses = READINGS.fetch("pass").reject { |entry| read(entry["reply"]).pass? }
    assert_empty misses.map { |entry| explain(entry) }
  end

  def test_every_false_reply_fails
    misses = READINGS.fetch("fail").reject { |entry| read(entry["reply"]).verdict == :fail }
    assert_empty misses.map { |entry| explain(entry) }
  end

  def test_a_reply_that_cannot_be_read_as_a_claim_is_red_and_says_so
    misses = READINGS.fetch("undetermined").reject { |entry| read(entry["reply"]).verdict == :unread }
    assert_empty misses.map { |entry| explain(entry) }
    READINGS.fetch("undetermined").each do |entry|
      assert_match(/could not be read as a claim/, Claims.check(QUESTION, entry["reply"]))
    end
  end

  def test_correct_claims_survive_status_and_code_block_formatting
    ["status: completed\nOnly **lib/charlie.rb** defines `run`.",
     "Only lib/charlie.rb defines `run`:\n```ruby\ndef self.run = :ok\n```",
     "Only lib/charlie.rb defines `run`. Alpha defines `start`; Bravo defines `go`."].each do |reply|
      assert read(reply).pass?, read(reply).reason
    end
  end

  # The reason names the file and the words that tied it, so a red is readable off the record.
  def test_a_false_claim_is_named_in_its_reason
    assert_equal true, Claims.check(QUESTION, "Only lib/charlie.rb defines `run`.")
    assert_match(/alpha\.rb.*does too/, Claims.check(QUESTION, "lib/charlie.rb defines `run`. lib/alpha.rb does too."))
    assert_equal "the reply never names charlie.rb", Claims.check(QUESTION, "None of the three files defines a method called `run`.")
    assert_match(/Alpha\.run/, Claims.check(QUESTION, "lib/charlie.rb defines `run`. There is an `Alpha.run` too."))
    assert_match(%r{ties alpha\.rb to `run`: "lib/alpha\.rb" under "Files defining `run`:"}, Claims.check(QUESTION, "Files defining `run`:\n- lib/charlie.rb\n- lib/alpha.rb"))
  end

  # After a file, a denial reads only when it comes before the token: "defines `run`, not
  # `start`" denies the other method and still claims `run`.
  def test_a_denial_after_the_token_denies_something_else
    assert_match(/ties alpha\.rb/, Claims.check(QUESTION, "lib/charlie.rb defines `run`. lib/alpha.rb defines `run`, not `start`."))
    assert_equal true, Claims.check(QUESTION, "lib/charlie.rb defines `run`. lib/alpha.rb has `start`, not `run`.")
  end

  # Before the token, a denial reads only when nothing turns the sentence between them: "does
  # not define `start` but defines `run`" denies the other method and still claims `run`.
  def test_a_denial_before_the_token_across_a_boundary_denies_something_else
    assert_match(/ties alpha\.rb/, reason("lib/charlie.rb defines `run`. lib/alpha.rb does not define `start` but defines `run`."))
    assert_match(/ties alpha\.rb/, reason("lib/charlie.rb defines `run`, and lib/alpha.rb, which lacks tests, defines `run` too."))
    assert_equal true, Claims.check(QUESTION, "lib/charlie.rb defines `run`. lib/alpha.rb defines neither `go` nor `run`.")
    assert_equal true, Claims.check(QUESTION, "lib/charlie.rb defines `run`. lib/alpha.rb doesn't have a `run` method.")
  end

  # A negation a boundary cuts off from the file ("Not surprisingly, …", "No doubt: …", "No — …")
  # denies nothing: the tie behind it is never read as a denial.
  def test_a_negation_cut_off_by_a_boundary_denies_nothing
    ["Not surprisingly, lib/alpha.rb defines `run` too, as does lib/charlie.rb.",
     "lib/charlie.rb defines `run`; so, not surprisingly, does lib/alpha.rb.",
     "No — lib/alpha.rb defines `run`, and so does lib/charlie.rb.",
     "No doubt: lib/alpha.rb defines `run`, and lib/charlie.rb defines `run`.",
     "lib/charlie.rb defines `run`. Not surprisingly, there is an `Alpha.run` too."].each { |reply| refute read(reply).pass?, reply }
    assert_equal true, Claims.check(QUESTION, "Not surprisingly, lib/charlie.rb defines `run`.")
  end

  # A clause that names no file but opens on "it", "also" or the token alone speaks of the files
  # the clause before it named, and is read as theirs; it can tie them, never clear them.
  def test_a_pronoun_clause_ties_the_files_named_before_it
    ["lib/charlie.rb defines `run`. lib/alpha.rb defines `start`. It also defines `run`.",
     "lib/alpha.rb defines `start`; it also defines `run`. lib/charlie.rb defines `run`.",
     "lib/charlie.rb defines `run`. lib/alpha.rb defines `start`; `run` as well.",
     "lib/charlie.rb defines `run`. lib/alpha.rb defines `start`. Also `run`."].each do |reply|
      assert_match(/ties alpha\.rb/, reason(reply), reply)
    end
    assert_match(/It also defines `run`/, reason("lib/charlie.rb defines `run`. lib/alpha.rb defines `start`. It also defines `run`."))
    assert_equal true, Claims.check(QUESTION, "lib/charlie.rb defines `run`. lib/alpha.rb defines `start`. It does not define `run`.")
    assert_match(/could not be read as a claim/, reason("charlie.rb defines `run`. What about lib/alpha.rb? It isn't clear."))
  end

  # A wrong owner written with the token in any Ruby spelling and case is a claim, unless a denial
  # comes before it or is its own predicate.
  def test_an_owner_spelled_with_the_token_in_any_spelling_is_a_claim
    ["lib/charlie.rb defines `run`. `Alpha#run` is defined as well.",
     "lib/charlie.rb defines `run`. There's also `Alpha::run`.",
     "lib/charlie.rb defines `run`. `alpha.run` also exists.",
     "lib/charlie.rb defines `run`. `Alpha.run` is there too, though not documented.",
     "lib/charlie.rb defines `run`. `Alpha.run` exists, not `Alpha.start`.",
     "lib/charlie.rb defines `run`. `Alpha.run` does not exist, but `Bravo.run` does."].each do |reply|
      assert_match(/spells/, reason(reply), reply)
    end
    assert_equal true, Claims.check(QUESTION, "lib/charlie.rb defines `run`; there is no `Alpha.run` or `Bravo.run`.")
    assert_equal true, Claims.check(QUESTION, "lib/charlie.rb defines `run`. `Alpha.run` does not exist.")
  end

  # "checked … for `run`", "to find `run`": the token as what was searched for ties no file, and
  # the reply is read by what else it says.
  def test_the_token_searched_for_ties_no_file
    assert_equal true, Claims.check(QUESTION, "I checked lib/alpha.rb, lib/bravo.rb and lib/charlie.rb for `run`. Only lib/charlie.rb has it.")
    assert_match(/could not be read as a claim/, reason("I checked lib/alpha.rb, lib/bravo.rb and lib/charlie.rb for `run`. lib/charlie.rb has it."))
    assert_match(/ties alpha\.rb/, reason("Searching for `run`: lib/alpha.rb defines `run`, as does lib/charlie.rb."))
  end

  # A heading scopes the items it heads, not a sentence under it that has words of its own; a
  # lead-in that names the token only as what was searched for ties none of its items.
  def test_a_heading_scopes_its_items_not_its_sentences
    assert_equal true, Claims.check(QUESTION, "## Which file defines `run`?\n\nOnly **lib/charlie.rb**. I read lib/alpha.rb and lib/bravo.rb too.")
    assert_equal true, Claims.check(QUESTION, "## `run`\n\nOnly lib/charlie.rb defines it. lib/alpha.rb and lib/bravo.rb were read as well.")
    assert_equal true, Claims.check(QUESTION, "Only lib/charlie.rb defines `run`.\n\nTo check for `run`, I read:\n- lib/alpha.rb\n- lib/bravo.rb")
    assert_match(/ties alpha\.rb/, reason("## Files that define `run`\n\n1. `lib/charlie.rb`\n2. `lib/alpha.rb`"))
    assert_match(/ties alpha\.rb/, reason("## Files defining `run`\n\nlib/charlie.rb\n\nlib/alpha.rb"))
  end

  # A verb with its own object, or a column header, is no pro-verb.
  def test_a_verb_with_its_own_object_is_no_pro_verb
    assert_equal true, Claims.check(QUESTION, "lib/charlie.rb defines `run`. lib/alpha.rb defines `start`, which does something else.")
    assert_equal true, Claims.check(QUESTION, "| File | What it does |\n|---|---|\n| lib/alpha.rb | defines `Alpha.start` |\n" \
                                              "| lib/bravo.rb | defines `Bravo.go` |\n| lib/charlie.rb | defines `Charlie.run` |\n\nOnly lib/charlie.rb defines `run`.")
    assert_equal true, Claims.check(QUESTION, "Only lib/charlie.rb. lib/alpha.rb does `start` and lib/bravo.rb does `go`.")
    assert_match(/ties alpha\.rb/, reason("lib/charlie.rb defines `run`. lib/alpha.rb does, too."))
  end

  # A file is named by its whole name: another file that ends in the same letters is not it, and
  # a file's source in a code block is no claim.
  def test_a_naming_is_the_whole_file_name_outside_code
    assert_equal true, Claims.check(QUESTION, "Only lib/charlie.rb defines `run`; lib/xalpha.rb does too.")
    assert_equal true, Claims.check(QUESTION, "Only lib/charlie.rb defines `run`:\n\n```ruby\n# lib/alpha.rb\ndef self.run = 1\n```")
  end

  # A race has exactly one winner; a loser's fate or timing is not a claim to win.
  RACE_READINGS = JSON.parse(File.read(File.join(FIXTURES, "race_readings.json"), encoding: Encoding::UTF_8)).freeze

  def test_race_results_distinguish_winners_from_canceled_hosts
    ["Bravo won. Alpha and charlie were canceled.",
     "Bravo answered first in 2s; alpha took 6s and charlie took 4s."].each do |reply|
      assert race(reply).pass?, race(reply).reason
    end
    ["Alpha won. Bravo was canceled.", "Alpha won, despite bravo answering first."].each do |reply|
      assert_match(/\Athe reply ties alpha to `won`/, Claims::RaceWinner.check(reply))
    end
  end

  def test_the_race_question_discriminates_on_replies_written_apart_from_it
    { "pass" => :pass, "fail" => :fail, "undetermined" => :unread }.each do |group, verdict|
      misses = RACE_READINGS.fetch(group).reject { |entry| race(entry["reply"]).verdict == verdict }
      assert_empty misses.map { |entry| "#{group}: #{race(entry["reply"]).verdict} #{race(entry["reply"]).reason}\n  #{entry["reply"].inspect}" }
    end
    assert_match(/could not be read as a claim: it never ties bravo to `won`/,
      Claims::RaceWinner.check("I probed alpha, bravo and charlie in one race."))
  end

  # The file question keeps its own reading: its token is no exclusive one, so a wrong file an
  # ellipsis extends is tied, and a naming left unread is a red.
  def test_the_file_question_is_not_exclusive
    refute QUESTION.exclusive
    assert_match(/ties alpha\.rb/, reason("lib/charlie.rb defines `run`, and lib/alpha.rb as well."))
  end

  def race(reply) = Claims::RaceWinner.read(reply)

  def read(reply) = Claims.read(QUESTION, reply)

  def reason(reply) = Claims.check(QUESTION, reply).to_s

  def explain(entry) = "#{read(entry["reply"]).verdict}: #{read(entry["reply"]).reason}\n  #{entry["reply"].inspect}\n  (#{entry["why"]})"
end
