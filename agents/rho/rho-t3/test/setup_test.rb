require_relative "test_helper"

class SetupTest < Minitest::Test
  include T3Test

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
      persist = ->(project:, operations:) { saved << [project, operations] }
      command = Rho::T3::Setup.new(settings: settings, native: nil, persist: persist, bridge: native)
      2.times { command.create_project("/work/project") }
      assert_equal 1, native.created.length
      assert_equal 2, saved.length
      assert_equal({ "id" => "native-project", "title" => "project", "workspaceRoot" => "/work/project" }, saved.last.first)
      assert_equal ["project_id"], saved.last.last.first.fetch("path")
      assert_equal "native-project", saved.last.last.first.fetch("value")
    end
  end

  def test_local_status_does_not_read_the_native_service
    Dir.mktmpdir do |root|
      native = Rho::T3::NativeEnvironment.new(root: root, work_root: File.join(root, "work"))
      command = Rho::T3::Setup.new(settings: settings(server: "local", project_id: ""), native: native,
        persist: ->(**) { flunk "status saves nothing" }, bridge: Object.new)
      status = command.status
      refute status.fetch("configured")
      assert_equal "saved", status.fetch("bearer")
      assert_equal root, status.fetch("native_configuration")
    end
  end

  # A local service's bearer is issued by the native program and saved; the
  # outcome, never the bearer, is the answer. A refused issuance saves nothing.
  def test_a_local_bearer_is_issued_natively_and_saved
    Dir.mktmpdir do |root|
      bin = File.join(root, "bin")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "t3"), <<~SH)
        #!/bin/sh
        [ "$1 $2 $3" = "auth session issue" ] || exit 2
        case "$*" in *--token-only*) printf 'issued-bearer\\n' ;; *) exit 2 ;; esac
      SH
      File.chmod(0o755, File.join(bin, "t3"))
      # The native program is found on the child environment's PATH, which
      # is the installation's, not this test's: a stand-in names this one.
      native = Object.new
      native.define_singleton_method(:prepare) { native }
      native.define_singleton_method(:server_root) { File.join(root, "server") }
      native.define_singleton_method(:environment) { { "PATH" => bin } }
      saved = []
      persist = ->(operations:, **facts) { saved << [facts, operations]; facts.merge("saved" => true) }
      command = Rho::T3::Setup.new(settings: settings(server: "local"), native: native, persist: persist, bridge: Object.new)
      out = StringIO.new
      answer = command.run("token", out: out)
      assert_equal({ bearer: "saved", "saved" => true }, answer)
      assert_equal [[{ bearer: "saved" }, [{ "op" => "set", "path" => ["token"], "value" => "issued-bearer" }]]], saved
      refute_includes out.string, "issued-bearer"

      File.write(File.join(bin, "t3"), "#!/bin/sh\nexit 1\n")
      assert_raises(Rho::T3::Error) { command.save_token }
      assert_equal 1, saved.length
    end
  end

  # A host bearer comes from the caller — the route's body, or stdin.
  def test_a_host_bearer_is_read_from_stdin_or_given_and_checked_before_saving
    saved = []
    persist = ->(operations:, **facts) { saved << operations; facts.merge("saved" => true) }
    piped = Rho::T3::Setup.new(settings: settings, native: nil, persist: persist, bridge: Object.new,
      input: StringIO.new("stdin-bearer\n"), prompt: StringIO.new)
    assert_equal({ bearer: "saved", "saved" => true }, piped.save_token)
    assert_equal [[{ "op" => "set", "path" => ["token"], "value" => "stdin-bearer" }]], saved
    given = Rho::T3::Setup.new(settings: settings, native: nil, persist: persist, bridge: Object.new)
    given.save_token(" given-bearer ")
    assert_equal "given-bearer", saved.last.first.fetch("value")
    assert_raises(Rho::ConfigurationError) { given.save_token("") }
    assert_raises(Rho::ConfigurationError) { given.save_token("two words") }
    empty = Rho::T3::Setup.new(settings: settings, native: nil, persist: persist, bridge: Object.new, input: StringIO.new(""), prompt: StringIO.new)
    assert_raises(Rho::ConfigurationError) { empty.save_token }
    assert_equal 2, saved.length
  end
end
