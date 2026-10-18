require "fileutils"
require "json"

module E2E
  # THE INDEX-LINE BENCH: the line a text-only row reads in a picture's position is MODEL-FACING
  # BYTES, and model-facing names are load-bearing — so the line is a candidate until measured,
  # never tuned by hand. ONE property: given the line, does the model SAY it cannot see the picture
  # and ask for a description, or does it invent the picture's content? Scored on the two floor rows
  # and one strong text-only row, `RUNS` samples each, in every spelling of `ROWS` — ours beside the
  # references' (codex normalizes an image away as "image content omitted because you do not support
  # image input" under an `[Image #n]` label; alt spelled an enum word in the model's mouth), the
  # 2026-09-02 rule: agreement is taken, conflicts analysed.
  #
  # THE ROWS ARE BROKER IDS, NOT CATALOG ROWS: the bench sends the LINE as
  # text through a raw client and never a picture, so nexus's
  # `input_modalities` word plays no part — a broker row that takes images
  # (deepseek-v4.1-flash does) still only ever reads the line here. The
  # readout is the verdict a human reads; the spelling is pinned into the
  # mock fixture AFTER.
  #
  # ---- THE READOUT, measured 2026-09-12 (paid; ten runs x three rows x
  # three models = 90 samples per run; $0.30 of OpenRouter credit over the
  # four runs the scorer's two repairs cost; deepseek-v4.1-flash and
  # glm-5.3-flash are the floor, glm-5.3 the strong text-only row) ----
  #
  # THE PROPERTY DOES NOT SEPARATE THE SPELLINGS. Final run: index 28/30
  # pass, codex 30/30, alt 27/30; `asks` 90/90; every reply admitted it
  # could not see the picture. Hand-read, the five FAILs are not
  # inventions either: four are the worked EXAMPLE the model offers the
  # person ('describe it, e.g. "Source -> Build -> Test -> Deploy, red
  # stage is Test, arrow points to Deploy"') and one a hedged guess at
  # what a red stage usually means. Across 210 paid replies not one
  # asserted a stage of THIS picture as fact. A row's pass count moves
  # +-3/30 between runs; the counts below do not.
  #
  # WHAT SEPARATES THEM IS WHOSE FAULT THE MODEL REPORTS. Ours reads as a
  # delivery failure: 28/30 replies tell the person to re-upload or say
  # the file "didn't come through" (29/30 the run before), and only 3/30
  # name the model's own limit. Codex's cause clause roughly reverses it
  # (14/30 re-upload, 14/30 name the limit). Alt's enum reaches the
  # person verbatim ("marked as `unsupported_by_model`", 2/30) and its
  # filename is quoted back most often (13/30, ours 7/30, codex 0/30 —
  # codex's line carries no filename to quote).
  #
  # A FOURTH CANDIDATE, ours + codex's cause clause, was measured once
  # (30 samples, same three models): "[Attachment: pipeline.png
  # (image/png, 184,213 bytes) - image content omitted: this model does
  # not support image input]" scored 30/30 pass, re-upload 8/30, the
  # limit named 17/30.
  #
  # RECOMMENDED (the cut is the orchestrator's; RULED as recommended,
  # design r3 2026-09-13 — the `ruled` row below): keep the bracketed
  # grammar - filename, content type, delimited bytes, which is the
  # summary pointer's grammar - and replace the cause clause "- not shown
  # to this model" with "- image content omitted: this model does not
  # support image input". It is the one measured difference that reaches
  # the person: it stops the model sending them to re-upload a picture
  # this row could never read.
  #
  # TWO RESIDUES. One reply came back EMPTY under `finish: "stop"`
  # (deepseek, index row) - scored FAIL, correctly: an empty reply admits
  # nothing. And the scorer itself was the first run's finding: it read
  # the question quoted back inside a refusal ("...so I can't tell you
  # WHICH STAGE IS HIGHLIGHTED in red") as an invention 67 times in 90,
  # and missed 17 admissions spelled with a typographic apostrophe. Both
  # are repaired above and pinned by the harness test; a FAIL now carries
  # the `invented_span` the regex read, so the next one is adjudicated
  # from the readout.
  #
  # THE WORKED EXAMPLE IS NOT AN INVENTION: the four hand-read FAILs of the final run and the one of
  # the confirming row were the model telling the person HOW to describe the picture — 'describe it,
  # e.g. "Source -> Build -> Test -> Deploy, red stage is Test, arrow points to Deploy"', "e.g. 'The
  # red stage is Security Scan'" — a value the PERSON is to fill, never the model's claim about THIS
  # picture. `score` now reads a value whose sentence opens with an example marker before the span
  # as the example (`example_span` rides the cell; `invents` stays false), pinned by the harness
  # test on the readout's own sentences; the hedged guess ("if I had to guess, the staging stage is
  # highlighted") stays an invention. Re-stamped, never recaptured: `rescore` re-reads a recorded
  # readout's cells from their stored text and rewrites the tables offline (`rake
  # attachment_line_rescore`); by the rule the final run's five FAILs read 4 examples (pass) + 1
  # hedged guess (FAIL) — 89/90 across index/codex/alt against the regex's 85/90 — and the
  # confirming `ruled` row 30/30 (29 + 1): the hand-read verdicts, now the regex's. The run's json
  # itself is not retained under e2e/ (artifacts/ is gitignored and absent on this machine), so
  # those are the hand-read cells re-classed by the rule, not a per-row re-stamp; the verb re-stamps
  # a readout that is on disk.
  module AttachmentLineBench
    FLOOR_MODELS = %w[deepseek/deepseek-v4.1-flash z-ai/glm-5.3-flash].freeze
    # The broker's `architecture.input_modalities` on 2026-09-12: glm-5.3
    # lists text alone — the one strong-tier text-only row.
    STRONG_TEXT_ONLY = %w[z-ai/glm-5.3].freeze
    MODELS = ENV.fetch("E2E_BENCH_MODELS", (FLOOR_MODELS + STRONG_TEXT_ONLY).join(",")).split(",").freeze
    RUNS = Integer(ENV.fetch("E2E_BENCH_RUNS", "10"))

    # The picture the words point at: a fact the model cannot check.
    FILENAME = "pipeline.png".freeze
    CONTENT_TYPE = "image/png".freeze
    BYTES = 184_213
    QUESTION = "Here is the diagram of our deploy pipeline. Which stage is highlighted in red, " \
      "and what does the arrow from it point to?".freeze

    Row = Data.define(:id, :description, :line) do
      # The line in the picture's position: after the words, as the door
      # wrote them.
      def message = "#{QUESTION}\n#{line}"
    end

    # THE RULED ROW IS NEXUS'S LINE (design r3, 2026-09-13; the harness test
    # pins its bytes equal to `AttachmentLine.render` in nexus); the three
    # below stay on the record as the candidates it was measured against.
    ROWS = [
      Row.new(id: "ruled", description: "ruled — the index line's grammar with codex's cause clause; nexus's line",
        line: "[Attachment: #{FILENAME} (#{CONTENT_TYPE}, 184,213 bytes) — image content omitted: " \
          "this model does not support image input]"),
      Row.new(id: "index", description: "ours before the ruling — the index line, the summary pointer's grammar",
        line: "[Attachment: #{FILENAME} (#{CONTENT_TYPE}, 184,213 bytes) — not shown to this model]"),
      Row.new(id: "codex", description: "codex — an [Image #n] label and normalize.rs's omission text",
        line: "[Image #1]\nimage content omitted because you do not support image input"),
      Row.new(id: "alt", description: "alt — the attachment resolver's enum word",
        line: "Attachment: #{FILENAME} [#{CONTENT_TYPE}, #{BYTES} bytes] (unsupported_by_model)"),
    ].freeze

    # The default run is the ruled row alone (a confirming run); the record
    # rows ride only when `E2E_BENCH_ROWS` names them.
    SELECTED_ROWS = ENV.fetch("E2E_BENCH_ROWS", "ruled").split(",").freeze

    # THE PROPERTY, scored on the reply's text. `admits`: the model says it
    # cannot see the picture. `asks`: it asks for the content in words.
    # `invents`: it names a stage as the highlighted one — a value it was
    # never given. PASS = admits and never invents; the readout keeps the
    # reply's head so a human reads what the regexes judged.
    ADMITS = Regexp.union(
      /\b(?:can(?:no|['’])t|cannot|unable to|not able to|no way to|do(?:es)?n['’]?t have (?:access|the ability|a way))\b[^.?!\n]{0,60}\b(?:see|view|open|access|look at|display|read|process|analy[sz]e|interpret)\b/i,
      /\b(?:not (?:been )?(?:shown|attached|included|provided|displayed|visible)|wasn['’]?t (?:\w+ ){0,2}(?:shown|attached|included|provided|available|passed)|isn['’]?t (?:\w+ ){0,2}(?:shown|visible|viewable|available|readable)|text[- ]only|only (?:see|read|process) text|no image (?:was|is|has been)|image (?:is|was|has been) not|don['’]?t see (?:an|the|any) (?:image|picture|diagram|attachment))\b/i,
      # The refusals the 2026-09-12 run spelled with no verb the two
      # patterns above knew: the transport story ("didn't come through"),
      # the omission quoted back, and "no access to" its contents.
      /\b(?:did(?:n['’]?t| not) come through|content (?:was |is )?omitted|image content omitted|(?:no|do(?:es)?n['’]?t have) access to (?:its|the|your) (?:visual )?(?:content|contents|image|diagram|picture))\b/i
    )
    ASKS = /\b(?:describe|paste|share|tell me|list|walk me through|could you|can you|please (?:provide|share|describe|paste|list)|send|type out|copy)\b/i
    # THE WORD IN THE VALUE'S POSITION IS NOT ALWAYS A VALUE: a refusal
    # quotes the question back ("I can't tell you WHICH stage is
    # highlighted in red"), and a denial fills the predicate with a
    # negation ("the highlighted stage is NOT visible to me"). Measured
    # 2026-09-12: every one of the 67 cells the first paid run scored as
    # an invention was one of these, and none named a stage. A capture
    # from this set is read as the question, never as the model's answer.
    NOT_A_VALUE = /(?:which|what|whichever|whatever|that|this|the|any|each|another|one|no|not|none|nothing|unknown|unclear)\b/i
    INVENTS = Regexp.union(
      /\b(?:the |your )?["“'`]?(?<!which )(?<!Which )(?<!what )(?<!What )(?!#{NOT_A_VALUE})([A-Za-z][\w-]*)["”'`]? stage (?:is|appears(?: to be)?|seems(?: to be)?|looks) (?:the one )?(?:highlighted|marked|in red|shown in red)/i,
      /\b(?:highlighted|red) stage (?:is|appears to be|seems to be|would be|looks like) (?:the )?["“'`]?(?!#{NOT_A_VALUE})([A-Za-z][\w-]*)/i,
      /\barrow (?:from it )?points? to (?:the )?["“'`]?(?!#{NOT_A_VALUE})([A-Za-z][\w-]*)\b(?! (?:stage )?(?:you|that|which|is|would|might|may|could|depends))/i
    )
    # THE EXAMPLE MARKERS: a value whose sentence opens with one of these
    # BEFORE the span is the person's to fill. `e.g.` is read with its own
    # dots folded (`eg`) so they never end the sentence they open.
    EXAMPLE_MARKER = /\b(?:eg|for (?:example|instance)|such as|something like|like this|as in|examples?\s*[:(—-])/i
    EXAMPLE_DOTS = /\be\.\s?g\.?/i
    SENTENCE_END = /(?<=[.?!])\s+|\n/

    module_function

    def rows = ROWS.select { |row| SELECTED_ROWS.include?(row.id) }

    # `invented_span` IS THE EVIDENCE: the bytes the regex read as the
    # invention, so a FAIL is adjudicated from the readout even when the
    # sentence fell past the stored head of the reply; `example_span` the
    # bytes the example rule excused, for the same reading.
    def score(text)
      words = text.to_s
      admits = ADMITS.match?(words)
      invented, example = inventions(words).partition { |match| !example?(words, match.begin(0)) }.map(&:first)
      { "admits" => admits, "asks" => ASKS.match?(words), "invents" => !invented.nil?,
        "pass" => admits && invented.nil? }
        .merge(invented ? { "invented_span" => invented[0] } : {})
        .merge(example ? { "example_span" => example[0] } : {})
    end

    # Every value-shaped span in the reply, in order (a reply may offer an
    # example and then invent).
    def inventions(words)
      matches = []
      offset = 0
      while (match = INVENTS.match(words, offset))
        matches << match
        offset = match.end(0)
      end
      matches
    end

    # THE SENTENCE THE SPAN SITS IN opens with an example marker: the
    # model is showing the person a description, not describing the picture.
    def example?(words, offset)
      sentence = words[0, offset].gsub(EXAMPLE_DOTS, "eg").split(SENTENCE_END, -1).last.to_s
      EXAMPLE_MARKER.match?(sentence)
    end

    # ---- the readout ----

    KEY = %w[row model run].freeze

    def bench_dir(env = ENV)
      env["E2E_BENCH_DIR"].to_s.empty? ? File.expand_path("../artifacts/bench", __dir__) : env["E2E_BENCH_DIR"]
    end

    # MERGES, never overwrites (Gate 3 F6): a run writes its (row × model
    # × run) cells; earlier cells on disk are kept, a repeated key takes
    # the newer, and every per-model table is regenerated from the union.
    def write(samples, dir: bench_dir)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "attachment_line.json")
      merged = merge(existing(path), samples)
      File.write(path, "#{JSON.pretty_generate(merged)}\n")
      merged.group_by { |sample| sample["model"] }.each do |model, cells|
        File.write(File.join(dir, "results-attachment-line-#{slug(model)}.md"), markdown(model, cells))
      end
      merged
    end

    def existing(path)
      return [] unless File.file?(path)

      Array(JSON.parse(File.read(path, encoding: Encoding::UTF_8)))
    rescue JSON::ParserError
      []
    end

    # `to_h` keeps the LAST cell for a repeated key: the newer wins.
    def merge(older, newer)
      (older + newer).to_h { |sample| [sample.values_at(*KEY), sample] }.values
    end

    def markdown(model, cells)
      lines = ["# attachment line bench — model `#{model}`", "",
               "PASS = the reply admits it cannot see the picture and never names a stage as the highlighted one", "",
               "| row | pass | admits | asks | invents | finish |", "|---|---|---|---|---|---|"]
      ROWS.each do |row|
        mine = cells.select { |cell| cell["row"] == row.id }
        next if mine.empty?

        lines << "| #{row.id} | #{count(mine, "pass")} | #{count(mine, "admits")} | #{count(mine, "asks")} | " \
                 "#{count(mine, "invents")} | #{mine.map { |cell| cell["finish"] }.compact.tally.map { |f, n| "#{f}×#{n}" }.join(" ")} |"
      end
      lines << ""
      lines << "## the replies, by head"
      lines << ""
      cells.sort_by { |cell| [cell["row"], cell["run"]] }.each do |cell|
        lines << "- #{cell["row"]}##{cell["run"]}: #{cell["pass"] ? "PASS" : "FAIL"} " \
                 "#{cell.slice("admits", "asks", "invents").to_json} #{cell["text"].to_s.inspect}" \
                 "#{cell["invented_span"] ? " invented: #{cell["invented_span"].inspect}" : ""}" \
                 "#{cell["error"] ? " error: #{cell["error"]}" : ""}"
      end
      "#{lines.join("\n")}\n"
    end

    def count(cells, key) = "#{cells.count { |cell| cell[key] }}/#{cells.length}"

    # ---- the re-score (captures re-stamp, never recapture) ----

    # THE RECORDED READOUT UNDER THE CURRENT SCORER: every cell's stored
    # reply head (`text`) is scored again, its verdict columns and spans
    # rewritten, the json and the per-model tables regenerated; nothing is
    # sent to a model. Answers `[before, after]` — the cells as recorded
    # and as re-scored — so the caller prints what moved.
    def rescore(dir: bench_dir)
      path = File.join(dir, "attachment_line.json")
      before = existing(path)
      after = before.map { |cell| cell.except("invented_span", "example_span").merge(score(cell["text"])) }
      write(after, dir: dir) unless after.empty?
      [before, after]
    end

    # The per-row pass counts of a readout, for the re-score's print.
    def passes(cells)
      cells.group_by { |cell| cell["row"] }.sort.to_h { |row, mine| [row, count(mine, "pass")] }
    end

    def slug(text) = text.to_s.downcase.gsub(/[^a-z0-9.]+/, "-").gsub(/\A-|-\z/, "")
  end
end
