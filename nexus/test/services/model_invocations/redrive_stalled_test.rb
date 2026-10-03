require "test_helper"

# The rediscovery three comments in this tree already promised.
#
# Until it existed, `RunJob` had exactly one enqueue site and both frontier
# sweeps terminalized rather than re-drove — so a wake lost between the
# admission commit and the queue meant the Attempt sat prepared until its
# deadline and was reaped `timed_out`. The work was lost, and the sentence
# saying it could not be was in the file that lost it.
class ModelInvocations::RedriveStalledTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    DevModelLane.ensure_enabled!(@account)
  end

  test "an attempt whose wake was lost is asked again" do
    attempt = stalled_attempt

    assert_enqueued_with(job: ModelInvocations::RunJob) do
      assert_equal 1, ModelInvocations::RedriveStalled.call[:redriven]
    end
  end

  # The durable Attempt identity is the only job argument a rediscovery needs;
  # send-time deployment configuration is read by the executor.
  test "the re-drive carries the durable attempt identity" do
    attempt = stalled_attempt

    ModelInvocations::RedriveStalled.call

    enqueued = enqueued_jobs.find { |job| job["job_class"] == "ModelInvocations::RunJob" }
    assert_equal [attempt.public_id], enqueued.fetch("arguments")
  end

  # A freshly admitted attempt is ordinary, not stalled: re-driving it would
  # race the wake this exists to replace and double every send's enqueue.
  test "work whose wake is still in flight is left alone" do
    admitted_attempt

    assert_equal 0, ModelInvocations::RedriveStalled.call[:redriven]
  end

  # Two owners already have these rows, and answering over them is how the
  # sweep and the converger came to disagree about one event in the first
  # place.
  test "it re-drives nothing another owner owns" do
    expired = stalled_attempt
    expired.update!(deadline_at: 1.minute.ago)
    cut = stalled_attempt
    cut.model_invocation.update!(status: "canceled", terminal_at: Time.current)

    assert_equal 0, ModelInvocations::RedriveStalled.call[:redriven]
  end

  # A second pass is the first pass: nothing is written, so nothing converges
  # and the same row is offered again until a host actually claims it.
  test "asking twice writes nothing either time" do
    attempt = stalled_attempt

    ModelInvocations::RedriveStalled.call
    assert_equal 1, ModelInvocations::RedriveStalled.call[:redriven]
    assert_equal "prepared", attempt.reload.status
    assert_nil attempt.provider_started_at
  end

  test "a stalled batch loads attempts and parents once" do
    3.times { stalled_attempt }
    queries = []
    subscriber = lambda do |*, payload|
      sql = payload.fetch(:sql)
      queries << sql if sql.include?('"model_invocation_attempts"') ||
        sql.include?('"model_invocations"')
    end

    result = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      ModelInvocations::RedriveStalled.call
    end

    assert_equal 3, result[:redriven]
    assert_equal 1, queries.count { _1.include?('"model_invocation_attempts"') }
    assert_equal 1, queries.count { _1.include?('"model_invocations"') }
  end

  test "a stalled batch enqueues every attempt with one runner notification" do
    2.times { stalled_attempt }
    notifications = 0

    result = ModelInvocations::Wake.stub(:notify_runner_after_commit, -> { notifications += 1 }) do
      ModelInvocations::RedriveStalled.call
    end

    assert_equal 2, result[:redriven]
    assert_equal 2, enqueued_jobs.count { _1["job_class"] == "ModelInvocations::RunJob" }
    assert_equal 1, notifications
  end

  # The recurring floor: a full batch schedules exactly one continuation
  # carrying its cursor, and a short one schedules nothing.
  test "the job pages its keyset and stops when the frontier is dry" do
    attempt = stalled_attempt

    assert_enqueued_with(job: ModelInvocations::RedriveStalledJob, args: [attempt.id]) do
      ModelInvocations::RedriveStalledJob.perform_now(0, budget: 1)
    end

    assert_no_enqueued_jobs(only: ModelInvocations::RedriveStalledJob) do
      ModelInvocations::RedriveStalledJob.perform_now(attempt.id, budget: 1)
    end
  end

  # THE GRACE HAS TO LEAVE A WINDOW ON THE SHORTEST LANE. The frontier needs
  # `created_at <= now - GRACE` AND `deadline_at >= now`, and an Attempt's
  # deadline is stamped at admission as `created_at + the lane's total
  # deadline` — so a GRACE equal to that total makes the window a single
  # instant. It was five minutes, and the three embedding profiles have a
  # 300-second deadline: their lost wakes were never re-driven, they were
  # reaped `timed_out`, which is the outcome this class exists to prevent.
  test "the grace leaves a redrive window on every shipped lane" do
    shortest = nil
    DevModelLane.each_catalog_profile do |profile|
      seconds = profile.total_execution_deadline_seconds
      shortest = [shortest, seconds].compact.min
    end

    assert_operator ModelInvocations::RedriveStalled::GRACE.to_i, :<, shortest,
      "a lane whose whole deadline is inside the grace can never be re-driven"
  end

  private

    def stalled_attempt
      attempt = admitted_attempt
      attempt.update_columns(created_at: (ModelInvocations::RedriveStalled::GRACE + 1.minute).ago)
      attempt
    end

    def admitted_attempt
      selection = DevModelLane.selection(workload: "text_generation", account: @account)
      one_shot = OneShot.create!(
        account: @account, workspace: workspaces(:shared), creating_user: users(:member),
        workload: selection.workload
      )
      body = ContentBodies::Replace.call(
        owner: one_shot, role: OneShots::Create::BODY_ROLE,
        entries: Nexus::InputEntries.for("say hi"), seal: true
      )
      raise "input refused: #{body.refusal.inspect}" unless body.accepted?

      invocation = DevModelLane.create_invocation!(one_shot: one_shot, selection: selection)
      ModelInvocations::AdmitQueuedWork.call
      clear_enqueued_jobs
      invocation.attempts.sole
    end
end
