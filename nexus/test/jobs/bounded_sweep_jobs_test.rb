require "test_helper"

# The sweep shells stay level-triggered and bounded: an idle pass sleeps
# until the next recurring wake, while a full scanned window schedules
# exactly one continuation carrying the walk's cursor. A recurring run
# starts cursor-less and revisits everything a window ever stepped past.
class BoundedSweepJobsTest < ActiveJob::TestCase
  include ActiveSupport::Testing::ConstantStubbing

  ALL_JOBS = [
    Sessions::ReapJob,
    MemberRecoveryAuthorizations::ReapJob,
    DeviceAuthorizations::ReapJob,
    RefreshTokenFamilies::ConvergeJob,
    AccessTokens::ConvergeJob,
    RefreshTokens::ConvergeJob,
    Users::ConvergeJob,
    TaskExecutors::ConvergeJob,
  ].freeze

  test "idle sweeps enqueue no continuation" do
    ALL_JOBS.each do |job_class|
      assert_no_enqueued_jobs(only: job_class) do
        job_class.perform_now
      end
    end
  end

  test "a full session window enqueues one continuation carrying the fenced cursor" do
    identity = identities(:member)
    sessions = 2.times.map { create_browser_session(identity) }

    stub_const(Sessions::ReapJob, :BATCH, 1) do
      assert_enqueued_jobs 1, only: Sessions::ReapJob do
        assert_enqueued_with(job: Sessions::ReapJob, args: [sessions.first.id]) do
          Sessions::ReapJob.perform_now
        end
      end
    end
  end

  test "a full marker window enqueues one continuation carrying its cursor" do
    member = create_agent_member(
      steward: users(:member), agent_identifier: "sweep-job-probe"
    )
    executor = member.task_executors.create!(
      account: member.account, executor_kind: :agent_application,
      display_name: "Sweep probe"
    )
    family = RefreshTokenFamily.create!(
      account: member.account, user: member, access_token_name: "Probe",
      task_executor: executor, credential_epoch: executor.credential_epoch,
      user_authority_generation: member.authority_generation,
      last_used_at: Time.current
    )

    assert_operator family.id, :>, 0
    first_window_id = RefreshTokenFamily.order(:id).first.id
    stub_const(RefreshTokenFamilies::ConvergeJob, :BATCH, 1) do
      assert_enqueued_jobs 1, only: RefreshTokenFamilies::ConvergeJob do
        assert_enqueued_with(
          job: RefreshTokenFamilies::ConvergeJob,
          args: [first_window_id, nil]
        ) do
          RefreshTokenFamilies::ConvergeJob.perform_now
        end
      end
    end
  end

  test "a full agent-profile window enqueues one continuation carrying its cursor" do
    profile = create_agent_member(
      steward: users(:member), agent_identifier: "converge-job-probe"
    )

    assert_operator profile.id, :>, 0
    first_window_id = User.where(kind: :agent).order(:id).first.id
    stub_const(Users::ConvergeJob, :BATCH, 1) do
      assert_enqueued_jobs 1, only: Users::ConvergeJob do
        assert_enqueued_with(job: Users::ConvergeJob, args: [first_window_id]) do
          Users::ConvergeJob.perform_now
        end
      end
    end
  end

  test "a full recovery batch enqueues one continuation" do
    identity = identities(:member)
    2.times do |index|
      MemberRecoveryAuthorization.create!(
        account: identity.user.account, identity: identity, user: identity.user,
        generation: identity.credential_recovery_generation,
        lookup_id: SecureRandom.base58(24), secret_digest: "probe",
        expires_at: 1.day.from_now, consumed_at: 31.days.ago + index.minutes
      )
    end

    stub_const(MemberRecoveryAuthorizations::ReapJob, :BATCH, 1) do
      assert_enqueued_jobs 1, only: MemberRecoveryAuthorizations::ReapJob do
        assert_enqueued_with(job: MemberRecoveryAuthorizations::ReapJob, args: []) do
          MemberRecoveryAuthorizations::ReapJob.perform_now
        end
      end
    end
  end

  test "a full access-token window enqueues one continuation carrying its cursor" do
    parts = AccessToken::DIGESTED.mint_parts
    token = users(:member).access_tokens.create!(
      credential_plane: :member, name: "Sweep probe", source: :personal,
      lookup_id: parts.lookup_id, secret_digest: parts.digest,
      expires_at: AccessToken::OAUTH_TTL.from_now,
      user_authority_generation: users(:member).authority_generation
    )
    first_window_id = AccessToken.order(:id).first.id
    assert_operator token.id, :>=, first_window_id

    stub_const(AccessTokens::ConvergeJob, :BATCH, 1) do
      assert_enqueued_jobs 1, only: AccessTokens::ConvergeJob do
        assert_enqueued_with(job: AccessTokens::ConvergeJob, args: [first_window_id]) do
          AccessTokens::ConvergeJob.perform_now
        end
      end
    end
  end

  test "access-token continuation carries a parked marker cursor explicitly" do
    result = Sweeps::Pass.new(counts: { marked: 0, reaped: 1, scanned: 1 }, cursor: nil, more: true)

    AccessToken.stub(:converge, result) do
      assert_enqueued_with(
        job: AccessTokens::ConvergeJob,
        args: [nil]
      ) do
        AccessTokens::ConvergeJob.perform_now
      end
    end
  end

  test "a full refresh-token reap window enqueues one continuation carrying the lapse cursor" do
    member = create_agent_member(
      steward: users(:member), agent_identifier: "rt-sweep-probe"
    )
    executor = member.task_executors.create!(
      account: member.account, executor_kind: :agent_application,
      display_name: "RT probe"
    )
    lapsed_at = (RefreshTokenFamily::INACTIVITY_WINDOW +
      RefreshToken::POST_LAPSE_RETENTION + 1.day).ago
    2.times do |index|
      RefreshTokenFamily.create!(
        account: member.account, user: member, access_token_name: "Lapsed #{index}",
        task_executor: executor, credential_epoch: executor.credential_epoch + index,
        user_authority_generation: member.authority_generation,
        last_used_at: lapsed_at + index.minutes
      )
    end
    expected = RefreshTokenFamily.where(last_used_at: ..lapsed_at + 2.minutes)
      .order(:last_used_at, :id).first

    stub_const(RefreshTokens::ConvergeJob, :BATCH, 1) do
      assert_enqueued_jobs 1, only: RefreshTokens::ConvergeJob do
        assert_enqueued_with(
          job: RefreshTokens::ConvergeJob,
          args: [[expected.last_used_at.iso8601(6), expected.id]]
        ) do
          RefreshTokens::ConvergeJob.perform_now
        end
      end
    end
  end

  test "a full executor window enqueues one continuation carrying its cursor" do
    first_window_id = TaskExecutor.where(status: :active).order(:id).first.id

    stub_const(TaskExecutors::ConvergeJob, :BATCH, 1) do
      assert_enqueued_jobs 1, only: TaskExecutors::ConvergeJob do
        assert_enqueued_with(
          job: TaskExecutors::ConvergeJob,
          args: [first_window_id, 0]
        ) do
          TaskExecutors::ConvergeJob.perform_now
        end
      end
    end
  end

  test "every sweep entry is wired through its job class" do
    production = recurring_schedule

    {
      "reap_dead_sessions" => Sessions::ReapJob,
      "reap_member_recovery_authorizations" => MemberRecoveryAuthorizations::ReapJob,
      "reap_expired_device_authorizations" => DeviceAuthorizations::ReapJob,
      "converge_refresh_token_families" => RefreshTokenFamilies::ConvergeJob,
      "converge_access_tokens" => AccessTokens::ConvergeJob,
      "converge_refresh_tokens" => RefreshTokens::ConvergeJob,
      "converge_users" => Users::ConvergeJob,
      "converge_task_executors" => TaskExecutors::ConvergeJob,
    }.each do |entry, job_class|
      assert_equal job_class.name, production.dig(entry, "class"), entry
    end
  end
end
