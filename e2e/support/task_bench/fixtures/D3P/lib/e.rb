module E
  def self.clean(field) = field.strip

  def self.clean_all(fields) = fields.map(&:strip).reject(&:empty?)
end
