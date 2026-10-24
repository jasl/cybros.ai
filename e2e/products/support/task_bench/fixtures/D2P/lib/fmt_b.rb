module FmtB
  def self.format(time, with_time: false)
    date = "#{time.year}-#{time.month}-#{time.day}"
    with_time ? "#{date} #{time.hour}:#{time.min}:#{time.sec}" : date
  end
end
