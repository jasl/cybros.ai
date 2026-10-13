require "simplecov"

SimpleCov.start "rails" do
  command_name "Minitest"
  skip "/vendor/"
  skip "/script/"
end
