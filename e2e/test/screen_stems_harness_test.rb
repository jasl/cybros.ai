$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "minitest/autorun"
require "set"
require "support/screen/stems"

# THE HELD-OUT CHECK IS MECHANICAL: a primary stimulus may share no listed stem with what the arm's
# diff ADDS. The tokenizer, the stemmer and the stop-list are code, so the sets a stamp prints are
# the ones this test reproduces — the door screens' four primary stimuli (D1P D2P D4P, and the Q
# screen's D3P) against the lines the final R-LADDER candidate adds (only the lines a diff adds: the
# compose paragraph's two unchanged opening lines and the task paragraph's unchanged review line are
# not among them). D1P shares `account`, `list`, `not`, `one`, `only`, `per`, `return` and `two`;
# D2P `file` ("file dumps"), `not`, `take`, `three` and `two`; D4P `not` and `want`; D3P `one`. None
# is listed, so none stops a launch.
class ScreenStemsHarnessTest < Minitest::Test
  Stems = E2E::Screen::Stems

  ADDED = <<~TEXT.lines
    {{task}}. When you will read the answers yourself — one job, or several
    whose answers you merge — use `{{task}}` calls, several in ONE message;
    you keep the conclusion, not the file dumps. A long command whose result
    you want later is one `{{task}}` call, never a one-step `{{compose}}`. Use
    `{{compose}}` when the answers must go on to further steps without passing
    through you: verifiers or judges whose answers one later step counts or
    weighs, a chain per item where each item moves on as soon as its own
    step is done, or a question for a person in the middle of the work. When
    a fan's items are not in the request, list them first with plain calls,
    then fan with `{{task}}` calls or pass them to `{{compose}}` in `params`. Read
    what one `{{compose}}` delivers before you plan the next.
    Beside the examples above, two shapes cover most work. A CHAIN PER ITEM
    is the per-directory pairs: each item moves on as soon as its own step
    is done. A PANEL is a fan of verifiers or judges, each briefed alone,
    and one reader that names them all — a g.model, since weighing them
    takes judgement (an "all" g.parallel of single steps returns their
    handles):

      const lenses = ["data loss", "locking", "rollback"];
      const reviews = g.parallel(lenses.map((lens) => g.model({ prompt: "Read db/migrate/20260927_split_accounts.rb. Through the " + lens + " lens only: is it safe to run on production? Answer `ship` or `hold` and the one risk that decides it." })));
      g.model({ prompt: "Weigh the three reviews; answer `ship` or `hold` and the deciding risk.", results: reviews });

    want summarised — you keep the conclusion, not the file dumps), for a
    long command whose result you want later, or for several jobs at once
    whose answers you will read yourself; not for a file or a few greps you
    can do yourself, several in one message.
  TEXT

  D1P = <<~TEXT.freeze
    Six claims about lib/ledger.rb, lib/posting.rb and lib/balance.rb are listed below. For each claim, two fresh agents — each seeing only the claim and the code — try to disprove it; a claim is sound only if both fail. Do not rule on the claims yourself: hand the disproving out and collect what they find. Reply with one line per claim, `C<n>: sound` or `C<n>: broken`.
    C1 `Ledger#post` rejects a posting whose amount is zero.
    C2 `Balance.for` sums only postings whose `settled` flag is true.
    C3 `Posting#reverse` returns a new posting and leaves the original unchanged.
    C4 `Ledger#post` is idempotent on a posting's `id`.
    C5 `Balance.for` raises when the account is unknown.
    C6 `Posting.new` normalises its currency code to upper case.
  TEXT
  D2P = "docs/date_format.md describes a date format; lib/fmt_a.rb and lib/fmt_b.rb are two candidate implementations. " \
       "Three fresh agents each take the doc and both files and score both candidates against it; a fourth agent adds up " \
       "the three scores and makes the pick. Do not score them yourself. Reply `pick: fmt_a` or `pick: fmt_b`.".freeze
  D4P = "Kick off the full suite, `ruby test/all.rb`, in the background now; it is slow and I do not want you waiting on it. " \
       "Meanwhile tell me how many Ruby sources sit under lib/ — reply with just that number, and do not let the suite delay " \
       "your reply.".freeze
  D3P = "lib/a.rb, lib/b.rb, lib/c.rb, lib/d.rb and lib/e.rb each define one method that is unused anywhere under lib/. Hand each " \
        "of the five to its own fresh agent, all at the same time, to find that method; then gather what the five report into one " \
        "reply, a line for each: `lib/<x>.rb — <method>`.".freeze
  LIST = %w[verif* judge* count* weigh* chain item panel lens review* brief* merge fan ship hold name* decid* answer*
            result later long command conclusion dump plan].push("one job", "later step", "moves on", "comes back").freeze

  def test_the_four_primaries_reproduce_their_sets_and_none_holds_a_listed_stem
    {
      D1P => %w[account list not one only per return two],
      D2P => %w[file not take three two],
      D4P => %w[not want],
      D3P => %w[one],
    }.each do |stimulus, expected|
      shared = Stems.intersection(stimulus, ADDED, list: LIST)
      assert_equal expected.to_set, shared, stimulus[0, 40]
      assert_empty Stems.listed(shared, list: LIST), stimulus[0, 40]
    end
  end

  def test_the_stemmer_folds_plurals_and_endings_and_the_stop_list_drops_function_words
    assert_equal %w[claim list return decid name see judg account], %w[claims listed returns deciding named seeing judging accounts].map { |word| Stems.stem(word) }
    assert_equal %w[answer weigh pass], Stems.tokens("Answers weighs `passing`"), "backticks and case fall away"
    assert_empty Stems.tokens("the a of to and is it you"), "the stop-list"
    assert_equal %w[not one two only per want], Stems.tokens("not one two only per want"), "cue-bearing function words stay"
  end

  # A listed stem stops the launch: a wildcard by prefix, a word by its stem, a phrase by its
  # stems in order on both sides. The final text says an item "moves on" and no longer that a result
  # "comes back".
  def test_a_listed_stem_or_phrase_is_found_in_the_intersection
    shared = Stems.intersection("Two judges weigh it; the item moves on and one job runs.", ADDED, list: LIST)
    assert_equal ["item", "judge", "moves on", "one job", "weigh"].to_set, Stems.listed(shared, list: LIST)
    assert_includes shared, "one job", "a listed phrase on both sides rides the intersection"
    refute_includes Stems.intersection("the result comes back", ADDED, list: LIST), "comes back"
    refute_includes Stems.intersection("one of the jobs", ADDED, list: LIST), "one job", "a phrase is contiguous"
  end
end
