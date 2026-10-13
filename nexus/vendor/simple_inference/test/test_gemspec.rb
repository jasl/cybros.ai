require "fileutils"
require "open3"
require "rbconfig"
require "test_helper"

class TestGemspec < Minitest::Test
  GEM_ROOT = File.expand_path("..", __dir__)

  def test_gemspec_loads_without_git_on_path
    script = <<~RUBY
      spec = Gem::Specification.load("simple_inference.gemspec")
      abort "failed to load simple_inference.gemspec" unless spec
      abort "missing library files" unless spec.files.include?("lib/simple_inference.rb")
      abort "gemspec should not be packaged" if spec.files.include?("simple_inference.gemspec")
      puts spec.files.length
    RUBY

    stdout, stderr, status = run_gemspec_script(script)

    message = stderr.empty? ? stdout : stderr
    assert status.success?, "expected gemspec to load without git on PATH, got: #{message}"
    assert_operator stdout.to_i, :>, 0
  end

  # Local `rake build` artifacts land in pkg/; a stale .gem riding spec.files
  # would ship a gem inside the gem. The sentinel makes the guard
  # deterministic even when pkg/ is currently empty or absent.
  def test_gemspec_never_packages_pkg_build_artifacts
    sentinel = File.join(GEM_ROOT, "pkg", "gemspec-guard-sentinel-0.0.0.gem")
    FileUtils.mkdir_p(File.dirname(sentinel))
    File.write(sentinel, "sentinel — must never appear in spec.files")

    script = <<~RUBY
      spec = Gem::Specification.load("simple_inference.gemspec")
      abort "failed to load simple_inference.gemspec" unless spec
      offenders = spec.files.grep(%r{\\Apkg/})
      abort "pkg/ build artifacts leaked into spec.files: \#{offenders.join(", ")}" unless offenders.empty?
      puts "clean"
    RUBY

    stdout, stderr, status = run_gemspec_script(script)

    message = stderr.empty? ? stdout : stderr
    assert status.success?, "expected spec.files to exclude pkg/, got: #{message}"
    assert_equal "clean", stdout.strip
  ensure
    FileUtils.rm_f(sentinel)
  end

  private

  def run_gemspec_script(script)
    Open3.capture3(
      { "PATH" => "/nonexistent" },
      RbConfig.ruby,
      "-e",
      script,
      chdir: GEM_ROOT
    )
  end
end
