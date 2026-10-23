require "minitest/autorun"
require "open3"
require "rbconfig"

class LazyBootTest < Minitest::Test
  def test_rake_environment_boots_without_premature_framework_load_hooks
    script = <<~RUBY
      require_relative "config/application"
      Rails.application.config.action_on_early_load_hook = :raise
      Rails.application.load_tasks
      Rake::Task["environment"].invoke
      abort "eager loading enabled" if Rails.application.config.eager_load
      abort "application not initialized" unless Rails.application.initialized?
    RUBY

    stdout, stderr, status = Open3.capture3(
      { "RAILS_ENV" => "production", "SECRET_KEY_BASE_DUMMY" => "1" },
      RbConfig.ruby, "-e", script, chdir: File.expand_path("../..", __dir__)
    )
    assert status.success?, "#{stdout}\n#{stderr}"
  end
end
