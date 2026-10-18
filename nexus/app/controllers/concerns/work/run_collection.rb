module Work::RunCollection
  extend ActiveSupport::Concern
  include RunListing
  include AgentAPI::KeysetPagination

  private

    def prepare_run_collection(scope, default_kind: "", fixed_executor: nil)
      scope = filtered_runs(scope, default_kind: default_kind, fixed_executor: fixed_executor)
      @page = keyset_page(scope.includes(:workspace, :creating_user, variant: { turn: [:conversation, :answering_user] }),
        columns: { public_id: :uuid })
      @runs = @page.records
      @projections = AgentAPI::RunPresenter.basic_many(@runs).index_by { |run| run.fetch(:public_id) }
    end

    def list_direction
      params[:order].blank? ? :desc : super
    end
end
