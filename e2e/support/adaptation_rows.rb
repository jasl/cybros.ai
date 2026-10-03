require "active_support/all"
require "cybros_agent"
require "json"
require "yaml"
require_relative "../../nexus/app/services/conversations/compaction/summarizer"
require_relative "../../nexus/lib/nexus/tool_registry"
require_relative "../../nexus/lib/nexus/tool_declarations"
require_relative "../../nexus/lib/nexus/tool_declarations/render"

module E2E
  # The harness loads the SDK's adaptation pack and alias tables instead of copying them. It adds
  # local preset rows under each daemon home's `adaptations/`, named candidates loaded by
  # `<row>/<id>`, and an `adaptations` fact on each evaluation record. `style_row` and
  # `kernel_entries_under` are shared by both text benches so the declarations and rendered kernel
  # text stay aligned. Unknown candidate names are refused; candidate data stays in the harness
  # until explicitly adopted into the SDK pack.
  module AdaptationRows
    Pack = CybrosAgent::ModelAdaptations
    CANDIDATES_DIR = File.expand_path("../evals/candidates", __dir__)
    # The one key a candidate's kind carries beside `id`, `kind`, `seed`.
    KINDS = { "tool_style" => "value", "lead_hints" => "text", "summarizer_prompt" => "recut", "tool_descriptions" => "entry" }.freeze
    BENCH_ROW_PREFIX = "bench-".freeze

    # ONE CANDIDATE: its row, its id, its kind and the payload its kind
    # takes. `key` is the spelling every knob reads (`<row>/<id>`, `kimi-k3/some-hint`).
    Candidate = Data.define(:row_id, :id, :kind, :payload, :seed) do
      def key = "#{row_id}/#{id}"

      # A hint's line (the probes append it), and its row entry `{id, text}`.
      def hint_texts = kind == "lead_hints" ? [payload] : []

      def hint = { "id" => id, "text" => payload }

      def entries = kind == "tool_descriptions" ? [payload] : []

      # A slug for a file name or a test method: the row's id and the candidate's.
      def slug = key.tr("/", "-")
    end

    module_function

    # The SDK's pack — the gem's rows, no local rows — loaded once.
    def pack = @pack ||= Pack.load

    # THE LOCAL ROW FOR A PRESET WORD (or words joined by `+`): the id
    # `bench-<word>`, the words alone, no text, `models: []`.
    def bench_row_id(style) = "#{BENCH_ROW_PREFIX}#{style.to_s.tr("+", "-")}"

    def word_row(id, words)
      { "format" => Pack::FORMAT, "row" => id, "models" => [], "tool_style" => Array(words),
        "tool_descriptions" => [], "summarizer_prompt" => nil, "lead_hints" => [], "compose" => "on" }
    end

    # A ROW AS ITS FILE SPELLS IT — the document a `Row` was read from,
    # written back (a local row of a gem row's id replaces it).
    def document(row)
      { "format" => Pack::FORMAT, "row" => row.id, "models" => row.models.to_a,
        "tool_style" => row.tool_style.to_a, "tool_descriptions" => deep_unfreeze(row.tool_descriptions),
        "summarizer_prompt" => row.summarizer_prompt, "lead_hints" => deep_unfreeze(row.lead_hints),
        "compose" => row.compose }
    end

    # The style words a probe declares, checked against the tables: presets
    # joined by `+`; a stranger is an error, never a silent baseline.
    def words(style)
      words = style.to_s.split("+")
      unknown = words - pack.presets.words
      raise ArgumentError, "no style #{style.inspect}: #{unknown.inspect} is not one of #{pack.presets.words.join(", ")}" if
        words.empty? || !unknown.empty?

      words
    end

    # ── a style's row and the kernel's entries under it ────────────────────

    # THE HARNESS-BUILT ROW for a style id: the pack's default row under the style's words, `source:
    # "local"`, `models: []`, pinned — never a gem row; a `tool_descriptions` candidate's entries
    # (the RUN step's text probes) ride it as the row's own description variant.
    def style_row(id, words, tool_descriptions: [])
      pack.default.with(id: id.to_s, source: "local", tool_style: Array(words), tool_descriptions: tool_descriptions.freeze)
    end

    # The kernel's templates by canonical, for the presets' recuts.
    def kernel_templates = Nexus::ToolRegistry::LIVE.values.to_h { |tool| [tool.canonical, tool.template] }

    # Every live kernel tool's function definition — what a rho turn declares.
    def kernel_definitions = Nexus::ToolRegistry::LIVE.values.map(&:function_definition)

    # THE KERNEL'S ENTRIES UNDER A ROW, rendered by the kernel — the stored
    # form a profile holds: `definitions` (every live tool by default; the
    # compose bench hands in its plain `task`/`ask` pair) through the pack's
    # `apply` (a plain name kept only with `nexus` or while no active preset
    # supersedes it, each preset's aliases added, a recut rendered against
    # the kernel's own template), refused exactly as the kernel refuses a
    # set, then `ToolDeclarations.render`.
    def kernel_entries_under(row, definitions = kernel_definitions)
      entries = pack.apply(definitions, row, templates: kernel_templates)
      refusal = Nexus::ToolDeclarations.refusal(entries)
      raise ArgumentError, "the kernel refuses the #{row.tool_style.join("+")} set: #{refusal}" if refusal

      Nexus::ToolDeclarations.render(entries)
    end

    # ── the candidates ─────────────────────────────────────────────────────

    # Every candidate of every file, keyed `<row>/<id>`.
    def candidates
      @candidates ||= Dir[File.join(CANDIDATES_DIR, "*.yml")].sort.flat_map do |path|
        document = YAML.safe_load(File.read(path, encoding: Encoding::UTF_8), permitted_classes: [], aliases: false, filename: path)
        row_id = document.fetch("row")
        document.fetch("candidates").map do |spec|
          kind = spec.fetch("kind")
          Candidate.new(row_id: row_id, id: spec.fetch("id"), kind: kind, payload: spec.fetch(KINDS.fetch(kind)), seed: spec.fetch("seed"))
        end
      end.to_h { |candidate| [candidate.key, candidate] }.freeze
    end

    # One candidate by `<row>/<id>`; an unknown one is refused naming what exists — none, while no
    # file is on the directory.
    def find(key)
      candidates.fetch(key.to_s.strip) do
        raise ArgumentError, "no candidate #{key.inspect}: the candidates are #{candidates.keys.join(", ").presence || "none"} (e2e/evals/candidates/)"
      end
    end

    # A comma list of keys — the probes' `E2E_BENCH_CANDIDATES` — each
    # loaded, each of a kind the probe can read (a `tool_style` word or a
    # summarizer text is the evals runner's, never a probe's).
    def list(raw, kinds:)
      raw.to_s.split(",").map(&:strip).reject(&:empty?).map do |key|
        candidate = find(key)
        unless kinds.include?(candidate.kind)
          raise ArgumentError, "candidate #{key} is a #{candidate.kind} candidate; this probe reads #{kinds.join(", ")}"
        end

        candidate
      end
    end

    # THE GEM ROW PLUS THE CANDIDATE, as the local row the evals write of
    # the gem row's own id (`adaptations: auto` then resolves it): a
    # `tool_style` value REPLACES the row's words (12a/12b ran `workflow`
    # alone), a hint or an entry is appended, a summarizer recut is ONE
    # anchored edit of the kernel's INSTRUCTIONS (a moved anchor is loud).
    def apply(candidate)
      row = pack.row(candidate.row_id) || raise(ArgumentError, "candidate #{candidate.key}: #{candidate.row_id.inspect} is not a gem row")
      base = document(row)
      case candidate.kind
      when "tool_style" then base.merge("tool_style" => Array(candidate.payload))
      when "lead_hints" then base.merge("lead_hints" => base.fetch("lead_hints") + [candidate.hint])
      when "tool_descriptions" then base.merge("tool_descriptions" => base.fetch("tool_descriptions") + [candidate.payload])
      when "summarizer_prompt" then base.merge("summarizer_prompt" => recut_summarizer(candidate))
      else raise ArgumentError, "candidate #{candidate.key}: unknown kind #{candidate.kind.inspect}"
      end
    end

    def recut_summarizer(candidate)
      edit = candidate.payload
      text = Conversations::Compaction::Summarizer::INSTRUCTIONS
      raise ArgumentError, "candidate #{candidate.key}: the anchor moved; re-cut the candidate: #{edit.fetch("anchor").inspect}" unless
        text.include?(edit.fetch("anchor"))

      text.sub(edit.fetch("anchor")) { edit.fetch("replacement") }
    end

    # ── the probes' cells ──────────────────────────────────────────────────

    # The gem row a PROBE's model resolves to: the probes spell the
    # catalog's refs (`openrouter/z-ai/glm-5.3`), so the pack resolves each
    # the way the daemon does — the lane segment stripped, the row whose
    # entry covers its reference whatever lane serves it.
    def probe_row(model_ref) = pack.for(model_ref)

    # A model's cells under a candidate list: the candidates whose row
    # covers it, else the one baseline cell (`nil`). Refused before a call
    # is paid: a candidate covering no selected model (a paid run that
    # measures nothing), and one its row pairs with a model on the bench's
    # floor tier — a roster floor or a named-only one, read through the
    # bench's one `tier_of` — the floor is read-only, never tuned for, in
    # the evals door's words (`Evals::Bench`, which every caller loads). A
    # floor's baseline cell stands.
    def cells(candidates, models)
      bench = Evals::Bench.read
      floor = models.select { |model| bench.tier_of(model) == Evals::Bench::FLOOR }
      candidates.each do |candidate|
        raise ArgumentError, "candidate #{candidate.key} covers none of #{models.join(", ")} (row #{candidate.row_id})" unless
          models.any? { |model| probe_row(model).id == candidate.row_id }

        floor.each do |model|
          raise ArgumentError, "#{candidate.key}: #{model} is on the #{Evals::Bench::FLOOR} tier (read-only, never tuned for)" if
            probe_row(model).id == candidate.row_id
        end
      end
      models.to_h do |model|
        mine = candidates.select { |candidate| probe_row(model).id == candidate.row_id }
        [model, mine.empty? ? [nil] : mine]
      end
    end

    # An unfrozen deep copy of a row's text (the pack deep-freezes its
    # rows); the text is plain YAML data, so the JSON round trip is exact.
    def deep_unfreeze(value) = JSON.parse(JSON.generate(value))
  end
end
