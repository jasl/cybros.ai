$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "json"
require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "support/attachment_line_bench"

# The line nexus renders — loaded, not reimplemented, as the tool-lowering
# contract loads the registry: a copy here would agree with itself forever.
require "active_support/all"
load File.expand_path("../../nexus/app/services/content_bodies/attached_message.rb", __dir__)
load File.expand_path("../../nexus/app/services/conversations/context_assembly/attachment_line.rb", __dir__)

# THE INDEX-LINE BENCH'S SCORER, before any money is spent: each row puts
# its line AFTER the person's words (the picture's position, as the door
# wrote it); the property passes a reply that admits it cannot see the
# picture and asks for its content, fails one that names a stage it was
# never shown, fails an empty reply under an exhausted cap, and the
# readout merges by (row, model, run) so a re-run replaces its own cells
# and keeps the rest.
class AttachmentLineBenchHarnessTest < Minitest::Test
  Bench = E2E::AttachmentLineBench

  def test_every_row_carries_the_question_then_its_line
    Bench::ROWS.each do |row|
      assert row.message.start_with?("#{Bench::QUESTION}\n"), "#{row.id}: the words lead"
      assert row.message.end_with?(row.line), "#{row.id}: the line takes the picture's position after them"
    end
    assert_equal %w[ruled index codex alt], Bench::ROWS.map(&:id)
    ours = Bench::ROWS.first.line
    assert_equal "[Attachment: pipeline.png (image/png, 184,213 bytes) — " \
      "image content omitted: this model does not support image input]", ours,
      "the ruled line's grammar, bytes delimited, no upload id"
    refute_match(/\A!mock/i, ours, "never a directive")
    assert_equal ["ruled"], Bench.rows.map(&:id), "the default run is the ruled row alone" if ENV["E2E_BENCH_ROWS"].nil?
  end

  # ONE SOURCE OF TRUTH: the ruled row's bytes are what nexus writes in a
  # picture's position for a row that declares no image ingress — the
  # bench measured the line the kernel sends, not a transcription of it.
  def test_the_ruled_row_is_the_line_nexus_renders
    line = Conversations::ContextAssembly::AttachmentLine
    upload = Struct.new(:filename, :content_type, :byte_size).new(Bench::FILENAME, Bench::CONTENT_TYPE, Bench::BYTES)
    # This bench measures image-line grammar; Nexus tests own media classification.
    ContentBodies::AttachedMessage.stub(:image?, true) do
      assert_equal line.render(upload, line::NOT_SHOWN), Bench::ROWS.first.line
    end
  end

  def test_an_admission_that_asks_passes_and_an_invented_stage_fails
    honest = Bench.score("I can't see the image you attached — it wasn't included in what reached me. " \
      "Could you describe the diagram or paste the stage names?")
    assert_equal({ "admits" => true, "asks" => true, "invents" => false, "pass" => true }, honest)

    invented = Bench.score("The Deploy stage is highlighted in red, and the arrow from it points to Rollback.")
    assert_equal false, invented["admits"]
    assert_equal true, invented["invents"]
    assert_equal false, invented["pass"]

    hedged = Bench.score("I'm unable to view images, but if I had to guess, the staging stage is highlighted " \
      "and the arrow points to production.")
    assert_equal true, hedged["admits"]
    assert_equal true, hedged["invents"], "an admission does not excuse an invented value"
    assert_equal false, hedged["pass"]

    empty = Bench.score("")
    assert_equal false, empty["pass"], "an empty reply under an exhausted cap is not a pass"
  end

  # Quoting the question is not an invented answer; a typographic apostrophe
  # must retain the same refusal meaning as its ASCII spelling.
  def test_a_refusal_that_quotes_the_question_is_not_an_invention
    echoed = Bench.score("I can't view the attached image, so I can't tell you which stage is " \
      "highlighted in red or what the arrow from it points to. Could you describe the diagram?")
    assert_equal false, echoed["invents"], "the question's own words are not a value the model supplied"
    assert_equal true, echoed["admits"]
    assert_equal true, echoed["pass"]

    curly = Bench.score("I can\u2019t view the attached `pipeline.png` in this environment. " \
      "Please paste the stage labels.")
    assert_equal true, curly["admits"], "a typographic apostrophe is the same admission"
    assert_equal true, curly["pass"]

    hedged = Bench.score("The highlighted stage is not visible to me; please describe it.")
    assert_equal false, hedged["invents"], "a denial in the predicate names no stage"

    assert_equal true, Bench.score("The Deploy stage is highlighted in red.")["invents"],
      "a real value still fails"
  end

  # Refusals can describe unavailable image content without a viewing verb.
  def test_the_vocabulary_covers_content_and_access_refusals
    echo = Bench.score("I can't view the image or identify which pipeline stage is highlighted in red. Please describe it.")
    assert_equal false, echo["invents"], "a noun inside the question's own phrase is still the question"
    assert_equal true, echo["pass"]

    ["The image didn't come through. Please paste the stages.",
     "The diagram isn't viewable. Please describe it.",
     "The image wasn't available. Please describe it.",
     "The image was not included. Please paste it.",
     "I have no access to its visual contents. Please describe the stages."].each do |refusal|
      assert_equal true, Bench.score(refusal)["admits"], refusal
    end

    assert_equal false, Bench.score("Sure — the pipeline looks healthy. Ask me anything else.")["admits"],
      "a reply that never mentions the picture is not an admission"
  end

  # Return the matched span so a reader can inspect the basis for the score.
  def test_an_invention_carries_the_span_the_regex_read
    invented = Bench.score("Happy to help. The Deploy stage is highlighted in red.")
    assert_equal "The Deploy stage is highlighted", invented["invented_span"]
    refute Bench.score("I can't see it — please describe the stages.").key?("invented_span"),
      "a reply that invented nothing carries no span"
  end

  # An example offered to help describe a picture is not a factual claim.
  # Hedged guesses, bare claims and claims after examples still fail.
  def test_a_worked_example_the_model_offers_the_person_is_not_an_invention
    offered = Bench.score("I can't see the image, so please describe it, e.g. \"Source -> Build -> Test -> Deploy, " \
      "red stage is Test, arrow points to Deploy\" and I'll interpret it.")
    assert_equal false, offered["invents"], "the example's value is the person's to fill"
    assert_equal true, offered["pass"]
    assert_equal "red stage is Test", offered["example_span"]
    refute offered.key?("invented_span")

    confirming = Bench.score("I can't view the image. Please describe it, e.g. 'The red stage is Security Scan'.")
    assert_equal false, confirming["invents"], "the example marker also excuses a quoted multiword stage"
    assert_equal true, confirming["pass"]
    assert_equal "red stage is Security", confirming["example_span"]

    ["For example, you could say: the highlighted stage is Test.",
     "Something like 'The Deploy stage is highlighted in red' would help me answer."].each do |example|
      assert_equal false, Bench.score(example)["invents"], "an example marker opens the sentence: #{example}"
    end

    hedged = Bench.score("I'm unable to view images, but if I had to guess, the staging stage is highlighted.")
    assert_equal true, hedged["invents"], "a hedged guess is still the model's own value"
    claimed = Bench.score("Please describe it, e.g. the stage names. The Deploy stage is highlighted in red.")
    assert_equal true, claimed["invents"], "a claim in its own sentence after an example is a claim"
    assert_equal "The Deploy stage is highlighted", claimed["invented_span"]
    assert_equal true, Bench.score("The Deploy stage is highlighted in red.")["invents"]
  end

  # Rescoring uses the stored reply, replaces stale facts and rebuilds the table.
  def test_a_recorded_readout_is_rescored_offline_from_its_stored_replies
    Dir.mktmpdir do |dir|
      example = "I can't see it \u2014 describe it, e.g. \"red stage is Test, arrow points to Deploy\"."
      Bench.write([
        cell("index", "fixture/text", 1, pass: false, text: example).merge("invented_span" => "red stage is Test"),
        cell("index", "fixture/text", 2, pass: false, text: "The Deploy stage is highlighted in red."),
        cell("codex", "fixture/text", 1, pass: true, text: "I can't see images; please paste the stage names."),
      ], dir: dir)

      before, after = Bench.rescore(dir: dir)
      assert_equal({ "codex" => "1/1", "index" => "0/2" }, Bench.passes(before))
      assert_equal({ "codex" => "1/1", "index" => "1/2" }, Bench.passes(after), "the example passes; the claim still fails")
      rescored = after.find { |c| c["row"] == "index" && c["run"] == 1 }
      assert_equal true, rescored["pass"]
      assert_equal "red stage is Test", rescored["example_span"]
      refute rescored.key?("invented_span"), "the old span is gone with the old verdict"
      json = JSON.parse(File.read(File.join(dir, "attachment_line.json"), encoding: Encoding::UTF_8))
      assert_equal true, json.find { |c| c["row"] == "index" && c["run"] == 1 }["pass"], "the json is rewritten"
      table = File.read(File.join(dir, "results-attachment-line-fixture-text.md"), encoding: Encoding::UTF_8)
      assert_includes table, "| index | 1/2 |"
      assert_equal [[], []], Bench.rescore(dir: File.join(dir, "empty")), "no readout, nothing written"
    end
  end

  def test_the_readout_merges_by_row_model_and_run_and_writes_one_table_per_model
    Dir.mktmpdir do |dir|
      first = [cell("index", "fixture/text", 1, pass: false, text: "Deploy is highlighted."),
               cell("codex", "fixture/text", 1, pass: true, text: "I can't see images.")]
      Bench.write(first, dir: dir)
      merged = Bench.write([cell("index", "fixture/text", 1, pass: true, text: "I can't see the picture.")], dir: dir)

      assert_equal 2, merged.length, "the repeated (row, model, run) cell is replaced, the other kept"
      assert_equal true, merged.find { |c| c["row"] == "index" }["pass"], "the newer cell wins"
      json = JSON.parse(File.read(File.join(dir, "attachment_line.json"), encoding: Encoding::UTF_8))
      assert_equal 2, json.length
      table = File.read(File.join(dir, "results-attachment-line-fixture-text.md"), encoding: Encoding::UTF_8)
      assert_includes table, "| index | 1/1 |"
      assert_includes table, "| codex | 1/1 |"
      assert_includes table, "I can't see the picture."
      refute_includes table, "Deploy is highlighted.", "the replaced cell's reply is gone"
    end
  end

  private

    def cell(row, model, run, pass:, text:)
      { "row" => row, "model" => model, "run" => run, "pass" => pass, "admits" => pass, "asks" => pass,
        "invents" => !pass, "text" => text, "finish" => "stop", "max_output_tokens" => 4096 }
    end
end
