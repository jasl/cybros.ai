require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"

class PumaTest < Minitest::Test
  LOAD = <<~RUBY.freeze
    require "bundler/setup"
    require "puma"
    require "puma/configuration"
    require "concurrent/utility/processor_counter"
    require "json"
    Concurrent.define_singleton_method(:available_processor_count) { Float(ARGV.fetch(1)) }
    configuration = Puma::Configuration.new({ config_files: [ARGV.fetch(0)] }, {}, ENV)
    configuration.load
    configuration.clamp
    puts JSON.generate(%i[workers min_threads max_threads].to_h { |key| [key, configuration.options[key]] })
  RUBY

  def test_production_defaults_follow_available_cpu_with_a_cap_and_minimum
    { "32" => 4, "2" => 2, "1.5" => 1, "0.5" => 1 }.each do |cpus, workers|
      assert_equal({ "workers" => workers, "min_threads" => 1, "max_threads" => 1 }, configuration("production", cpus: cpus))
    end
  end

  def test_development_and_test_keep_single_mode_and_three_threads
    %w[development test].each do |environment|
      assert_equal({ "workers" => 0, "min_threads" => 3, "max_threads" => 3 }, configuration(environment))
    end
  end

  def test_explicit_puma_worker_and_thread_overrides_are_preserved
    { "0" => 0, "1" => 1, "7" => 7, "auto" => 8 }.each do |value, workers|
      assert_equal(
        { "workers" => workers, "min_threads" => 2, "max_threads" => 2 },
        configuration("production", { "WEB_CONCURRENCY" => value, "RAILS_MAX_THREADS" => "2" })
      )
    end
  end

  def test_empty_worker_override_uses_production_default
    assert_equal 4, configuration("production", { "WEB_CONCURRENCY" => " " }).fetch("workers")
  end

  private

    def configuration(environment, variables = {}, cpus: "8")
      variables = { "RAILS_ENV" => environment, "BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__) }.merge(variables)
      stdout, stderr, status = Open3.capture3(
        variables, RbConfig.ruby, "-e", LOAD,
        File.expand_path("../../config/puma.rb", __dir__), cpus,
        unsetenv_others: true
      )
      assert status.success?, stderr
      JSON.parse(stdout)
    end
end
