require "test_helper"
require "support/fixture_project"
require "support/live_journey"

# A live-model diagnostic: the parent reads a file, then begins a longer task.
# A default writable Side asks about that context while the parent continues.
# The model is asked to answer without tools; ordinary Side permissions remain
# in effect. The lane checks the answer and absence of calls, inherited content
# and order, and a stable reference snapshot across Side turns. Raw prefix equality
# is reported separately because last_turn reasoning replay can change its bytes.
# Provider cache reads are observations, not proof that a particular parent
# prefix supplied them; the second Side request may reuse the Side's own cache.
#
# Run ALONE after the four-world gate, never beside it: E2E_LIVE=1 rake live_side # the floor,
# deepseek/deepseek-flash, by default
class LiveSideTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  # Words a right answer carries: the file's path word and its method.
  TASK_WORDS = %w[greeting salute].freeze
  BOUNDARY_TEXT = "[The turns above are inherited from the parent conversation as reference. " \
    "Only the turns after this point belong to this conversation.]".freeze

  PROJECT = {
    "lib/greeting.rb" => <<~RUBY,
      module Greeting
        def self.salute(name) = "Hello, \#{name}!"
      end
    RUBY
    "lib/farewell.rb" => <<~RUBY,
      module Farewell
        def self.wave(name) = "Goodbye, \#{name}."
      end
    RUBY
    "lib/tally.rb" => <<~RUBY,
      module Tally
        def self.count_words(text) = text.split.size
      end
    RUBY
  }.freeze

  TURN_1 = "Read lib/greeting.rb and reply with the name of the one method it defines — the method name only.".freeze
  TURN_2 = "Now read lib/farewell.rb and lib/tally.rb one at a time. Then write NOTES.md with one line per file " \
           "under lib/ naming its method and what it does. Then run " \
           "`ruby -Ilib -e 'require \"greeting\"; require \"farewell\"; require \"tally\"; " \
           "puts Tally.count_words(Greeting.salute(\"x\") + Farewell.wave(\"y\"))'` and reply with its output.".freeze
  QUESTION = "Answer from the conversation above only, with no tool: which file did you read earlier in this " \
             "conversation, and what is its method called? One line.".freeze
  FOLLOW_UP = "And what argument does that method take? One line, from the conversation above only.".freeze
  include E2E::LiveJourney

  def setup = start_live_journey!(MODEL, home_prefix: "rho-live-side-e2e")

  def teardown = finish_live_journey!

  def test_rho_side_answers_from_inherited_context_while_the_parent_runs_and_reports_provider_cache
    connect_and_open_lane!
    project = E2E::FixtureProject.write(@home, "notes", PROJECT)
    @daemon.control(:post, "/environment", body: { root: project.root })

    output, status = @daemon.cli("do", TURN_1, "--model", MODEL, "--dir", project.root)
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    conversation = output[/^conversation:\s+(\S+)/, 1]
    first_loop = output[/^run:\s+(\S+)/, 1]
    refute_nil first_loop, "rho do printed no loop id:\n#{output}"
    rho_watch(first_loop, "--timeout", "300")
    assert_equal "completed", await_loop_completion(first_loop).fetch("status"), "the first turn did not settle"
    chat = client.workspace(workspace_public_id).conversations.conversation(conversation)

    said, status = @daemon.cli("say", conversation, TURN_2, "--mode", "queue")
    assert_predicate status, :success?, "rho say failed:\n#{said}"
    running = await_running_turn(chat)
    second_loop = running.active_variant.run_public_id
    await_tool_call(second_loop)
    assert_predicate chat.fetch, :busy?, "the parent's second turn is running when Side opens"

    opened = @daemon.control(:post, "/side", body: { "parent_public_id" => conversation, "text" => QUESTION })
    refute opened["error"], opened.inspect
    side_id = opened.fetch("side").fetch("public_id")
    side = client.workspace(workspace_public_id).conversations.conversation(side_id)
    reply = poll("the Side's first reply never settled", seconds: 240) do
      side.turns.list.items.find do |turn|
        !turn.inherited? && !turn.reference? && turn.role == "assistant" && turn.status == "completed"
      end
    end
    side_loop = await_loop_completion(reply.active_variant.run_public_id)
    assert_empty side_loop.fetch("tasks").select { |task| task["kind"] == "tool_task" },
      "the model did not follow the request to answer from context: #{summarize(side_loop)}"
    answer = reply.text.to_s
    still_running = chat.fetch.busy?
    puts "\n--- live side on #{MODEL}: parent still running after first Side reply: #{still_running}\n#{answer}"
    assert TASK_WORDS.any? { |word| answer.downcase.include?(word) },
      "the Side's answer names no word of the earlier turn (#{TASK_WORDS.join("/")}):\n#{answer}"
    side_rows = @daemon.control(:get, "/followers?side=1").fetch("followers").select { |row| row.dig("side", "parent") == conversation }
    assert_equal [side_id], side_rows.map { |row| row.fetch("public_id") }

    first_read = side.fetch.context&.cache_read_tokens
    parent_tools = tool_count(chat, running.public_id)
    side_tools = tool_count(side, reply.public_id)

    # A second question retains the captured reference content. Its reasoning
    # replay and the provider's cache decisions can differ from the first turn.
    said, status = @daemon.cli("say", side.public_id, FOLLOW_UP)
    assert_predicate status, :success?, "rho say on the side failed:\n#{said}"
    second = poll("the side's second reply never settled") do
      side.turns.list.items.find { |turn| turn.role == "assistant" && turn.position > reply.position && turn.status == "completed" }
    end
    second_run = await_loop_completion(second.active_variant.run_public_id)
    assert_empty second_run.fetch("tasks").select { |task| task["kind"] == "tool_task" },
      "the follow-up called a tool, so its cache usage spans multiple requests: #{summarize(second_run)}"
    second_read = side.fetch.context&.cache_read_tokens
    rho_watch(second_loop, "--timeout", "600")
    parent_read = chat.fetch.context&.cache_read_tokens

    assert_context_and_report_prefixes(chat, running, side, reply, second)
    second_tools = tool_count(side, second.public_id)
    puts "--- live side: cache_read_tokens side1=#{first_read.inspect} side2=#{second_read.inspect} parent=#{parent_read.inspect}; " \
         "tools parent=#{parent_tools} side1=#{side_tools} side2=#{second_tools}"
    skip "the provider reported no cache field (#{MODEL})" if [first_read, second_read, parent_read].all?(&:nil?)

    # Cache warmth belongs to the provider. Structural assertions above remain
    # independent of whether this invocation reports a cache hit.
    if first_read.to_i.zero? && second_read.to_i.zero?
      puts "--- live side observation: #{MODEL} reported no cache read for either Side request. " \
           "The inherited content and order hold; the parent's newest round reported #{parent_read.inspect}."
      skip "#{MODEL} reported no Side cache read on this run"
    end
    puts "--- live side observation: positive provider cache reads do not identify which earlier request supplied the cache."
  end

  private

    def client
      @client ||= CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    end

    # How many tool declarations a turn's sealed r1 carried on the wire.
    def tool_count(chat, turn_public_id)
      turn = chat.turns.list.items.find { |row| row.public_id == turn_public_id }
      Array(chat.turns.request(turn_public_id, turn.active_variant.public_id).request_options["tools"]).size
    end

    # The parent's newest RUNNING assistant turn, its loop minted.
    def await_running_turn(chat)
      poll("the parent's second turn never ran") do
        chat.turns.list.items.find do |row|
          row.role == "assistant" && row.status == "running" && row.active_variant&.run_public_id
        end
      end
    end

    # `last_turn` chooses the newest eligible trace in each request, so raw
    # request equality is diagnostic. All non-reasoning content remains an
    # ordered exact comparison, including calls, results and uploaded parts.
    def assert_context_and_report_prefixes(chat, running, side, first, second)
      parent_r1 = chat.turns.request(running.public_id, running.active_variant.public_id)
      side_r1 = side.turns.request(first.public_id, first.active_variant.public_id)
      side_r2 = side.turns.request(second.public_id, second.active_variant.public_id)
      k = parent_r1.entries.length - 1
      pinned = parent_r1.entries.first(k) == side_r1.entries.first(k)
      puts "--- live side prefix parent→side: #{pinned} (k=#{k}; parent #{parent_r1.entries.length} entries, " \
           "side #{side_r1.entries.length})"
      common = side_r1.entries.zip(side_r2.entries).take_while { |a, b| a == b }.size
      puts "--- live side prefix side1→side2: #{common}/#{side_r1.entries.length} entries equal; " \
           "first difference: #{excerpt(side_r1.entries[common])} | #{excerpt(side_r2.entries[common])}"

      settled = semantic_entries(parent_r1.entries.first(k))
      first_reference = reference_prefix(semantic_entries(side_r1.entries))
      second_reference = reference_prefix(semantic_entries(side_r2.entries))
      assert_equal settled, first_reference.first(settled.length),
        "the Side lost or reordered settled parent content"
      current = first_reference.drop(settled.length).flat_map { |entry| Array(entry["parts"]) }
        .filter_map { |part| part["text"] if part["type"] == "text" }.join("\n")
      assert_includes current, TURN_2, "the Side lost the parent's current question before the reference boundary"
      assert_equal first_reference, second_reference,
        "the Side's captured reference content changed after the parent continued"
    end

    # Replay changes only reasoning items/parts and a signed tool call's
    # provider payload. Split ordinary message parts to ignore only the
    # message-merge boundary that replay can move; each part stays exact.
    def semantic_entries(entries)
      entries.flat_map do |entry|
        if entry["type"] == "reasoning_item"
          []
        elsif entry.key?("parts")
          entry.fetch("parts").reject { |part| part["type"] == "reasoning" }
            .map { |part| entry.merge("parts" => [part]) }
        elsif entry["type"] == "tool_call_item"
          [entry.except("native_origin").merge("payload" => entry.fetch("payload").except("provider_payload"))]
        else
          [entry]
        end
      end
    end

    def reference_prefix(entries)
      boundaries = entries.each_index.select do |index|
        entry = entries[index]
        entry["role"] == "user" && entry.dig("parts", 0, "text") == BOUNDARY_TEXT
      end
      assert_equal 1, boundaries.length, "the Side's request must carry one reference boundary"
      entries.first(boundaries.first)
    end

    def excerpt(entry)
      return "nil" if entry.nil?

      text = Array(entry["parts"]).map { |part| part["text"].to_s }.join
      "#{entry["role"] || entry["type"]}:#{text[0, 100].inspect}"
    end

    # r1 is sealed and the model has acted: a tool task EXISTS on the loop,
    # whatever its status — a `read` on this machine is claimed and done
    # inside one poll, so "running" is never observed on a real model.
    def await_tool_call(run_public_id)
      poll("the second turn never called a tool", seconds: 240) do
        row = loop_row(run_public_id)
        row if row.fetch("tasks").any? { |task| task["kind"] == "tool_task" }
      end
    end

    def poll(message, seconds: 120)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      loop do
        value = yield
        return value if value
        flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 1
      end
    end
end
