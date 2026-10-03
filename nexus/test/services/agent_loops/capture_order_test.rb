require "test_helper"

class AgentLoops::CaptureOrderTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "one tool's captured pictures retain result block order in the continuation" do
    first = capture("first.png", rgb: "\xff\x00\x00".b)
    second = capture("second.png", rgb: "\x00\x00\xff".b)
    agent_loop, task = settled_round([second, first])
    assert_equal [second, first].map { |upload| "nexus://uploads/#{upload.public_id}" },
      AgentAPI::AgentLoopPresenter.task_detail(task.reload).fetch(:content)
        .filter_map { |block| block[:uri] }, "the accepted result itself retains the declared order"

    schedule_loop!(agent_loop)
    continuation = loop_node(agent_loop, "r1")
    assert_equal "running", continuation.status
    assert_predicate build(loop_attempt(agent_loop)), :built?
    pictures = round_request_entries(continuation).flat_map do |entry|
      entry.fetch("parts", []).filter_map { |part| part["upload_public_id"] }
    end
    assert_equal [second.public_id, first.public_id], pictures,
      "the sealed continuation must preserve the same picture order as the accepted result"
  end

  test "replaying more captured results batches their ordered fragment reads" do
    picture = capture("shared.png", rgb: "\x00\x00\xff".b)
    rounds = 8.times.map do
      agent_loop, = settled_round([picture])
      loop_node(agent_loop, "round1")
    end
    small = replay_queries(rounds.first(2), picture)
    large = replay_queries(rounds, picture)

    assert_operator large.length, :<=, small.length,
      "capture ordering must use batched content reads: #{small.length} for 2 rounds, #{large.length} for 8"
  end

  private

    def settled_round(pictures)
      agent_loop = seed(model("round1", "prompt" => "Compare the first and second pictures",
        "tools" => [LoopLaneTestHelper::READ_TOOL]))
      started = AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
      assert_predicate started, :accepted?
      schedule_loop!(agent_loop)
      run_loop_round!(agent_loop, sse_success("reading", tool_calls: [
        { id: "call_pictures", name: "read_file", arguments: "{}" },
      ]))

      task = agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_pictures")
      claimed = Executors::Claim.call(Executors::Claim::Command.new(
        agent_loop: agent_loop, task_key: task.node_key, executor: suite_runner
      ))
      assert_predicate claimed, :accepted?

      # The executor may stage files before deciding their result order.
      # The result's ordered blocks, not upload ids or join scan order, name
      # which picture "first" and "second" mean to the next model round.
      links = pictures.map do |upload|
        { "type" => "resource_link", "uri" => "nexus://uploads/#{upload.public_id}",
          "name" => upload.filename.to_s }
      end
      committed = Executors::Commit.call(Executors::Commit::Command.new(
        agent_loop: agent_loop, task_key: task.node_key, executor: suite_runner,
        claim_token: claimed.value.claim_token,
        content: [{ "type" => "text", "text" => "The first picture is blue; the second is red." }, *links],
        structured_content: nil, result_type: nil, outcome: "completed", is_error: false,
        title: nil, metadata: nil
      ))
      assert_predicate committed, :applied?
      [agent_loop, task]
    end

    def replay_queries(rounds, picture)
      # Reload both sample sizes so a previous replay's association cache
      # cannot hide physical SQL when the larger history is read.
      rounds = rounds.map(&:reload)
      fans = AgentLoops::RoundReplay.fans_of(rounds)
      calls = fans.values.flat_map(&:values)
      queries = []
      capture = lambda do |*, payload|
        sql = payload.fetch(:sql)
        if !payload[:cached] && sql.match?(/\ASELECT .*FROM "content_(?:bodies|body_entries|fragments)"/m)
          queries << sql
        end
      end
      ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
        ApplicationRecord.uncached do
          AgentLoops::RoundReplay.preload(rounds, calls: calls)
          rounds.each do |round|
            replay = AgentLoops::RoundReplay.call(round, fan_by_call_id: fans.fetch(round.id))
            assert_equal [picture.public_id], replay.picture.upload_public_ids
          end
        end
      end
      queries
    end

    def capture(filename, rgb:)
      Tempfile.create(["ordered-capture", ".png"], binmode: true) do |file|
        file.write(PngFixture.bytes(width: 1, height: 1, rgb: rgb))
        file.flush
        uploaded = Rack::Test::UploadedFile.new(file.path, "image/png", original_filename: filename)
        result = ContentUploads::Create.call(account: @account, creator: suite_runner, file: uploaded)
        assert_predicate result, :accepted?
        result.upload
      end
    end
end
