require_relative "test_helper"

class RetentionTest < OperatorTest
  def test_retention_can_be_read_changed_and_disabled_through_the_platform_api
    saved_session
    [90, 30, nil].each { |days| @transport.answer(200, { "account" => { "execution_details_retention_days" => days } }) }

    assert_equal 0, run_cli("account", "retention")
    assert_equal 90, output.fetch("account").fetch("execution_details_retention_days")
    assert_equal 0, run_cli("account", "retention", "30")
    assert_equal 30, output.fetch("account").fetch("execution_details_retention_days")
    assert_equal 0, run_cli("account", "retention", "off")
    assert_nil output.fetch("account").fetch("execution_details_retention_days")
    assert_equal [:get, :patch, :patch], @transport.requests.map { |request| request.fetch(:method) }
    assert_equal ["/api/v1/admin/account/retention"] * 3, @transport.requests.map { |request| request.fetch(:path) }
    assert_equal({ "account" => { "execution_details_retention_days" => nil } }, @transport.requests.last.fetch(:body))
  end

  def test_invalid_retention_arguments_make_no_request
    saved_session
    ["0", "-1", "1.5", "days"].each do |invalid|
      assert_equal 2, run_cli("account", "retention", invalid)
    end
    assert_equal 2, run_cli("account", "retention", "30", "60")
    assert_empty @transport.requests
  end

  def test_a_refused_policy_write_is_reported_without_retry
    saved_session
    @transport.answer(403, { "error" => { "code" => "administrator_required" } })
    assert_equal 1, run_cli("account", "retention", "off")
    assert_includes @error.string, "administrator_required"
    assert_equal 1, @transport.requests.length
  end
end
