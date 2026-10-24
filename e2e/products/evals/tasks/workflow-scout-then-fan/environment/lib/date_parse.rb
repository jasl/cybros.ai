# Reads a day written as YYYY-MM-DD.
module DateParse
  module_function

  def call(text)
    year, month, day = text.split("-").map(&:to_i)
    { year: year, month: month, day: day }
  end
end
