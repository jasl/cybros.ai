require "test_helper"
require "open3"
require "tmpdir"

# THE GEM LOADS, AND THE EXE IS THE SURFACE: the module, its version, and
# `rho-acp` on a stdin at EOF — nothing on stdout, the wire an editor
# would read — exiting 0 (EOF is a clean exit; the stub's sentence and its exit 2 left with the surface's landing).
class GemTest < Minitest::Test
  def test_the_module_loads_with_its_version
    assert_kind_of Module, Rho::Acp
    assert_match(/\A\d+\.\d+\.\d+\z/, Rho::Acp::VERSION)
    assert_predicate Rho::Acp::VERSION, :frozen?
    assert_kind_of Class, Rho::Acp::Agent
  end

  def test_the_exe_serves_the_wire_and_exits_0_at_eof_with_nothing_on_stdout
    env = RhoAcpTest::CHILD_BUNDLE_ENV.merge("RHO_HOME" => Dir.mktmpdir("rho-acp-gem"), "RHO_NEXUS_URL" => "https://nexus.example")
    stdout, stderr, status = Open3.capture3(env, Gem.ruby, "-rbundler/setup", RhoAcpTest::EXE, stdin_data: "")
    assert_equal 0, status.exitstatus, stderr
    assert_equal "", stdout
  end
end
