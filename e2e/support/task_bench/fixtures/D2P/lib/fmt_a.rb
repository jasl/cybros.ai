module FmtA
  def self.format(time, with_time: false)
    utc = time.getutc
    with_time ? utc.strftime("%Y-%m-%dT%H:%M") : utc.strftime("%Y-%m-%d")
  end
end
