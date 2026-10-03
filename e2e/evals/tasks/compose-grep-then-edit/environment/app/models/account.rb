class Account < ApplicationRecord
  has_many :teams

  def label = "#{slug} (#{plan})"
end
