Dir[File.join(__dir__, "*_test.rb")].sort.each { |file| require file }
