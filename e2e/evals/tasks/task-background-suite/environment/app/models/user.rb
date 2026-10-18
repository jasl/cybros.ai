class User < ApplicationRecord
  def active? 
    enabled == true
  end
end
