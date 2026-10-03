$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "fileutils"
require "json"
require "mini_racer"
require "minitest/autorun"
require "support/manual_anthropic"
require_relative "../../nexus/lib/nexus/tool_registry"
require_relative "../../nexus/lib/nexus/compose"
require_relative "../../nexus/lib/nexus/compose/grammar"
require_relative "../../nexus/lib/nexus/compose/evaluator"
require_relative "../../nexus/lib/nexus/model_tool_calls"

# THE ONE THING THE ARCHITECTURE CANNOT ANSWER: does a model REACH for
# `compose` when nobody told it to, and is the script it writes one our
# evaluator accepts? Every other compose test supplies the script. This
# one asks a real model for it, with the shipped declaration verbatim
# and objectives worded so they never name the shape they want.
#
# It captures what the model wrote under local artifacts for inspection.
# Durable regression inputs are authored separately from the provider output.
#
# Paid, local, opt-in: E2E_LIVE=1 RAILS_ENV=development.
class ComposeProbeTest < Minitest::Test
  CAPTURES = File.expand_path("../artifacts/compose-probe", __dir__)

  READ_TOOL = {
    type: "function",
    function: {
      name: "read_file",
      description: "Read one file and return its contents.",
      parameters: {
        type: "object",
        properties: { path: { type: "string" } },
        required: ["path"],
      },
    },
  }.freeze

  PROBE_TOOL = {
    type: "function",
    function: {
      name: "probe_host",
      description: "Check whether one host responds. Returns its status.",
      parameters: {
        type: "object",
        properties: { host: { type: "string" } },
        required: ["host"],
      },
    },
  }.freeze

  # WORDED IMPLICITLY, on purpose. Not one of these says "in parallel",
  # "race", "first one wins", or "at the same time" — telling the model
  # the shape would measure transcription instead of recognition. The
  # last is a CONTROL: it wants exactly one call, and composing for it
  # is over-reach, the cost-without-win failure this arm has to avoid.
  OBJECTIVES = [
    { slug: "config-sweep", wording: :implicit,
      text: "Five config files are in this repo: app.yml, db.yml, cache.yml, " \
            "queue.yml and mail.yml. Tell me which of them set debug to true." },
    { slug: "review-angles", wording: :implicit,
      text: "Review the patch in patch.diff for security problems, for " \
            "performance problems, and for style, then give me one verdict " \
            "that weighs all three." },
    { slug: "host-sweep", wording: :implicit,
      text: "Check whether each of these hosts responds and summarize the ones " \
            "that do not: alpha, bravo, charlie, delta, echo, foxtrot, golf, " \
            "hotel, india, juliet, kilo, lima." },
    # THE CEILING CHECK. The shape is handed over, so this measures
    # transcription rather than recognition — which is exactly what makes
    # it the right gate. A surface a model cannot use even when told to
    # use it is dead; a surface it uses on request but not on its own has
    # a DISCOVERY problem, which is a different repair entirely.
    # Each branch reads the patch ITSELF. The first run of this probe
    # asked for the graph while the model still had to read the file to
    # write it, and the model — correctly — read the file first. That
    # measured my objective, not the surface.
    { slug: "review-angles-explicit", wording: :explicit,
      text: "Build a compose graph, right now, for reviewing patch.diff: " \
            "three model branches in parallel, one for security, one for " \
            "performance, one for style, each told to read patch.diff " \
            "itself, then a fourth step that reads all three and gives one " \
            "verdict. Do not read anything first; just build the graph." },
    { slug: "host-sweep-explicit", wording: :explicit,
      text: "Check whether each of these hosts responds and summarize the ones " \
            "that do not: alpha, bravo, charlie, delta, echo, foxtrot, golf, " \
            "hotel, india, juliet, kilo, lima. Build the whole fan in one " \
            "compose script by mapping over the host list in params." },
    # THE OVER-REACH CONTROL: one call's worth of work, and composing for
    # it is the cost-without-win failure this arm has to avoid.
    { slug: "single-read", wording: :control,
      text: "What does app.yml set the log level to?" },
  ].freeze

  SYSTEM = <<~TEXT.strip
    You are an engineering agent working in a repository. Answer the user's
    request by calling the tools available to you. Do not describe what you
    would do; make the calls.
  TEXT

  def test_a_real_model_reaches_for_compose_and_writes_a_script_we_accept
    E2E::ManualAnthropic.validate!
    FileUtils.mkdir_p(CAPTURES)
    model = E2E::ManualAnthropic.model
    client = E2E::ManualAnthropic.client

    results = OBJECTIVES.map { |objective| probe(client, model, objective) }
    implicit = results.select { |r| r[:wording] == :implicit }
    composed = results.select { |r| r[:script] }
    puts JSON.pretty_generate(
      model: model,
      reached_unprompted: "#{implicit.count { |r| r[:script] }}/#{implicit.length}",
      valid_first_submission: "#{composed.count { |r| r[:attempts] == 1 }}/#{composed.length}",
      results: results.map { |r| r.except(:script) }
    )

    write_manifest!(model, results)
    assert_reach(results)
    assert_repair(composed)
  end

  private

    # The vendored protocols read symbol keys; nexus stores strings. No
    # ActiveSupport here, so the conversion is four lines and explicit.
    def symbolize(value)
      case value
      when Hash then value.to_h { |key, inner| [key.to_sym, symbolize(inner)] }
      when Array then value.map { |inner| symbolize(inner) }
      else value
      end
    end

    # One turn, and — if the script does not build — ONE REPAIR TURN
    # playing the kernel's own refusal back as the tool result the model
    # would really receive. First-submission validity is a number to
    # report; whether the refusal TEACHES is the property that matters,
    # because a model writing a program will get it wrong and the
    # envelope is the whole feedback channel.
    def probe(client, model, objective)
      history = [{ "role" => "user", "content" => objective[:text] }]
      attempt = ask(client, model, history)
      return finish(objective, attempt, 0) if attempt[:script].nil?

      built = evaluate(attempt)
      return finish(objective, attempt, 1) if built.built?

      history += [call_item(attempt), result_item(attempt, refusal_text(built))]
      finish(objective, ask(client, model, history), 2, first: attempt)
    end

    def ask(client, model, input)
      result = client.responses.create(
        model: model, instructions: SYSTEM, input: input,
        tools: [symbolize(Nexus::Compose::DEFINITION), READ_TOOL, PROBE_TOOL],
        max_output_tokens: 4096
      )
      calls = Nexus::ModelToolCalls.normalize(result.tool_calls)
      composed = calls.find { |call| call["name"] == Nexus::Compose::TOOL_NAME }
      arguments = composed && parse(composed["arguments"])

      { call: composed, called: calls.map { |call| call["name"] }.tally,
        text: result.output_text.to_s.strip[0, 300],
        script: arguments && arguments["script"], params: arguments && arguments["params"] }
    end

    def parse(raw)
      JSON.parse(raw.to_s)
    rescue JSON::ParserError
      nil
    end

    def finish(objective, attempt, attempts, first: nil)
      attempt.except(:call).merge(
        slug: objective[:slug], wording: objective[:wording],
        attempts: attempts, first_refusal: first && refusal_text(evaluate(first))
      ).compact
    end

    def evaluate(attempt)
      Nexus::Compose::Evaluator.call(
        script: attempt[:script], params: attempt[:params] || {}
      )
    end

    def refusal_text(built)
      "#{built.refusal}: #{built.detail}"
    end

    # The exact wire shape the kernel would send back: the call the model
    # made, then its result, marked as an error the way the composer
    # marks one.
    def call_item(attempt)
      { "type" => "function_call", "call_id" => attempt[:call]["id"],
        "name" => Nexus::Compose::TOOL_NAME, "arguments" => attempt[:call]["arguments"] }
    end

    def result_item(attempt, text)
      { "type" => "function_call_output", "call_id" => attempt[:call]["id"],
        "name" => Nexus::Compose::TOOL_NAME,
        "output" => "<tool_use_error>#{text}</tool_use_error>" }
    end

    # WHAT THIS ASSERTS, and what it deliberately does not.
    #
    # The CEILING is a gate: a model told in plain words to use compose
    # must produce a script we accept, or the surface is dead and no
    # prose fixes it.
    #
    # The IMPLICIT rate is REPORTED, never asserted. A handful of
    # single-sample objectives cannot carry a pass/fail verdict, and
    # wiring one in would turn a finding for the owner into a red build
    # that says nothing about the code under it. The number goes in the
    # manifest, where a human reads it.
    def assert_reach(results)
      ceiling = results.select { |r| r[:wording] == :explicit }
      missed = ceiling.reject { |r| r[:script] }.map { |r| r[:slug] }
      assert_empty missed,
        "told outright to compose and did not: the surface is unusable, " \
        "not merely undiscovered"

      overreach = results.select { |r| r[:wording] == :control }.count { |r| r[:script] }
      assert_equal 0, overreach,
        "composed for work that is one call - the cost-without-win failure"
    end

    # THE REFUSAL MUST TEACH. Getting a program wrong is normal; a
    # surface whose error envelope does not converge in one turn is not,
    # because the shipped repeat brake would turn that into a human
    # interrupt. Scored through the SHIPPED evaluator and the SHIPPED
    # builder library, never a lookalike.
    def assert_repair(composed)
      composed.each do |result|
        built = evaluate(result)
        assert_predicate built, :built?,
          "#{result[:slug]}: did not build after #{result[:attempts]} attempts - " \
          "#{refusal_text(built)}"
        refute_empty built.steps, "#{result[:slug]} built nothing"

        built.steps.each { |step| assert_step_shape(result[:slug], step) }
      end
    end

    # The step-shaped grammar: one verb per step, only compose's options
    # on it, a group's members steps or nested sequences of steps.
    def assert_step_shape(slug, step)
      verb = step.keys.find { |key| Nexus::Compose::Grammar.verbs.include?(key) }
      refute_nil verb, "#{slug}: a step with no verb: #{step.keys.inspect}"
      if verb == "parallel"
        assert_empty step.keys - ["parallel"] - Nexus::Compose::Grammar.compose_options("parallel"),
          "#{slug}: unknown group options"
        step.fetch("parallel").each do |member|
          Array(member.is_a?(Array) ? member : [member]).each { |nested| assert_step_shape(slug, nested) }
        end
      else
        assert_empty step.fetch(verb).keys - Nexus::Compose::Grammar.compose_options(verb),
          "#{slug}: unknown #{verb} fields"
      end
    end

    # Captured as SOURCE, one file per objective, because a script is
    # something a human reads in review — and replayed by the nexus suite
    # through the real compiler, where the constants live.
    def write_manifest!(model, results)
      manifest = results.map do |result|
        path = File.join(CAPTURES, "#{result[:slug]}.js")
        result[:script] ? File.write(path, result[:script]) : FileUtils.rm_f(path)
        { "objective" => result[:slug], "model" => model,
          "wording" => result[:wording].to_s,
          "composed" => !result[:script].nil?, "attempts" => result[:attempts],
          "called" => result[:called], "first_refusal" => result[:first_refusal],
          "params" => result[:params] }.compact
      end
      File.write(File.join(CAPTURES, "manifest.json"),
        "#{JSON.pretty_generate(manifest)}\n")
    end
end
