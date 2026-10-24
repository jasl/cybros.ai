require "test_helper"
require "rake"

class ModelCatalogTaskTest < ActiveSupport::TestCase
  setup do
    @previous_rake = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    Rake::Task.define_task("db:prepare")
    load Rails.root.join("lib/tasks/model_catalog.rake")
  end

  teardown do
    Rake.application = @previous_rake
  end

  test "installation preparation retains existing configured lanes and repeat capture is inert" do
    policy = ModelProviderConfig.find_or_initialize_by(account: accounts(:cybros), provider_id: "test_api")
    policy.update!(enabled: true, model_overrides: ModelProviderConfig.empty_overrides)

    Rake::Task["db:prepare"].invoke

    saved = policy.reload.retained_catalog
    assert_equal ModelCatalog.current.providers.fetch("test_api"), saved.fetch("provider")
    assert_equal ModelCatalog.current.models.fetch("test_api/text"), saved.fetch("models").fetch("test_api/text")
    version = policy.lock_version

    Rake::Task["model_catalog:retain"].reenable
    Rake::Task["model_catalog:retain"].invoke
    assert_equal version, policy.reload.lock_version
  end
end
