require "test_helper"

class DeviceAuthorizations::ReapJobTest < ActiveJob::TestCase
  include ActiveSupport::Testing::ConstantStubbing

  test "a full batch schedules one cursorless continuation" do
    authorizations = 2.times.map { issue_authorization }
    DeviceAuthorization.where(id: authorizations.map(&:id))
      .update_all(expires_at: 1.minute.ago)

    stub_const(DeviceAuthorizations::ReapJob, :BATCH, 2) do
      assert_enqueued_jobs 1, only: DeviceAuthorizations::ReapJob do
        assert_enqueued_with(job: DeviceAuthorizations::ReapJob, args: []) do
          DeviceAuthorizations::ReapJob.perform_now
        end
      end
    end
  end

  test "an idle pass schedules no continuation" do
    assert_no_enqueued_jobs(only: DeviceAuthorizations::ReapJob) do
      DeviceAuthorizations::ReapJob.perform_now
    end
  end

  test "the recurring entry starts the shallow job without cursor state" do
    entry = recurring_schedule.fetch("reap_expired_device_authorizations")

    assert_equal DeviceAuthorizations::ReapJob.name, entry.fetch("class")
    assert_not entry.key?("args")
    assert_equal "20,50 * * * *", entry.fetch("schedule")
  end

  private

    def issue_authorization
      DeviceAuthorizations::Issue.call(
        account: accounts(:cybros),
        agent_identifier: "job-reap-#{SecureRandom.hex(4)}",
        agent_display_name: "Job reap",
        requested_executor_display_name: "Job executor"
      ).authorization
    end
end
