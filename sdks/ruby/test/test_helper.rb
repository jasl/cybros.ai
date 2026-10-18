$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "cybros_agent"

require "minitest/autorun"

require_relative "support/fake_transport"
require_relative "support/operation_coverage" if ENV["CYBROS_SDK_OPERATION_COVERAGE"] == "1"
