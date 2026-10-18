require "minitest/autorun"
require "minitest/mock"
require "active_storage"
require "active_storage/vips"
require "active_support/testing/constant_stubbing"
require "rake"

# No Rails boot, database, storage service or native process is needed.
class UploadsTaskTest < Minitest::Test
  include ActiveSupport::Testing::ConstantStubbing

  def setup
    @previous_rake = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load File.expand_path("../../lib/tasks/uploads.rake", __dir__)
  end

  def teardown
    Rake.application = @previous_rake
  end

  def test_checks_the_configured_previewers_and_reports_the_limits
    accepted = []
    previewer = Object.new
    previewer.define_singleton_method(:accept?) do |probe|
      accepted << [probe.content_type, probe.video?]
      true
    end

    output = with_dependencies(vips: true, previewers: [previewer]) do
      capture_io { Rake::Task["uploads:check_preview_dependencies"].invoke }.first
    end

    assert_equal [["application/pdf", false], ["video/mp4", true]], accepted
    assert_includes output, "libvips: available"
    assert_includes output, "PDF previewer: available"
    assert_includes output, "Video previewer: available"
    assert_includes output, "individual files and codecs may still fail to render"
  end

  def test_unconfigured_previewers_are_missing_even_when_libvips_loads
    output = with_dependencies(vips: true, previewers: []) do
      capture_io do
        error = assert_raises(SystemExit) { Rake::Task["uploads:check_preview_dependencies"].invoke }
        refute error.success?
      end.first
    end

    assert_includes output, "libvips: available"
    assert_includes output, "PDF previewer: missing"
    assert_includes output, "Video previewer: missing"
  end

  def test_missing_libvips_exits_unsuccessfully_even_when_previewers_accept
    previewer = Object.new
    previewer.define_singleton_method(:accept?) { |_| true }
    output = with_dependencies(vips: false, previewers: [previewer]) do
      capture_io do
        error = assert_raises(SystemExit) { Rake::Task["uploads:check_preview_dependencies"].invoke }
        refute error.success?
      end.first
    end

    assert_includes output, "libvips: missing"
    assert_includes output, "PDF previewer: available"
    assert_includes output, "Video previewer: available"
  end

  private

    def with_dependencies(vips:, previewers:)
      stub_const(ActiveStorage, :VIPS_AVAILABLE, vips) do
        ActiveStorage.stub(:previewers, previewers) do
          yield
        end
      end
    end
end
