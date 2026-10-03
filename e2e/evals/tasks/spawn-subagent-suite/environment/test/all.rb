sleep 45 # the suite is slow on purpose: the reply must go final before it
Dir[File.join(__dir__, "*_test.rb")].each { |file| require file }
