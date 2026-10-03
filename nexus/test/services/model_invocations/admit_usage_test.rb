require "test_helper"

# The admission seam's attempt writer, after the course correction's Stage 1:
# admission holds nothing, so what this proves is what admission CREATES —
# the ordinal, the deadline whose clock starts here, the shape, and both
# halves of the start fence frozen where they were true.
class ModelInvocations::AdmitUsageTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
  end

  test "admission stamps the execution deadline on every shape" do
    %w[dev/mock-text dev/mock-unmetered].each do |model|
      result = admit(invocation_for(model))
      attempt = result.attempt

      assert_not_nil attempt.deadline_at, model
      assert_in_delta attempt.created_at + SimpleInference::ApiFormat::WORKLOAD_DEADLINE_SECONDS.fetch("text_generation"),
        attempt.deadline_at, 2.seconds, model
    end
  end

  test "the three shapes admit without holding anything" do
    @account.update!(cost_unit: "USD")
    shapes = {
      "dev/mock-text" => "admitted_free",
      "dev/mock-unmetered" => "unmetered",
      DevModelLane::PRICED_TEXT_MODEL => "priced",
    }

    shapes.each do |model, shape|
      attempt = admit(invocation_for(model)).attempt
      assert_equal shape, attempt.admission_shape, model
      assert_equal "prepared", attempt.status, model
    end
  end

  # The fence, frozen at admission — a value living only in the queue message
  # cannot be reconstructed by the rediscovery scan.
  test "the frozen principals ride the attempt" do
    attempt = admit(invocation_for("dev/mock-text")).attempt

    assert_equal @human.public_id, attempt.consumer_public_id
    assert_equal @human.public_id, attempt.payer_public_id
  end

  private

    def admit(invocation, ordinal: 1)
      quote = ModelInvocations::AdmissionCandidate.call(invocation: invocation)
      raise "quote refused: #{quote.refusal.inspect}" unless quote.accepted?

      ApplicationRecord.transaction do
        PrincipalLocks.descend(@human)
        invocation.lock!
        ModelInvocations::AdmitUsage.call(
          invocation: invocation, quote: quote, consumer: @human, payer: @human,
          ordinal: ordinal
        )
      end
    end

    def invocation_for(model)
      selection = DevModelLane.selection(
        workload: "text_generation", account: @account, model: model
      )
      one_shot = OneShot.create!(
        account: @account, workspace: workspaces(:shared), creating_user: @human,
        workload: selection.workload
      )
      DevModelLane.create_invocation!(one_shot: one_shot, selection: selection)
    end
end
