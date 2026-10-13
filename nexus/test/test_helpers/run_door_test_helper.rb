# The loop door in tests: a message through the one `Conversations::Inputs::Create` over a LOOP
# host, the way the HTTP door knocks — every field the loop does not admit left absent.
module RunDoorTestHelper
  def loop_input!(agent_run, acting_user:, text:, delivery_mode: "steer", **over)
    Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(**{
      host: agent_run, acting_user: acting_user, kind: "message", role: "user",
      entries: [{ "text" => text }], visible_in_context: nil, delivery_mode: delivery_mode,
      context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil,
    }.merge(over)))
  end
end
