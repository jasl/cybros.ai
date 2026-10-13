require "test_helper"
require "tmpdir"

class RbsSmokeTest < Minitest::Test
  def test_public_home_and_state_file_entrypoints
    Dir.mktmpdir("rho-rbs-smoke") do |root|
      home = Rho::Home.resolve(base_url: "http://127.0.0.1:3000", root:).prepare
      state = Rho::StateFile.new(home.announcement_path)

      assert_equal({ "state" => "ready" }, state.write("state" => "ready"))
      assert_equal({ "state" => "ready" }, state.read)
      assert_equal root, home.root
    end
  end
end
