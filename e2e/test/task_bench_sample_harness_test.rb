$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "json"
require "minitest/autorun"
require "minitest/mock"
require "support/bench_records"
require "support/task_bench"

# THE TWO-STEP DRAW, OVER THE REAL WIRES (a stepped transport, no socket): a first message whose
# every call is a READ is answered from the objective's fixture — the calls and their answers
# appended as the Responses items a repair round carries, the kernel's cache markers placed again
# over the grown input — and the next message is asked; the first message that is not all reads
# is the one scored. Three read-only messages are a SCOUT (no fourth call). An objective whose
# right answer IS reads is scored on its first message. Every call keeps its own facts under
# `messages[]` and beats a heartbeat of the blind fields alone; a raise in a later message's
# scoring is the draw's error and reads as a harness fault.
class TaskBenchSampleHarnessTest < Minitest::Test
  Objectives = E2E::TaskBench::Objectives
  Sample = E2E::TaskBench::Sample

  KEYS = { "OPENROUTER_API_KEY" => "broker-placeholder", "ANTHROPIC_API_KEY" => "anthropic-placeholder" }.freeze
  JSON_HEADERS = { "content-type" => "application/json" }.freeze
  DEFAULT_ROUTE = E2E::ProviderLanes::Route.new(ref: "openrouter/acme/test-model",
    lane: E2E::ProviderLanes.lane("openrouter"), model: "acme/test-model")

  FIXTURE = {
    "lib/alpha.rb" => "class Alpha\n  def run\n    :alpha\n  end\nend\n",
    "lib/bravo.rb" => "class Bravo\n  def call\n    :bravo\n  end\nend\n",
  }.freeze

  # A DOOR OBJECTIVE'S SHAPE, synthetic: a fixture the reads are answered from, scored on the
  # delegating message (two `task` calls).
  HAND_OUT = Objectives::Objective.new(
    id: "X1", slug: "hand-out-two-reviews", fixture: FIXTURE,
    text: "Have a fresh agent review each of lib/alpha.rb and lib/bravo.rb, and tell me what they find.",
    scorer: ->(calls, _declared) { { "pass" => calls.count(&:task?) == 2, "tasks" => calls.count(&:task?) } }
  )

  # Each step answers one request: a response the transport hands the gem, or a raise as the
  # socket raises it. Every request is kept.
  class StepAdapter < SimpleInference::HTTPAdapter
    attr_reader :requests

    def initialize(*steps)
      super()
      @steps = steps
      @requests = []
    end

    def call(request)
      @requests << request
      @steps.shift.call(request)
    end
  end

  def ok(body) = ->(_request) { { status: 200, headers: JSON_HEADERS, body: JSON.generate(body) } }

  def chat(*calls, finish: "tool_calls", usage: { "prompt_tokens" => 4_000, "completion_tokens" => 100 })
    tool_calls = calls.each_with_index.map do |(name, arguments), i|
      { "id" => "call_#{i + 1}", "type" => "function", "function" => { "name" => name, "arguments" => JSON.generate(arguments) } }
    end
    ok({ "id" => "gen-1", "object" => "chat.completion", "usage" => usage,
         "choices" => [{ "index" => 0, "finish_reason" => finish,
                         "message" => { "role" => "assistant", "content" => nil, "tool_calls" => tool_calls.presence }.compact }] })
  end

  def opus(*calls)
    content = calls.each_with_index.map { |(name, input), i| { "type" => "tool_use", "id" => "toolu_#{i + 1}", "name" => name, "input" => input } }
    ok({ "id" => "msg_1", "type" => "message", "role" => "assistant", "model" => "claude-opus-5-5", "content" => content,
         "stop_reason" => "tool_use", "usage" => { "input_tokens" => 20, "cache_read_input_tokens" => 9_000, "output_tokens" => 80 } })
  end

  def draw(objective, *steps, ref: nil, index: 1, heartbeat: nil, pause: ->(_seconds) { })
    route = ref ? E2E::ProviderLanes.route(ref) : DEFAULT_ROUTE
    wire = StepAdapter.new(*steps)
    client = E2E::ManualClient.for(route, env: KEYS, adapter: wire)
    beats = heartbeat || ->(_facts) { }
    record = Sample.call(client: client, route: route, style: "nexus", candidate: nil, objective: objective, index: index,
      declared: E2E::TaskBench::DeclaredSet.function_definitions, heartbeat: beats, pause: pause)
    [record, wire.requests.map { |request| JSON.parse(request.fetch(:body)) }]
  end

  def test_a_read_only_first_message_is_answered_from_the_fixture_and_the_next_is_scored
    record, bodies = draw(HAND_OUT,
      chat(["read", { path: "lib/alpha.rb" }], ["bash", { command: "ls lib" }]),
      chat(["task", { prompt: "Review lib/alpha.rb." }], ["task", { prompt: "Review lib/bravo.rb." }]))

    assert_equal 2, bodies.length
    ask, called, *answers = bodies.last.fetch("messages").drop_while { |message| message["role"] == "system" }
    assert_equal ["user", HAND_OUT.text], ask.values_at("role", "content")
    assert_equal ["assistant", %w[read bash]], [called["role"], called.fetch("tool_calls").map { |c| c.dig("function", "name") }],
      "the read-only message folds back as ONE assistant message carrying both calls"
    assert_equal [%w[tool call_1], %w[tool call_2]], answers.map { |answer| answer.values_at("role", "tool_call_id") }
    assert_includes answers.first.fetch("content"), "def run", "the read is rho's own `read` over the fixture's bytes"
    assert_equal "alpha.rb\nbravo.rb", answers.last.fetch("content").strip, "the admitted bash ran inside the copy"

    assert record["pass"], record.inspect
    assert_equal [2, false, true], record.values_at("scored_message", "scout", "scout_then_door")
    assert_equal({ "task" => 2 }, record["called"], "the scored message's calls")
    assert_equal [[1, { "read" => 1, "bash" => 1 }, true], [2, { "task" => 2 }, false]],
      record.fetch("messages").map { |message| message.values_at("index", "called", "read_class") }
  end

  # THE TAIL MARKER ROLLS: each message of an Opus draw carries the kernel's two markers — the
  # system block's and the tail on the grown input's last entry — so message 2 reads the prefix
  # message 1 wrote; an answer the tool gave as an error rides with the kernel's marker and the
  # wire's own `is_error`.
  def test_each_message_of_an_opus_draw_carries_the_two_markers_over_the_grown_input
    record, bodies = draw(HAND_OUT, opus(["read", { "path" => "lib/charlie.rb" }]),
      opus(["task", { "prompt" => "Review lib/alpha.rb." }], ["task", { "prompt" => "Review lib/bravo.rb." }]),
      ref: "anthropic/claude-opus-5-5")

    assert record["pass"], record.inspect
    bodies.each_with_index do |body, i|
      assert_equal({ "type" => "ephemeral" }, body.fetch("system").last["cache_control"], "call #{i + 1}: the stable marker")
      assert_equal({ "type" => "ephemeral" }, body.fetch("messages").last.fetch("content").last["cache_control"], "call #{i + 1}: the tail")
      assert_equal 2, JSON.generate(body).scan("\"cache_control\"").size, "call #{i + 1}: two breakpoints, no more"
    end
    refute_includes JSON.generate(bodies.last.fetch("messages").first), "cache_control", "the ask the tail left is unmarked"
    result = bodies.last.fetch("messages").last.fetch("content").last
    assert_equal ["tool_result", true], result.values_at("type", "is_error")
    assert_match(%r{\A<tool_use_error>File not found: .*lib/charlie\.rb</tool_use_error>\z}, result.fetch("content"))
  end

  # A scout chose no door and says so; a lost draw was never read, so it names none.
  def test_three_read_only_messages_are_a_scout_and_no_fourth_call_is_made
    record, bodies = draw(HAND_OUT, chat(["ls", {}]), chat(["read", { path: "lib/alpha.rb" }]), chat(["grep", { pattern: "def" }]))

    assert_equal 3, bodies.length
    assert_equal [true, false, nil, false], record.values_at("scout", "scout_then_door", "scored_message", "pass")
    assert_equal [true, true, true], record.fetch("messages").map { |message| message["read_class"] }
    refute record.key?("tasks"), "no message was scored"
    assert_equal "scout", record["door_kind"]

    denied = ->(_request) { { status: 400, headers: JSON_HEADERS, body: JSON.generate({ "error" => { "message" => "bad request" } }) } }
    lost, = draw(HAND_OUT, chat(["ls", {}]), denied)
    assert lost["error"], lost.inspect
    refute lost.key?("door_kind"), "a lost draw names no door"
  end

  def test_a_first_message_that_is_not_all_reads_is_scored_as_it_stands
    record, bodies = draw(HAND_OUT, chat(["read", { path: "lib/alpha.rb" }], ["task", { prompt: "Review lib/bravo.rb." }]))
    assert_equal 1, bodies.length
    assert_equal [1, false, false, false, 1], record.values_at("scored_message", "scout", "scout_then_door", "pass", "tasks")

    plain, bodies = draw(HAND_OUT, chat(finish: "stop"))
    assert_equal 1, bodies.length, "a message with no call is a plain answer, never a read"
    assert_equal [1, false, "none"], plain.values_at("scored_message", "scout", "door_kind")

    control, = draw(Objectives.find("T5"), chat(*Objectives::CONFIGS.map { |path| ["grep", { pattern: "debug", path: path }] }))
    assert_equal [true, "plain", %w[grep]], control.values_at("pass", "door_kind", "beside"), "a control's record carries its door"
  end

  # A read of the root spelled empty (`grep`'s `path: ""`) is a read, as rho reads it.
  def test_a_read_of_the_root_spelled_empty_is_answered_and_the_next_message_scored
    record, bodies = draw(HAND_OUT, chat(["grep", { pattern: "def run", path: "" }]),
      chat(["task", { prompt: "a" }], ["task", { prompt: "b" }]))

    assert_equal 2, bodies.length
    assert_includes bodies.last.fetch("messages").last.fetch("content"), "alpha.rb:2:"
    assert_equal [true, 2], record.values_at("pass", "scored_message")
  end

  # A TWO-STEP OBJECTIVE CARRIES EVERY FILE ITS TEXT NAMES, so a scout's read of one is answered
  # and never contradicts the premise the draw is scored on (an objective scored on its first
  # message answers no read). TT4's file is the content its text states; the reviewed diff patches
  # a file its fixture holds.
  FILE_NAMED = %r{[\w/-]*\w\.(?:rb|diff|yml|md)\b}

  def test_a_two_step_objective_carries_every_file_its_text_names
    named = Objectives::ALL.reject(&:scored_first).to_h { |objective| [objective.id, objective.text.scan(FILE_NAMED).uniq] }
      .reject { |_id, files| files.empty? }
    assert_equal %w[SP1 SP2 SP3A SP3B TT2 TT4 D1P D2P D4P D3P], named.keys
    named.each { |id, files| assert_empty files - Objectives.find(id).fixture.keys, "#{id} names a file its fixture lacks" }
    assert_includes Objectives::TT4.text, "```ruby\n#{Objectives::TT4.fixture.fetch(Objectives::TT4_FILE)}```"
    %w[SP3A SP3B TT2].each do |id|
      fixture = Objectives.find(id).fixture
      patched = fixture.fetch("patch.diff")[%r{^\+\+\+ b/(\S+)$}, 1]
      assert fixture.key?(patched), "#{id}'s diff patches #{patched}, a file its fixture holds"
    end

    record, bodies = draw(Objectives::TT4, chat(["read", { path: Objectives::TT4_FILE }]),
      chat(["edit", { path: Objectives::TT4_FILE, edits: [{ oldText: "TIMEOUT = 30", newText: "TIMEOUT = 60" },
                                                          { oldText: "RETRIES = 3", newText: "RETRIES = 5" }] }]))
    assert_includes bodies.last.fetch("messages").last.fetch("content"), "LOG_LEVEL = :info", "the stated file is read back"
    assert_equal [true, 2], record.values_at("pass", "scored_message")
  end

  # G0's greps are its answer, and so are the control's and TT3's `find`: answering them would
  # score the model's summary instead of its calls.
  def test_an_objective_whose_answer_is_reads_is_scored_on_its_first_message
    assert_equal %w[G0 T5 TT3], Objectives::ALL.select(&:scored_first).map(&:id)
    reads = %w[lib/alpha.rb lib/bravo.rb lib/charlie.rb].map { |path| ["read", { path: path }] }
    record, bodies = draw(Objectives.find("G0"), chat(*reads))
    assert_equal 1, bodies.length
    assert_equal [true, 1, false], record.values_at("pass", "scored_message", "scout_then_door")
  end

  # THE DRAW'S SPEND IS ON TOP: the record's `usage` is every message's summed key by key — the
  # broker's `cost` too — so a reader that prices `record["usage"]` prices the whole draw, as it
  # prices a compose record; its `retries` are every message's, in order. A one-message draw's top
  # level is its one message's, as it always was.
  def test_the_records_usage_sums_its_messages_and_its_retries_are_every_messages
    reset = ->(_request) { raise Errno::ECONNRESET }
    record, bodies = draw(HAND_OUT,
      reset, chat(["ls", {}], usage: { "prompt_tokens" => 4_000, "completion_tokens" => 50, "cost" => 0.25 }),
      reset, chat(["task", { prompt: "a" }], ["task", { prompt: "b" }],
        usage: { "prompt_tokens" => 4_300, "completion_tokens" => 90, "cost" => 0.5 }))

    assert_equal 4, bodies.length
    first, second = record.fetch("messages")
    assert_equal [0.25, 0.5], [first, second].map { |message| message.dig("usage", "cost") }
    assert_equal({ "input_tokens" => 8_300, "output_tokens" => 140, "cost" => 0.75 }, record["usage"])
    assert_equal [1, 1], [first, second].map { |message| message.fetch("retries").length }
    assert_equal first["retries"] + second["retries"], record["retries"]

    single, = draw(HAND_OUT, chat(["task", { prompt: "a" }], ["task", { prompt: "b" }]))
    assert_equal single.fetch("messages").first.slice("finish", "usage"), single.slice("finish", "usage")
    refute single.key?("retries"), "no call retried"
  end

  # A CALL'S SETTLEMENT FACTS ARE NOT COUNTS: the broker's `is_byok` (and the served tier) ride the
  # draw's spend when every message says the same, so the draw prices as its calls do; messages
  # that disagree leave the fact out rather than keep one call's.
  def test_the_draws_spend_keeps_a_settlement_fact_its_messages_agree_on
    broker = ->(cost, byok) { { "prompt_tokens" => 4_000, "completion_tokens" => 50, "cost" => cost, "is_byok" => byok } }
    agreed, = draw(HAND_OUT, chat(["ls", {}], usage: broker.call(0.25, false)), chat(["task", { prompt: "a" }], usage: broker.call(0.5, false)))
    assert_nil agreed["error"], agreed.inspect
    assert_equal({ "input_tokens" => 8_000, "output_tokens" => 100, "cost" => 0.75, "is_byok" => false }, agreed["usage"])

    mixed, = draw(HAND_OUT, chat(["ls", {}], usage: broker.call(0.25, false)), chat(["task", { prompt: "a" }], usage: broker.call(0.5, true)))
    assert_nil mixed["error"], mixed.inspect
    assert_equal({ "input_tokens" => 8_000, "output_tokens" => 100, "cost" => 0.75 }, mixed["usage"])
  end

  # EVERY CALL KEEPS ITS OWN FACTS: the finish, the spend and whatever the retry recorded
  # (`Called#facts`, passed through whole); the draw's top level keeps its LAST message's finish
  # and the whole draw's spend. Each call beats one heartbeat of the blind fields alone: nothing
  # that reads the outcome.
  def test_every_call_keeps_its_facts_and_beats_a_blind_heartbeat
    beats = []
    pauses = []
    reset = ->(_request) { raise Errno::ECONNRESET }
    record, bodies = draw(HAND_OUT,
      chat(["ls", {}], usage: { "prompt_tokens" => 4_000, "completion_tokens" => 50 }), reset,
      chat(["task", { prompt: "a" }], ["task", { prompt: "b" }], usage: { "prompt_tokens" => 4_300, "completion_tokens" => 90 }),
      index: 4, heartbeat: ->(facts) { beats << facts }, pause: ->(seconds) { pauses << seconds })

    assert_equal 3, bodies.length, "the reset call and the one that answered"
    assert_equal [10], pauses
    first, second = record.fetch("messages")
    assert_equal ["tool_calls", { "input_tokens" => 4_000, "output_tokens" => 50 }], first.values_at("finish", "usage")
    refute first.key?("retries")
    assert_equal [{ "error" => "SimpleInference::ConnectionError: Connection reset by peer", "pause_seconds" => 10 }], second["retries"]
    attempts = 0
    passed = E2E::ManualClient.retrying(pause: ->(_seconds) { }) do
      attempts += 1
      raise SimpleInference::ConnectionError, "reset" if attempts == 1

      :answered
    end
    assert_empty passed.facts.keys - second.keys, "every fact the retry records rides its message"
    assert_equal second.slice("finish"), record.slice("finish"), "the last message's finish on top"
    assert_equal({ "input_tokens" => 8_300, "output_tokens" => 140 }, record["usage"], "the draw's spend on top, never one call's")

    assert_equal 2, beats.length, "one heartbeat per answered call"
    beats.each do |beat|
      assert_empty beat.keys - %w[model objective sample index seconds usage retries error], beat.inspect
    end
    assert_equal [["openrouter/acme/test-model", "X1", 4, 1], ["openrouter/acme/test-model", "X1", 4, 2]],
      beats.map { |beat| beat.values_at("model", "objective", "sample", "index") }
    assert_equal second["retries"], beats.last["retries"]
    assert_equal second["usage"], beats.last["usage"]
  end

  # A RAISE IN A LATER MESSAGE'S SCORING IS THE DRAW'S ERROR, and the paid run's harness-fault
  # check reads it as the harness's; a provider's refusal of a later call is the draw's error too,
  # kept on its message and its heartbeat, and is no harness fault.
  def test_a_raise_in_the_second_messages_scoring_is_a_harness_fault_and_a_refusal_is_not
    broken = HAND_OUT.with(scorer: ->(_calls, _declared) { raise NoMethodError, "undefined method 'agent' for nil" })
    faulted, = draw(broken, chat(["ls", {}]), chat(["task", { prompt: "a" }]))
    assert_equal false, faulted["pass"]
    assert faulted["error"].start_with?("NoMethodError"), faulted.inspect
    assert_equal 2, faulted.fetch("messages").length
    assert_equal [faulted["error"]], E2E::BenchRecords.faults([faulted]).uniq

    beats = []
    denied = ->(_request) { { status: 400, headers: JSON_HEADERS, body: JSON.generate({ "error" => { "message" => "bad request" } }) } }
    refused, = draw(HAND_OUT, chat(["ls", {}]), denied, heartbeat: ->(facts) { beats << facts })
    assert refused["error"].start_with?("SimpleInference::HTTPError"), refused.inspect
    assert_equal refused["error"], refused.fetch("messages").last["error"]
    assert_equal refused["error"], beats.last["error"]
    assert_empty E2E::BenchRecords.faults([refused])
  end

  # AN ANSWER THE EMULATOR COULD NOT GIVE is the harness's own fault too, kept beside the message
  # whose reads it was answering; no next message is asked.
  def test_an_emulator_that_raises_is_the_draws_harness_fault
    broken = Object.new
    def broken.read_class?(_calls) = true
    def broken.answer(_call) = raise(TypeError, "no implicit conversion of nil into String")

    record, bodies = E2E::TaskBench::Emulator.stub(:open, ->(fixture:, &block) { block.call(broken) }) do
      draw(HAND_OUT, chat(["ls", {}]))
    end
    assert_equal 1, bodies.length
    assert record["error"].start_with?("TypeError"), record.inspect
    assert_equal [1], record.fetch("messages").map { |message| message["index"] }
    assert_equal [record["error"]], E2E::BenchRecords.faults([record]).uniq
  end

  # THE DRAWS OF A RUN: `E2E_BENCH_SAMPLES` per objective (three unset) numbered from
  # `E2E_BENCH_SAMPLE_FIRST` (one unset) — a job split by sample halves numbers its half after
  # the other's; a count that is not a positive integer refuses before anything is paid.
  def test_the_draws_are_counted_and_numbered_from_the_env
    objective = Objectives.find("T5")
    assert_equal 3, objective.samples({})
    assert_equal (1..3).to_a, objective.indices({}).to_a
    assert_equal 5, objective.samples({ "E2E_BENCH_SAMPLES" => "5" })
    assert_equal (6..10).to_a, objective.indices({ "E2E_BENCH_SAMPLES" => "5", "E2E_BENCH_SAMPLE_FIRST" => "6" }).to_a
    assert_equal (1..3).to_a, objective.indices({ "E2E_BENCH_SAMPLES" => "", "E2E_BENCH_SAMPLE_FIRST" => "" }).to_a
    assert_raises(ArgumentError) { objective.samples({ "E2E_BENCH_SAMPLES" => "0" }) }
    assert_raises(ArgumentError) { objective.indices({ "E2E_BENCH_SAMPLE_FIRST" => "one" }) }
  end
end
