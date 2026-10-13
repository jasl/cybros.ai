$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "json"
require "minitest/autorun"
require "support/attachment_line_bench"
require "support/manual_anthropic"
require "support/manual_openrouter"
require "support/output_caps"

# WHAT A TEXT-ONLY MODEL DOES WITH THE INDEX LINE. The line is the bytes a row that cannot take a
# picture reads in its position; the summary's pointer shares its grammar. Each selected spelling of
# `E2E::AttachmentLineBench::ROWS` — the `ruled` row by default, the record rows under
# `E2E_BENCH_ROWS` — rides one user message — the person's question, then the line — with no tools
# and no instructions, `E2E_BENCH_RUNS` times on each model, and ONE property is scored on the
# reply: the model SAYS it cannot see the picture and asks for a description, never invents its
# content. The rows are broker ids read through a raw client: the catalog's word plays no part, the
# picture never rides.
#
# A MEASUREMENT: the assertions are about the harness; the readout
# (`E2E_BENCH_DIR`, `artifacts/bench` by default: `attachment_line.json`
# and one `results-attachment-line-<model>.md` per model, merged across
# runs) carries the verdict a human reads. The spelling was pinned into
# nexus and the mock lane's fixture AFTER the readout (design r3), never
# before; the default run now confirms the ruled row.
#
# E2E_LIVE=1 RAILS_ENV=development rake live_attachment_line E2E_BENCH_ROWS=index,codex
# E2E_BENCH_MODELS=z-ai/glm-5.3 E2E_BENCH_RUNS=3 … # the record rows, a subset
#
# Paid, local, opt-in.
class AttachmentLineProbeTest < Minitest::Test
  Bench = E2E::AttachmentLineBench

  def test_the_index_line_bench
    E2E::ManualOpenRouter.validate!
    rows = Bench.rows
    refute_empty rows, "E2E_BENCH_ROWS=#{ENV["E2E_BENCH_ROWS"].inspect} names no row of #{Bench::ROWS.map(&:id).inspect}"
    samples = Bench::MODELS.flat_map do |model|
      client = E2E::ManualOpenRouter.client(model)
      rows.flat_map do |row|
        (1..Bench::RUNS).map do |run|
          sample(client, model, row, run).tap { |cell| puts progress(cell) }
        end
      end
    end
    Bench.write(samples)
    puts "\nreadout: #{Bench.bench_dir}"

    assert_equal Bench::MODELS.length * rows.length * Bench::RUNS, samples.length
    assert samples.all? { |cell| cell.key?("pass") }, "a sample was not scored"
  end

  private

    # The cap is the model's (`E2E::OutputCaps`) and rides the cell with
    # the provider's finish, so an empty reply under an exhausted cap is
    # read as the cap and never as a choice.
    def sample(client, model, row, run)
      cap = E2E::OutputCaps.for(model)
      base = { "row" => row.id, "model" => model, "run" => run, "max_output_tokens" => cap }
      result = client.responses.create(
        model: model, input: [{ "role" => "user", "content" => row.message }], max_output_tokens: cap
      )
      text = result.output_text.to_s.strip
      base.merge(Bench.score(text)).merge("text" => text[0, 900]).merge({ "finish" => result.finish_reason&.to_s }.compact)
    rescue StandardError => error
      base.merge("pass" => false, "admits" => false, "asks" => false, "invents" => false,
        "error" => "#{error.class}: #{error.message[0, 200]}")
    end

    def progress(cell)
      format("%-28s %-6s #%-2d %s  admits=%s asks=%s invents=%s%s", cell["model"], cell["row"], cell["run"],
        cell["pass"] ? "PASS" : "FAIL", cell["admits"], cell["asks"], cell["invents"],
        cell["error"] ? "  #{cell["error"]}" : "")
    end
end
