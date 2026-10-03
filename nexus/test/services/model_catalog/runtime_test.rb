require "test_helper"
require "tmpdir"

# The process-local snapshot publisher. Boot compiles the whole candidate or
# fails fast, then exposes one immutable snapshot to every consumer.
class ModelCatalog::RuntimeTest < ActiveSupport::TestCase
  def with_catalog_root
    Dir.mktmpdir do |root|
      %w[90_dev.yml 92_test_api.yml].each do |name|
        FileUtils.cp(Rails.root.join("test/support/model_catalog", name), root)
      end
      yield root
    end
  end

  def write_broken(root)
    File.write(File.join(root, "92_test_api.yml"), "schema_version: [unclosed")
  end

  test "boot publishes a frozen snapshot" do
    with_catalog_root do |root|
      runtime = ModelCatalog::Runtime.new(root: root)
      runtime.boot

      snapshot = runtime.current
      assert_predicate snapshot, :frozen?
      # Structure only: what a selector CONTAINS is catalog data and lives in
      # the projection test, not this runtime test. There is no shipped
      # selector left to name here — the repository ships none — so what this
      # asserts is the shape the runtime publishes.
      assert_predicate snapshot.selectors, :frozen?
      assert_predicate runtime, :ready?
    end
  end

  test "boot on a bad tree fails fast and the runtime refuses reads" do
    with_catalog_root do |root|
      write_broken(root)
      runtime = ModelCatalog::Runtime.new(root: root)

      assert_raises(ModelCatalog::CompileError) { runtime.boot }
      refute_predicate runtime, :ready?
      assert_raises(ModelCatalog::Unavailable) { runtime.current }
    end
  end

  # A CANDIDATE THAT LOSES A ROUTED-TO LANE REFUSES WHOLE. The selector is
  # written by this test because the repository ships none: routing policy is a
  # deployment decision now, so the deployment is who can lose a candidate out
  # from under a selector — and the compiler still has to catch it.
  test "boot refuses a candidate missing a lane a selector routes to" do
    with_catalog_root do |root|
      File.write(File.join(root, "80_routes.yml"), <<~YAML)
        schema_version: #{ModelCatalog::FileBase::SCHEMA_VERSION}
        selectors:
          routed:
            - test_api/text
      YAML
      FileUtils.rm(File.join(root, "92_test_api.yml"))
      runtime = ModelCatalog::Runtime.new(root: root)

      error = assert_raises(ModelCatalog::CompileError) { runtime.boot }
      assert_includes error.message, "test_api/text"
      refute_predicate runtime, :ready?
    end

    # Dropping an unrouted provider lane is an ordinary catalog edit.
    with_catalog_root do |root|
      FileUtils.rm(File.join(root, "92_test_api.yml"))
      runtime = ModelCatalog::Runtime.new(root: root)

      runtime.boot
      assert_predicate runtime, :ready?
      assert_not runtime.current.models.key?("test_api/text")
    end
  end

  test "the application boots a global runtime over the shipped tree" do
    assert_predicate ModelCatalog, :ready?
    assert_kind_of ModelCatalog::Snapshot, ModelCatalog.current
  end
end
