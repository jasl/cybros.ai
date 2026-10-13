# Selection intent remains independent of the route that eventually answers.
# Equality with a configured default never erases an explicit user choice.
class ModelSelectionIntent
  include StoreModel::Model

  SOURCES = %w[default inherited explicit].freeze
  CONSTRAINTS = %w[any model provider route].freeze

  attribute :source, :string
  attribute :model, :string
  attribute :constraint, :string
  attribute :alternatives, default: -> { [] }

  validates :source, inclusion: { in: SOURCES }
  validates :constraint, inclusion: { in: CONSTRAINTS }
  validates :model, length: { maximum: 193 }, presence: true
  validates :alternatives, model_references: true
  validate :model_is_complete

  def self.default(model) = new(source: "default", model: model, constraint: "any")
  def self.inherited(model) = new(source: "inherited", model: model, constraint: "any")
  def self.explicit(model) = new(source: "explicit", model: model, constraint: "route")

  private

    def model_is_complete
      errors.add(:model, :invalid) unless Nexus::ModelRef.parse(model).complete?
    end
end
