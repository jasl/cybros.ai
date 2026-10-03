require "support/runtime"

class TelegramBusyInputTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_ordinary_input_queues_and_explicit_steer_submits_only_its_body
    @runtime.consume(telegram_message(1, "Do the original work"))
    @runtime.consume(telegram_message(2, "This is the next request"))
    @runtime.consume(telegram_message(3, "/steer Keep the output in Chinese"))

    assert_equal %w[queue queue steer], @bridge.inputs.values.map { |input| input.fetch(:mode) }
    assert_equal "Keep the output in Chinese", @bridge.inputs.values.last.fetch(:text)
    assert_equal ["conversation-1"], @bridge.inputs.values.map { |input| input.fetch(:conversation_id) }.uniq
    assert_empty @bridge.stops
    assert_equal "Your request is queued.\nTask: input-2", @state.read.fetch("deliveries").fetch("control:2").fetch("text")
    assert_includes @state.read.fetch("deliveries").fetch("control:3").fetch("text"), "Running tools are not interrupted"
  end

  def test_steer_replay_keeps_the_original_model_scope_and_input_key
    @runtime.consume(telegram_message(1, "Start"))
    @state.change { |doc| doc.fetch("routes").fetch("1:0")["model"] = "vendor/original" }
    @bridge.fail_input = true
    update = telegram_message(2, "/steer Add this constraint")
    assert_raises(Rho::ConnectionError) { @runtime.consume(update) }
    @bridge.default_workspace = @bridge.workspace_rows.last
    @state.change { |doc| doc.fetch("routes").fetch("1:0")["model"] = "vendor/new" }

    @runtime = runtime
    @runtime.consume(update)
    @runtime.consume(update)

    assert_equal 2, @bridge.inputs.length
    accepted = @bridge.inputs.fetch("telegram:42:2:input")
    assert_equal "steer", accepted.fetch(:mode)
    assert_equal "Add this constraint", accepted.fetch(:text)
    assert_equal "vendor/original", accepted.fetch(:model)
    assert_equal "workspace-home", accepted.fetch(:workspace_public_id)
    assert_equal 3, @state.read.fetch("offset")
    assert_nil @state.read["pending_update"]
  end

  def test_empty_steer_or_steer_without_a_known_task_never_opens_or_submits
    @runtime.consume(telegram_message(1, "/steer   "))
    @runtime.consume(telegram_message(2, "/steer Change the plan", user: 2, chat: -10))

    assert_empty @bridge.inputs
    assert_empty @bridge.opened
    assert_includes @state.read.fetch("deliveries").fetch("control:1").fetch("text"), "/steer"
    assert_includes @state.read.fetch("deliveries").fetch("control:2").fetch("text"), "No conversation is open"
  end

  def test_media_captions_are_not_silently_submitted_as_text_only_busy_commands
    %w[steer btw].each_with_index do |name, index|
      id = index + 1
      update = telegram_message(id, "")
      update.fetch("message").delete("text")
      update.fetch("message").merge!("caption" => "/#{name} Explain this image",
        "photo" => [{ "file_id" => "photo", "width" => 100, "height" => 100, "file_size" => 20 }])
      @runtime.consume(update)
      assert_includes @state.read.fetch("deliveries").fetch("control:#{id}").fetch("text"), "accepts text only"
    end
    assert_empty @bridge.inputs
    assert_empty @bridge.opened
  end
end
