require "test_helper"

class AgentAPI::V1::ConversationHistoryQueriesTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include InvocationHarness
  include RunLaneTestHelper

  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @token = create_access_token_fixture(user: @human, name: "History reader")
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent)
  end

  test "context preview batches round calls and results as history grows" do
    complete_reply("short", rounds: 1)
    preview
    small = preview_queries

    complete_reply("long", rounds: 10)
    large = preview_queries

    entries = response.parsed_body.fetch("context_estimate").fetch("entries")
    rendered = entries.to_json
    assert_includes rendered, "short answer"
    assert_includes rendered, "long answer"
    10.times do |index|
      assert_includes rendered, "long result #{index}"
    end
    assert_operator large.length, :<=, small.length + 5,
      "history grew from 2 to 13 model rounds: #{small.length} -> #{large.length} queries\n#{large.join("\n")}"
  end

  test "context preview replays own loop replies without loading their final content projection" do
    turns = Array.new(3) do |index|
      complete_reply("reply #{index}", rounds: 0,
        answer: "answer #{index}: " + "implementation details\n" * 750)
    end
    variants = turns.map(&:active_variant_id)
    bodies = loaded_bodies { preview(model: DevModelLane::WINDOWLESS_TEXT_MODEL) }

    rendered = response.parsed_body.fetch("context_estimate").fetch("entries")
      .flat_map { |entry| entry.fetch("parts").filter_map { |part| part["text"] } }.join("\n")
    turns.each_index do |index|
      assert_includes rendered, "reply #{index} question"
      assert_includes rendered, "answer #{index}: " + "implementation details\n" * 750
    end
    unused = bodies.select { |body| body.role == "content" && variants.include?(body.conversation_turn_variant_id) }
    assert_empty unused,
      "round replay already owns these answers: loaded #{unused.length} unused content bodies, " \
        "#{unused.sum { |body| body.readable_text.to_s.bytesize }} redundant text bytes"
  end

  test "context preview keeps the adopted content when a loop reply was manually edited" do
    turn = complete_reply("original", rounds: 0)
    post "/agent_api/v1/workspaces/#{@workspace.public_id}/conversations/#{@conversation.public_id}/turns/#{turn.public_id}/edit",
      headers: { "Authorization" => "Bearer #{@token.secret}" }, as: :json,
      params: { edit: { text: "my corrected answer" } }
    assert_response :success

    preview(model: DevModelLane::WINDOWLESS_TEXT_MODEL)

    rendered = response.parsed_body.fetch("context_estimate").fetch("entries").to_json
    assert_includes rendered, "original question"
    assert_includes rendered, "my corrected answer"
    refute_includes rendered, "original answer"
  end

  test "timeline batches attachment parts as the page grows" do
    add_picture_message(0)
    timeline
    small = attachment_queries { timeline }

    19.times { |index| add_picture_message(index + 1) }
    large = attachment_queries { timeline }

    turns = response.parsed_body.fetch("turns")
    assert_equal 20, turns.length
    assert_equal [@picture.public_id] * 20,
      turns.map { |turn| turn.dig("active_variant", "attachments", 0, "public_id") }
    assert_operator large.length, :<=, small.length,
      "one to twenty attachment bodies: #{small.length} -> #{large.length} queries\n#{large.join("\n")}"
  end

  test "context preview batches attachment parts as history grows" do
    add_picture_message(0)
    preview(model: DevModelLane::WINDOWLESS_TEXT_MODEL)
    small = attachment_queries { preview(model: DevModelLane::WINDOWLESS_TEXT_MODEL) }

    19.times { |index| add_picture_message(index + 1) }
    large = attachment_queries { preview(model: DevModelLane::WINDOWLESS_TEXT_MODEL) }

    rendered = response.parsed_body.fetch("context_estimate").fetch("entries").to_json
    20.times { |index| assert_includes rendered, "picture #{index}" }
    assert_operator large.length, :<=, small.length,
      "one to twenty attachment bodies: #{small.length} -> #{large.length} queries\n#{large.join("\n")}"
  end

  private

    def add_picture_message(index)
      @picture ||= @account.content_uploads.create!(
        creating_user: @human,
        file: ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(PNG), filename: "diagram.png", content_type: "image/png", identify: false
        )
      )
      post "/agent_api/v1/workspaces/#{@workspace.public_id}/conversations/#{@conversation.public_id}/inputs",
        headers: { "Authorization" => "Bearer #{@token.secret}", "Idempotency-Key" => "picture-#{index}" },
        as: :json, params: { input: { text: "picture #{index}", attachments: [@picture.public_id] } }
      assert_response :accepted
      outcome = Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
      assert_predicate outcome, :accepted?, outcome.outcome.to_s
      clear_enqueued_jobs
    end

    def timeline
      get "/agent_api/v1/workspaces/#{@workspace.public_id}/conversations/#{@conversation.public_id}/turns",
        headers: { "Authorization" => "Bearer #{@token.secret}" }
      assert_response :success
    end

    def attachment_queries(&block)
      read_queries(&block).grep(/FROM "(?:content_body_entries|content_fragments)"/)
    end

    def complete_reply(label, rounds:, answer: "#{label} answer")
      turn, agent_run = materialize_loop_reply!(@conversation, agent: @human, text: "#{label} question")
      schedule_loop!(agent_run)
      rounds.times do |index|
        call_id = "#{label}_#{index}"
        run_loop_round!(agent_run, sse_success("#{label} working #{index}", tool_calls: [
          { id: call_id, name: "read_file", arguments: { path: "#{index}.txt" }.to_json },
        ]))
        call = agent_run.agent_run_tasks.find_by!(tool_call_id: call_id)
        AgentRuns::Parks::Settle.call(node: call, trusted: true,
          content: "#{label} result #{index}", outcome: "completed")
        schedule_loop!(agent_run)
      end
      run_loop_round!(agent_run, sse_success(answer))
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status
      clear_enqueued_jobs
      turn
    end

    def preview(model: "dev/mock-text")
      post "/agent_api/v1/workspaces/#{@workspace.public_id}/conversations/#{@conversation.public_id}/context_estimate",
        headers: { "Authorization" => "Bearer #{@token.secret}" }, as: :json,
        params: { context_estimate: { prompt: "continue", model: { model: model }, render: true } }
      assert_response :success
    end

    def preview_queries
      read_queries { preview }
    end

    def loaded_bodies
      bodies = []
      observer = ->(body) { bodies << body }
      ContentBody.set_callback(:find, :after, observer)
      yield
      bodies
    ensure
      ContentBody.skip_callback(:find, :after, observer)
    end

    def read_queries
      ApplicationRecord.connection_pool.clear_query_cache
      queries = []
      callback = lambda do |*, payload|
        queries << payload[:sql] unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
      queries
    end
end
