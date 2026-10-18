module DiagnosticDownload
  private

    def download_diagnostics(body, filename:)
      response.headers["Content-Type"] = "application/gzip"
      response.headers["Content-Disposition"] = ActionDispatch::Http::ContentDisposition.format(
        disposition: "attachment", filename: filename)
      response.headers["Cache-Control"] = "no-store"
      self.response_body = body
    end
end
