require "test_helper"

class DeviceAuthorizations::IssueTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
  end

  # An Agent connection's kind is its branch's: the machine kind column stays NULL on it (the kind
  # is named on branch B alone).
  test "issues a digest-only Agent authorization naming no machine kind" do
    result = issue_agent

    assert result.device_code.start_with?("dc-cybros-v1-")
    authorization = result.authorization
    assert_equal 8, authorization.user_code.length
    assert authorization.user_code.chars.all? { |character|
      DeviceAuthorization::USER_CODE_ALPHABET.include?(character)
    }
    assert_match(/\A[A-Z]{4}-[A-Z]{4}\z/, authorization.formatted_user_code)
    assert_equal 5, authorization.interval
    assert authorization.expires_at > 14.minutes.from_now
    assert_no_match(
      /#{Regexp.escape(result.device_code.split(".").last)}/,
      authorization.attributes.values.join(" ")
    )
    assert_nil authorization.requested_executor_kind
  end

  test "a machine authorization carries the requested kind, the runner's by default" do
    runner = DeviceAuthorizations::Issue.call(
      account: @account, runner_identifier: "box", runner_display_name: "Box"
    ).authorization
    provider = DeviceAuthorizations::Issue.call(
      account: @account, runner_identifier: "box-2", runner_display_name: "Box",
      requested_executor_kind: "tools_provider"
    ).authorization

    assert_equal "runner", runner.requested_executor_kind
    assert_equal "tools_provider", provider.requested_executor_kind
    assert_predicate provider, :tools_provider_connection?
    assert_raises ActiveRecord::ReadonlyAttributeError do
      provider.update!(requested_executor_kind: "runner")
    end
  end

  test "a live user-code collision retries generation instead of failing" do
    first = issue_agent.authorization
    replacement_code = "BCDFGHJK"
    generated_codes = [first.user_code, replacement_code]

    DeviceAuthorizations::Issue.stub(:generate_user_code, -> { generated_codes.shift || raise("exhausted") }) do
      second = issue_agent.authorization
      assert_equal replacement_code, second.user_code
    end
  end

  private

    def issue_agent
      DeviceAuthorizations::Issue.call(
        account: @account,
        agent_identifier: "install-#{SecureRandom.hex(4)}",
        agent_display_name: "Helper",
        requested_executor_display_name: "Helper app"
      )
    end
end
