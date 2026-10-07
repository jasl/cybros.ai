require "test_helper"
require_relative "../../../test_helpers/compaction_test_helper"

# Summarizers receive the host's declared names and profile instruction slot.
class Conversations::Compaction::SummarizerConfigurationTest < ActiveJob::TestCase
  include CompactionTestHelper

  # THE SUMMARY NAMES ONLY DECLARED TOOLS: a kernel summary's NEXT STEPS said "call
  # `execute_command`" to a loop that had declared `bash` — the summarizer had been told no names at
  # all, and model-facing names are load-bearing. The declared set rides the REQUEST, under one
  # header, in the spelling the model saw: an alias by its alias, never the kernel's wire name.
  # INSTRUCTIONS stays one text for both hosts. Here the mock answers what the harness writes, so
  # the summary's own next steps are provable only live — a recorded observation, never a pass
  # condition.
  test "the summarizer is told the names the repaired round declared, in the model's spelling" do
    agent_run = loop_with_history(tools: [declared("bash"), WAIT_ALIAS])
    schedule!(agent_run)

    request = node(agent_run, "k1").content_bodies.find_by!(role: "input").effective_text
    assert_includes request, Conversations::Compaction::Serialize::TOOLS_HEADER
    assert_includes request, "bash"
    assert_includes request, "AwaitWork", "the alias is the name the model saw"
    refute_match(/\bwait\b/, request, "the kernel's wire name never reaches the summarizer")
    assert_operator request.index(Conversations::Compaction::Serialize::TOOLS_HEADER), :<,
      request.index(Conversations::Compaction::Serialize::HEADER), "the names lead the transcript"
    assert_equal Conversations::Compaction::Summarizer::INSTRUCTIONS, node(agent_run, "k1").system_instructions,
      "the names ride the request, never the one INSTRUCTIONS"
  end

  # THE SUMMARIZER SLOT: the declaring profile's `summarizer` prompt document is the kernel step's
  # `instructions` — mid-turn the loop's answering agent, between turns the conversation's default
  # answerer — and the window fit counts the same text; absent, the one INSTRUCTIONS (pinned above).
  # The delegate arm hands its tool the rendering and never reads the slot.
  SLOT_TEXT = "Summarize by pointers, in three lines, ending on the next action.".freeze

  def write_summarizer_slot!(agent = @agent)
    written = PromptDocuments::Write.call(anchor: { user: agent }, slot: "summarizer", content: SLOT_TEXT)
    assert_predicate written, :written?
  end

  test "the mid-turn summarizer reads the answering agent's summarizer slot" do
    write_summarizer_slot!
    _conversation, _turn, agent_run = run_backed_two_reads!(
      first_words: prose(22_000), first_body: "first line: alpha\n",
      second_words: prose(22_000), second_body: "first line: beta\n"
    )
    schedule_loop!(agent_run)

    assert_equal "k1", loop_node(agent_run, "r3").compaction["summary_source"]
    assert_equal SLOT_TEXT, loop_node(agent_run, "k1").system_instructions, "the slot's bytes, not INSTRUCTIONS"
  end

  test "the between-turn summarizer reads the answering agent's summarizer slot" do
    write_summarizer_slot!
    declare_tools!(@agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    build_history!
    post_input!(@conversation, acting_user: @agent, kind: "direct_reply",
      text: "and now what #{SecureRandom.hex(PROMPT_HEX)}", provider_id: "dev", model_ref: "mock-text",
      context_options: { "history" => { "token_budget_share" => 1.0 } })
    assert_equal 0, drain!, "the head waits behind the summary"

    assert_equal SLOT_TEXT, summary_loop.agent_run_tasks.sole.system_instructions
  end

  test "a human-answered conversation's summarizer has no slot to read and carries INSTRUCTIONS" do
    write_summarizer_slot!
    build_history!
    ask_greedily!
    drain!

    assert_equal Conversations::Compaction::Summarizer::INSTRUCTIONS,
      summary_loop.agent_run_tasks.sole.system_instructions
  end

  test "the window fit counts the slot's text, and the delegate arm never reads it" do
    write_summarizer_slot!
    selection = mock_text_selection
    counted = []
    count = ModelRequests::TokenCount.method(:count)
    counter = lambda do |profile:, segments:|
      counted << segments.first
      count.call(profile: profile, segments: segments)
    end
    kernel = Conversations::Compaction::Summarizer.new(
      key: "k1", policy: { "mode" => "kernel" }, account: @account, model: "dev/mock-text",
      reasoning_effort: nil, address: nil, selection: selection, profile: @agent
    )
    assert_equal SLOT_TEXT, kernel.instructions
    entries = ["turn0 (user): #{prose(400)}", "turn1 (assistant): #{prose(400)}"]
    older, tail = Conversations::Compaction::Serialize.call(entries)
    step = ModelRequests::TokenCount.stub(:count, counter) { kernel.step(entries, older, tail) }
    assert_equal SLOT_TEXT, step.instructions
    assert_equal [SLOT_TEXT], counted.uniq, "the fit counted the slot's text ahead of the request"

    delegate = Conversations::Compaction::Summarizer.new(
      key: "k1", policy: { "mode" => "delegate", "tool_name" => "summarize_history" }, account: @account,
      model: "dev/mock-text", reasoning_effort: nil, address: { "agent_run" => "al-1" }, profile: @agent
    )
    handed = delegate.step(entries, older, tail)
    assert_instance_of AgentRuns::Tasks::Step::Tool, handed
    refute_includes handed.input.to_json, SLOT_TEXT, "a delegate's tool knows its own text"
  end

  test "a summarizer for a round that declared nothing is told no tools" do
    agent_run = loop_with_history
    schedule!(agent_run)

    request = node(agent_run, "k1").content_bodies.find_by!(role: "input").effective_text
    refute_includes request, Conversations::Compaction::Serialize::TOOLS_HEADER
    assert_includes request, Conversations::Compaction::Serialize::HEADER
  end

  # Between turns there is no round: the names are the answering agent's standing declaration, and a
  # human-answered conversation declares nothing.
  test "the between-turn summarizer is told the answering agent's declared names" do
    declare_tools!(@agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    build_history!
    post_input!(@conversation, acting_user: @agent, kind: "direct_reply",
      text: "and now what #{SecureRandom.hex(PROMPT_HEX)}", provider_id: "dev", model_ref: "mock-text",
      context_options: { "history" => { "token_budget_share" => 1.0 } })
    assert_equal 0, drain!, "the head waits behind the summary"

    request = summary_loop.agent_run_tasks.sole.content_bodies.find_by!(role: "input").effective_text
    assert_includes request, Conversations::Compaction::Serialize::TOOLS_HEADER
    assert_includes request, "read_file"
  end

  test "a human-answered conversation's summarizer is told no tools" do
    build_history!
    ask_greedily!
    drain!

    request = summary_loop.agent_run_tasks.sole.content_bodies.find_by!(role: "input").effective_text
    refute_includes request, Conversations::Compaction::Serialize::TOOLS_HEADER
  end
end
