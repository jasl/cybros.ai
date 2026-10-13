require "support/runtime"

class TelegramQuestionReconciliationTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_a_sent_local_notice_becomes_the_addressed_question_without_duplicate_delivery
    receive(telegram_message(1, "start"))
    @bridge.pending_rows = [local_notice]
    @runtime.tick
    id, local = @state.read.fetch("questions").first
    receipt = @state.read.fetch("deliveries").fetch("question:#{id}")
    assert_equal "local", local.fetch("kind")
    assert_equal "sent", receipt.fetch("status")

    @bridge.pending_rows = [addressed_question]
    @now += Rho::IngressTelegram::Runtime::RECONCILE_INTERVAL
    @runtime.tick

    question = @state.read.fetch("questions").fetch(id)
    assert_equal "ask", question.fetch("kind")
    assert_equal "workspace-home", question.fetch("workspace_public_id")
    assert_equal receipt, @state.read.fetch("deliveries").fetch("question:#{id}")
    assert_equal 2, question.fetch("message_ids").length
    assert_includes question.fetch("message_ids"), local.fetch("message_ids").first
    assert_equal 1, sent_texts.count { |text| text.include?("Continue the original request?") }

    @now += Rho::IngressTelegram::Runtime::RECONCILE_INTERVAL
    @runtime.tick
    @runtime = runtime
    @runtime.tick
    assert_equal 1, sent_texts.count { |text| text.include?("Continue the original request?") }
  end

  def test_replying_to_the_old_notice_after_restart_answers_the_same_question_and_cleans_both_receipts
    id, local = publish_local_notice
    old_message_id = local.fetch("message_ids").first
    @runtime = runtime
    publish_addressed_question

    receive(telegram_message(2, "Continue", reply_to: old_message_id))

    assert_equal [["answer", "loop-1", "ask-1", "Continue", "workspace-home"]], @bridge.decisions
    assert_equal 1, @bridge.inputs.length
    assert @state.read.fetch("questions").fetch(id).fetch("resolved")
    @bridge.pending_rows = []
    @now += Rho::IngressTelegram::Runtime::RECONCILE_INTERVAL
    @runtime.tick
    refute @state.read.fetch("questions").key?(id)
    refute @state.read.fetch("deliveries").values.any? { |entry| entry["question_id"] == id }
  end

  def test_replying_to_the_new_prompt_after_restart_answers_the_same_question
    id, local = publish_local_notice
    publish_addressed_question
    @runtime = runtime
    message_id = (@state.read.fetch("questions").fetch(id).fetch("message_ids") - local.fetch("message_ids")).fetch(0)

    receive(telegram_message(2, "Continue", reply_to: message_id))

    assert_equal [["answer", "loop-1", "ask-1", "Continue", "workspace-home"]], @bridge.decisions
    assert_equal 1, @bridge.inputs.length
  end

  def test_an_unsent_local_notice_is_withdrawn_when_the_question_becomes_answerable
    @state.change { |document| document["retry_at"] = @now + 10 }
    id, = publish_local_notice
    assert_equal "pending", @state.read.fetch("deliveries").fetch("question:#{id}").fetch("status")

    publish_addressed_question
    refute @state.read.fetch("deliveries").key?("question:#{id}")
    @now += Rho::IngressTelegram::Runtime::RECONCILE_INTERVAL
    @runtime.tick

    refute_includes sent_texts, local_notice.fetch("question")
    assert_equal 1, sent_texts.count { |text| text.include?("Continue the original request?") }
  end

  def test_an_uncertain_local_send_is_preserved_while_the_addressed_question_is_delivered
    @client.failure = Rho::IngressTelegram::Client::Unavailable.new(reason: "lost_response", ambiguous: true)
    id, = publish_local_notice
    receipt = @state.read.fetch("deliveries").fetch("question:#{id}")
    assert_equal "uncertain", receipt.fetch("status")

    @runtime = runtime
    publish_addressed_question
    receive(telegram_message(2, "/answer #{id} Continue"))
    @bridge.pending_rows = []
    @now += Rho::IngressTelegram::Runtime::RECONCILE_INTERVAL
    @runtime.tick

    assert_equal receipt, @state.read.fetch("deliveries").fetch("question:#{id}")
    assert_equal 1, sent_texts.count(local_notice.fetch("question")), "the ambiguous notice is never sent again"
    assert_equal 1, sent_texts.count { |text| text.include?("Continue the original request?") }
    assert_equal [["answer", "loop-1", "ask-1", "Continue", "workspace-home"]], @bridge.decisions
    assert @state.read.fetch("questions").fetch(id).fetch("resolved")
    assert_equal 2, @state.read.fetch("deliveries").values.count { |entry| entry["question_id"] == id }
    assert_includes @state.status.fetch("delivery_issues").map { |entry| entry.fetch("key") }, "question:#{id}"
  end

  def test_a_sending_notice_left_at_restart_is_not_retried_when_the_question_arrives
    @state.change { |document| document["retry_at"] = @now + 5 }
    id, = publish_local_notice
    @state.change { |document| document.fetch("deliveries").fetch("question:#{id}")["status"] = "sending" }
    @runtime = runtime
    assert_equal "uncertain", @state.read.fetch("deliveries").fetch("question:#{id}").fetch("status")

    publish_addressed_question

    assert_equal "uncertain", @state.read.fetch("deliveries").fetch("question:#{id}").fetch("status")
    refute_includes sent_texts, local_notice.fetch("question")
    assert_equal 1, sent_texts.count { |text| text.include?("Continue the original request?") }
  end

  def test_a_refused_local_notice_keeps_its_receipt_when_the_question_arrives
    @client.failure = Rho::IngressTelegram::Client::Refused.new(code: 400, description: "notice refused")
    id, = publish_local_notice
    receipt = @state.read.fetch("deliveries").fetch("question:#{id}")
    assert_equal "refused", receipt.fetch("status")

    publish_addressed_question

    assert_equal receipt, @state.read.fetch("deliveries").fetch("question:#{id}")
    assert_equal 1, sent_texts.count(local_notice.fetch("question"))
    assert_equal 1, sent_texts.count { |text| text.include?("Continue the original request?") }
  end

  def test_a_local_notice_becomes_an_actionable_approval_for_the_same_task
    id, local = publish_local_notice
    @bridge.pending_rows = [addressed_question.merge("kind" => "approval", "question" => "Approve the original tool call?")]
    @now += Rho::IngressTelegram::Runtime::RECONCILE_INTERVAL
    @runtime.tick

    question = @state.read.fetch("questions").fetch(id)
    assert_equal "approval", question.fetch("kind")
    assert_includes question.fetch("message_ids"), local.fetch("message_ids").first
    sent = @client.calls.find { |method, fields| method == "sendMessage" && fields[:text].to_s.include?("Approve the original tool call?") }
    assert_equal ["approve:#{id}", "deny:#{id}"], sent.last.fetch(:reply_markup).fetch("inline_keyboard").flatten.map { |button| button.fetch("callback_data") }
    receive(telegram_message(2, "/approve #{id}"))
    assert_equal [["approve", "loop-1", "ask-1", "workspace-home"]], @bridge.decisions
  end

  private

    def publish_local_notice
      receive(telegram_message(1, "start"))
      @bridge.pending_rows = [local_notice]
      @runtime.tick
      @state.read.fetch("questions").first
    end

    def publish_addressed_question
      @bridge.pending_rows = [addressed_question]
      @now += Rho::IngressTelegram::Runtime::RECONCILE_INTERVAL
      @runtime.tick
    end

    def local_notice
      { "run_public_id" => "loop-1", "task_key" => "ask-1", "kind" => "local",
        "question" => "Use the child agent's CLI to handle this request." }
    end

    def addressed_question
      local_notice.merge("kind" => "ask", "question" => "Continue the original request?", "workspace_public_id" => "workspace-home")
    end

    def sent_texts
      @client.calls.filter_map { |method, parameters| parameters[:text] if method == "sendMessage" }
    end
end
