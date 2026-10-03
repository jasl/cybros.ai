# The whole suite: every test file under test/, loaded in one process. It is slow.
require "minitest/autorun"

Dir[File.join(__dir__, "**", "*_test.rb")].sort.each { |file| require file }
