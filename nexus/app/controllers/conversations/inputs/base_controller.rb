class Conversations::Inputs::BaseController < Conversations::BaseController
  before_action :require_writable_conversation
end
