require "test_helper"

# THE LOOP DOOR: the one waiting room, hosted by a standalone
# loop at its own address. The context is the conversation's, handed a
# different path — so what a conversation caller already knows about the
# queue is what a loop caller knows, and the two can never drift.
class ApiAgentLoopInputsTest < Minitest::Test
  WORKSPACE_ID = "019f0000-0000-7000-8000-000000000101".freeze
  LOOP_ID = "019f0000-0000-7000-8000-000000000601".freeze
  INPUTS_PATH = "/agent_api/v1/workspaces/#{WORKSPACE_ID}/agent_loops/#{LOOP_ID}/inputs".freeze

  INPUT = {
    "public_id" => "019f0000-0000-7000-8000-0000000009a1",
    "queue_position" => 0,
    "state" => "steering",
    "kind" => "message",
    "role" => "user",
    "delivery_mode" => "steer",
    "origin" => "person",
    # Every input names its addressee and its author: a
    # loop-host row answers as the loop's creator.
    "answering_user_public_id" => "019f0000-0000-7000-8000-0000000000a1",
    "speaker" => { "user_public_id" => "019f0000-0000-7000-8000-0000000000a1", "handle" => "ada",
                   "kind" => "human", "display_name" => "Ada" },
    "text" => "use postgres, not sqlite",
    "lock_version" => 0,
    "created_at" => "2026-09-05T00:00:00Z",
  }.freeze

  def workspace(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member",
      transport: @transport).workspace(WORKSPACE_ID)
  end

  def inputs(script) = workspace(script).agent_loops.agent_loop(LOOP_ID).inputs

  def request(index = 0) = @transport.requests.fetch(index)

  def test_a_steer_is_a_message_through_the_loop_door_bound_to_its_one_turn
    accepted = inputs([[202, {}, { "input" => INPUT }]]).create(
      text: "use postgres, not sqlite", delivery_mode: "steer", idempotency_key: "say-1"
    )

    assert_equal :post, request[:method]
    assert_equal INPUTS_PATH, request[:path]
    assert_equal "say-1", request[:headers].fetch("Idempotency-Key")
    assert_equal({ "input" => { "text" => "use postgres, not sqlite", "delivery_mode" => "steer" } },
      request[:body])
    assert_equal "steering", accepted.state
    refute_predicate accepted, :replayed?
    assert_nil accepted.input.context_mode, "a loop-host row shows only what its door admits"
  end

  def test_the_queue_reads_edits_gives_up_and_reorders_at_the_loop_address
    context = inputs([
      [200, {}, { "inputs" => [INPUT], "input_queue" => { "limit" => 16, "held" => 1 } }],
      [200, {}, { "input" => INPUT.merge("text" => "shorter") }],
      [204, {}, nil],
      [200, {}, { "inputs" => [INPUT] }],
    ])

    list = context.list
    assert_equal 16, list.input_queue.limit
    assert_equal 1, list.input_queue.held
    assert_equal INPUTS_PATH, request(0)[:path]

    context.update(INPUT.fetch("public_id"), text: "shorter", expected_lock_version: 0)
    assert_equal "#{INPUTS_PATH}/#{INPUT.fetch("public_id")}", request(1)[:path]
    assert_equal :patch, request(1)[:method]

    context.delete(INPUT.fetch("public_id"))
    assert_equal :delete, request(2)[:method]

    context.reorder([INPUT.fetch("public_id")])
    assert_equal "#{INPUTS_PATH}/reorder", request(3)[:path]
  end

  # THE REPLY-LANE FIELDS ARE REFUSED BY NAME AT THIS DOOR: a loop host admits a `message`
  # and nothing that names a model, a tool subset or — an approval tightening; the loop's
  # one turn carries its shell's mode. The context sends what it is given (one context,
  # two paths) and the kernel answers 422 `validation_failed` naming the field, typed here
  # — never a silent drop.
  def test_the_loop_door_refuses_the_reply_lanes_fields_by_name
    %w[tool_names approval_mode].each do |field|
      value = field == "tool_names" ? %w[read_file] : "ask"
      error = assert_raises(CybrosAgent::Api::InvalidRequest) do
        inputs([[422, {}, { "error" => { "code" => "validation_failed",
                                         "message" => "#{field.tr("_", " ").capitalize} must be blank" } }]])
          .create(text: "late", idempotency_key: "say-3", field.to_sym => value)
      end
      assert_equal "validation_failed", error.code
      assert_equal value, request.fetch(:body).fetch("input").fetch(field), "sent as written; the door judged it"
    end
  end

  # The two refusals a loop door adds arrive as the status they ride on,
  # carrying the kernel's code — documented, not tabled.
  def test_a_settled_or_loop_backed_loop_refuses_by_name
    %w[agent_loop_settled conversation_hosted].each do |code|
      error = assert_raises(CybrosAgent::Api::Error) do
        inputs([[409, {}, { "error" => { "code" => code, "message" => "no" } }]])
          .create(text: "late", idempotency_key: "say-2")
      end
      assert_equal code, error.code
    end
  end
end
