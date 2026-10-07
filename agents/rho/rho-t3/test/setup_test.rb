require_relative "test_helper"
require "stringio"

class SetupTest < Minitest::Test
  include T3Test
  Cli = Data.define(:core, :out)

  class Projects
    attr_reader :rows, :created
    attr_accessor :uncertain
    def initialize
      @rows, @created = [], []
    end
    def projects = rows
    def create_project(path:, title:)
      row = { "id" => "native-project", "title" => title, "workspaceRoot" => path }
      @created << row
      @rows << row
      raise Rho::T3::Uncertain, "lost response" if uncertain

      row
    end
  end

  def test_create_reuses_existing_path_and_reconciles_an_uncertain_response
    [false, true].each do |uncertain|
      native = Projects.new
      native.uncertain = uncertain
      saved = []
      core = Object.new
      core.define_singleton_method(:configure_extension) { |id, operations:| saved << [id, operations] }
      cli = Cli.new(core: core, out: StringIO.new)
      command = Rho::T3::Setup.new(cli: cli, settings: settings, native: nil, bridge: native)
      2.times { command.create_project("/work/project") }
      assert_equal 1, native.created.length
      assert_equal 2, saved.length
      assert_equal ["project_id"], saved.last.last.first.fetch("path")
      assert_equal "native-project", saved.last.last.first.fetch("value")
    end
  end

  def test_local_status_does_not_read_the_native_service
    Dir.mktmpdir do |root|
      native = Rho::T3::NativeEnvironment.new(root: root, work_root: File.join(root, "work"))
      cli = Cli.new(core: nil, out: StringIO.new)
      command = Rho::T3::Setup.new(cli: cli, settings: settings(server: "local", project_id: ""), native: native, bridge: Object.new)
      status = command.status
      refute status.fetch("configured")
      assert_equal root, status.fetch("native_configuration")
    end
  end
end
