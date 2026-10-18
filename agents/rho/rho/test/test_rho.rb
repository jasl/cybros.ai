require "test_helper"

class TestRho < Minitest::Test
  def test_version_is_set
    refute_nil Rho::VERSION
  end
end
