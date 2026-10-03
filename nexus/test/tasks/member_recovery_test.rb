require "test_helper"
# Rake reaches a test process only through railties' prepare task, which Rails
# skips whenever the argv names a path or -n — so without this every focused
# invocation (including the file:LINE line minitest prints on failure) died on
# `uninitialized constant Rake::Task` before running anything.
require "rake"

class MemberRecoveryTaskTest < ActiveSupport::TestCase
  setup do
    @previous_rake = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load Rails.root.join("lib/tasks/member_recovery.rake")
  end

  teardown do
    Rake.application = @previous_rake
  end

  test "mint prints the one-time consume path and fences the identity" do
    output = capture_io do
      Rake::Task["member_recovery:mint"].invoke("member@example.com")
    end.first

    assert_match %r{/passwords/edit\?token=rc-cybros-}, output
    assert identities(:member).reload.local_recovery_pending?
    # The raw secret is printed exactly once and never persisted.
    secret = output[/token=(rc-cybros-\S+)/, 1]
    assert MemberRecoveryAuthorization.find_by_secret(secret).present?
  end

  test "mint aborts for an unknown or ineligible target" do
    error = assert_raises(SystemExit) do
      capture_io { Rake::Task["member_recovery:mint"].invoke("nobody@example.com") }
    end
    assert_not error.success?
  end

  test "status reports facts without any secret" do
    MemberRecoveryAuthorizations::Issue.call(user: users(:member))

    output = capture_io do
      Rake::Task["member_recovery:status"].invoke("member@example.com")
    end.first

    assert_match(/Fence pending: true/, output)
    assert_match(/generation 1/, output)
    assert_no_match(/rc-cybros-/, output)
  end
end
