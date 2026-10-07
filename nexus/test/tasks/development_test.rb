require "test_helper"
require "rake"

class DevelopmentTaskTest < ActiveSupport::TestCase
  setup do
    @previous_rake = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load Rails.root.join("lib/tasks/development.rake")
  end

  teardown do
    Rake.application = @previous_rake
  end

  test "the explicit development shortcut founds an empty installation without choosing providers or cost unit" do
    Account.destroy_all
    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("development")) do
      output = capture_io { Rake::Task["development:seed"].invoke }.first
      assert_includes output, "/admin/model_providers"
    end
    account = Account.sole
    assert_equal "admin@example.com", account.owner.identity.email
    assert_nil account.cost_unit
    assert_empty ModelProviderCredential.where(account: account)
    assert_empty ModelProviderConfig.where(account: account)
  end

  test "the shortcut refuses test and production and never changes an existing development installation" do
    %w[test production development].each do |environment|
      Rake::Task["development:seed"].reenable
      assert_no_difference [-> { Account.count }, -> { Identity.count }, -> { User.count }] do
        Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new(environment)) do
          error = assert_raises(SystemExit) do
            capture_io { Rake::Task["development:seed"].invoke }
          end
          assert_not error.success?
        end
      end
    end
  end
end
