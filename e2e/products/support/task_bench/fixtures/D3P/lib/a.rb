require_relative "e"

module A
  def self.parse(text) = text.split(",").map { |field| E.clean(field) }

  def self.parse_semicolons(text) = text.split(";").map { |field| E.clean(field) }
end
