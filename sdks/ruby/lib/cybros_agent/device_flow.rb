require_relative "device_flow/errors"
require_relative "device_flow/results"
require_relative "device_flow/client"

module CybrosAgent
  # The minimum typed RFC 8628 device-flow client. This first slice
  # returns typed credential sets to its caller; durable credential storage,
  # executor hosting, and the Agent API resources remain later gem work.
  module DeviceFlow
  end
end
