module D
  def self.render(field) = "<#{field}>"

  def self.render_json(field) = %({"field":"#{field}"})
end
