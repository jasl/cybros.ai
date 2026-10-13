# Hands a message to the transport, retrying once when the first attempt fails.
class RelaySend
  def initialize(transport)
    @transport = transport
  end

  def call(message)
    @transport.deliver(message)
  rescue IOError
    @transport.deliver(message)
  end
end
