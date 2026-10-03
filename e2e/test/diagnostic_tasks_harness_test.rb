require "test_helper"
require "open3"

class DiagnosticTasksHarnessTest < Minitest::Test
  def test_paid_batches_require_opt_in_before_starting_a_child
    %w[live_exit live_sweep[until]].each do |task|
      output, status = run_task(task, "E2E_LIVE" => nil)

      refute status.success?, task
      assert_includes output, "set E2E_LIVE=1", task
      refute_includes output, "unexpected child launch", task
    end
  end

  def test_paid_batches_refuse_ci_before_starting_a_child
    %w[live_exit live_sweep[until]].each do |task|
      output, status = run_task(task, "E2E_LIVE" => "1", "CI" => "true")

      refute status.success?, task
      assert_includes output, "local-development only", task
      refute_includes output, "unexpected child launch", task
    end
  end

  def test_explicit_opt_in_reaches_the_child_launcher_with_the_default_development_environment
    %w[live_exit live_sweep[until]].each do |task|
      output, status = run_task(task, "E2E_LIVE" => "1", "RAILS_ENV" => nil)

      refute status.success?, task
      assert_equal "unexpected child launch\n", output, task
    end
  end

  private

    def run_task(task, env)
      script = <<~RUBY
        require "rake"
        def system(*) = abort("unexpected child launch")
        Rake.application.run(ARGV)
      RUBY
      defaults = { "E2E_LIVE_MODEL" => "fixture/floor", "E2E_SWEEP_MODELS" => "fixture/floor",
                   "RAILS_ENV" => "development", "CI" => nil }
      Open3.capture2e(defaults.merge(env), Gem.ruby, "-I.", "-e", script, task,
        chdir: File.expand_path("..", __dir__))
    end
end
