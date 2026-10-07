# Writes rows as comma-separated lines, quoting a field that holds a comma.
class CsvOut
  def initialize(columns)
    @columns = columns
  end

  def call(rows)
    lines = rows.map { |row| @columns.map { |column| field(row[column]) }.join(",") }
    ([@columns.join(",")] + lines).join("\n")
  end

  private

  def field(value)
    text = value.to_s
    text.include?(",") ? %("#{text}") : text
  end
end
