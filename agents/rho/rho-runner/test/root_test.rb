require "test_helper"

# THE PROGRAM'S ROOT: the directory this gem is loaded from — a checkout in development,
# the installed gem in production — which rho's self-modification deny rules protect
# beside its own, because the toolset gem is the program too.
class RunnerRootTest < Minitest::Test
  def test_root_is_the_directory_the_gem_is_loaded_from
    root = Rho::Runner.root

    assert_equal File.expand_path("..", __dir__), root
    assert File.file?(File.join(root, "lib", "rho", "runner.rb"))
    assert File.file?(File.join(root, "rho-runner.gemspec"))
  end
end
