# The terminal mainline's selection after its detailed task evidence is collected.
class Run::RetainedModel
  include StoreModel::Model

  attribute :provider_id, :string
  attribute :model_ref, :string
  attribute :reasoning_effort, :string
  attribute :reasoning_enabled, :boolean

  validates :provider_id, presence: true, length: { maximum: 64 }
  validates :model_ref, presence: true, length: { maximum: 128 }
  validates :reasoning_effort, length: { maximum: 32 }, allow_nil: true

  def self.capture(selection)
    new(provider_id: selection.provider_id, model_ref: selection.model_ref,
      reasoning_effort: selection.reasoning_effort, reasoning_enabled: selection.reasoning_enabled)
  end
end
