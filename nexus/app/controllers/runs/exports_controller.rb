class Runs::ExportsController < Work::BaseController
  include DiagnosticDownload

  def show
    run = find_visible_run(:run_id)
    download_diagnostics(AgentAPI::RunExport.new(run: run, user: acting_user),
      filename: "run-#{run.public_id}.jsonl.gz")
  end
end
