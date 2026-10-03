require "test_helper"

class PackageTest < Minitest::Test
  include WebuiTest

  def test_an_extracted_gem_registers_its_own_files_without_an_external_runtime
    Dir.mktmpdir("rho-webui-package") do |directory|
      archive = File.join(directory, "rho-webui.gem")
      spec = Gem::Specification.load(File.join(ROOT, "rho-webui.gemspec"))
      capture_io do
        Dir.chdir(ROOT) { Gem::Package.build(spec, false, false, archive) }
      end
      unpacked = File.join(directory, "unpacked")
      Gem::Package.new(archive).extract_files(unpacked)

      script = <<~RUBY
        require "rho/webui"
        api = Object.new
        api.define_singleton_method(:register_webui) { |root:| print root }
        Rho::Webui.register(api)
      RUBY
      output, error, status = Open3.capture3(
        { "PATH" => "", "RUBYOPT" => nil, "RUBYLIB" => nil },
        RbConfig.ruby, "--disable-gems", "-I", File.join(unpacked, "lib"), "-e", script,
        chdir: directory
      )
      assert_predicate status, :success?, error
      assert_equal "", error
      assert_equal File.realpath(File.join(unpacked, "webui")), output

      %w[index.html console.css console.js api.js views.js markdown.js controls.js lifecycle.js scheduled_jobs.js].each do |name|
        assert_equal File.binread(File.join(ROOT, "webui", name)), File.binread(File.join(output, name))
      end
      assert File.file?(File.join(unpacked, "LICENSE.txt"))
      refute File.exist?(File.join(unpacked, "test"))
      refute File.exist?(File.join(unpacked, "Gemfile"))
    end
  end
end
