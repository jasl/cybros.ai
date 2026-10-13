require "minitest/autorun"
require "rho"

class GreetingTest < Minitest::Test
  def test_greeting_uses_the_persons_name
    package = Rho::Runner::Extensions::Loader.load_file(File.expand_path("../extension.rb", __dir__))
    answer = package::Read.new(env: nil, person: "Ada").call({})
    assert_equal "#{package::WORD}, Ada.", answer.content
  end
end
