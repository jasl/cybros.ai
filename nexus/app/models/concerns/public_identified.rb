# A record addressed by its public id: URL helpers take the record itself
# (`redirect_to [:admin, member]`, `workspace_path(workspace)`) and Rails
# reads the id here.
module PublicIdentified
  extend ActiveSupport::Concern

  def to_param = public_id
end
