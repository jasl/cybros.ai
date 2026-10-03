require "json"
require "simple_inference"

# THE WIRE ITSELF, OFFLINE: a routed manual client over a recording transport (the gem's own adapter
# seam) — the request a bench would send and the answer it would parse, no socket opened. Each call
# answers the next body and keeps the request.
class RecordingAdapter < SimpleInference::HTTPAdapter
  attr_reader :requests

  def initialize(*bodies)
    super()
    @bodies = bodies
    @requests = []
  end

  def call(request)
    @requests << request
    { status: 200, headers: { "content-type" => "application/json" }, body: JSON.generate(@bodies.shift) }
  end
end

# A LIVE LANE'S RESET, OFFLINE: the recording transport raising each of `errors` in turn — as the
# socket raises it, beneath the gem's own wrapping — before it answers the bodies. Every request is
# kept, the failed ones too.
class ResettingAdapter < RecordingAdapter
  def initialize(errors, *bodies)
    super(*bodies)
    @errors = errors.dup
  end

  def call(request)
    if @errors.empty?
      super
    else
      @requests << request
      raise @errors.shift
    end
  end
end
