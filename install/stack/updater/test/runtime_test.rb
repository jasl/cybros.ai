require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class RuntimeTest < Minitest::Test
  def test_deployment_client_loads_without_installed_gems
    Dir.mktmpdir("updater-gems") do |gems|
      output, error, status = Open3.capture3(
        { "GEM_HOME" => gems, "GEM_PATH" => gems, "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil },
        RbConfig.ruby, "-r", File.expand_path("../updater", __dir__), "-e",
        'abort unless CybrosUpdater::Client && CybrosUpdater::CLI; puts "Deployment client loaded"',
      )

      assert status.success?, error
      assert_equal "Deployment client loaded\n", output
    end
  end
end
