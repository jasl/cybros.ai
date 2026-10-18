class Workspaces::DataExportsController < Workspaces::BaseController
  include DiagnosticDownload

  def show
    download_diagnostics(Workspaces::DataExport.new(workspace: workspace),
      filename: "workspace-#{workspace.public_id}-data.jsonl.gz")
  end
end
