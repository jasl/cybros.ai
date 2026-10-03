class User < ApplicationRecord
  belongs_to :team

  def initials = name.split.map { |part| part[0] }.join
end
