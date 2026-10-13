class ExecutionDeclaration::Delegation
  include StoreModel::Model

  attribute :name, :string
  attribute :description, :string
  attribute :model_mode, :string
  attribute :declaration, ExecutionDeclaration.to_type

  validates :name, length: { maximum: 64 }, format: { with: /\A[a-z0-9][a-z0-9_-]*\z/ }, presence: true
  validates :description, length: { maximum: 1024 }, presence: true
  validates :model_mode, inclusion: { in: %w[caller default] }
  validates :declaration, presence: true, store_model: true
  validate :declaration_is_a_leaf

  private

    def declaration_is_a_leaf
      errors.add(:declaration, :invalid) if declaration&.delegation_catalog
    end
end
