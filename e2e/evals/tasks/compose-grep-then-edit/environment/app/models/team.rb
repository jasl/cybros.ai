class Team < ApplicationRecord
  belongs_to :account
  has_many :users

  def full_name = "#{account.label} / #{name}"

  def to_s = full_name
end
