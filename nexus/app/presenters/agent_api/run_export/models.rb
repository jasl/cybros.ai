module AgentAPI
  class RunExport
    module Models
      private

        def models
          scope = ModelInvocation.where(run_id: @run.id)
          ceiling = read { scope.maximum(:id) }
          cursor = 0
          while ceiling && cursor < ceiling
            page = read do
              scope.where(id: (cursor + 1)..ceiling).order(:id).limit(DiagnosticExport::PAGE_SIZE).to_a
            end
            break if page.empty? || !retained_run?

            cursor = page.last.id
            page.each do |invocation|
              yield envelope("model_invocation", model_invocation: {
                public_id: invocation.public_id, provider_id: invocation.provider_id, model_ref: invocation.model_ref,
                workload: invocation.workload, status: invocation.status, finish_quality: invocation.finish_quality,
                failure_reason: invocation.failure_reason_key, failure_detail: invocation.failure_detail,
                created_at: invocation.created_at, terminal_at: invocation.terminal_at,
              })
              model_bodies(invocation) { |record| yield record }
              attempts(invocation) { |record| yield record }
              usage(invocation) { |record| yield record }
            end
          end
        end

        def model_bodies(invocation)
          scope = invocation.content_bodies.where(role: %w[request response reasoning tool_calls])
          bodies = read { scope.order(:id).to_a }
          bodies.each do |body|
            cursor = -1
            ceiling = read { body.content_body_entries.maximum(:position) }
            while ceiling && cursor < ceiling
              page = read do
                body.content_body_entries.where(position: (cursor + 1)..ceiling).order(:position)
                  .limit(DiagnosticExport::PAGE_SIZE).preload(:content_fragment).map do |entry|
                    [entry.position, entry.content_fragment.payload]
                  end
              end
              break if page.empty?

              cursor = page.last.first
              page.each do |position, payload|
                yield envelope("model_content", model_invocation_public_id: invocation.public_id,
                  role: body.role, position: position, content: payload)
              end
            end
            files(body, invocation) { |record| yield record }
          end
        end

        def files(body, invocation)
          ceiling = read { body.content_uploads.maximum(:id) }
          cursor = 0
          while ceiling && cursor < ceiling
            page = read do
              body.content_uploads.where(id: (cursor + 1)..ceiling).order(:id).limit(DiagnosticExport::PAGE_SIZE)
                .preload(file_attachment: :blob).map { |upload| [upload.id, UploadPresenter.full(upload)] }
            end
            break if page.empty?

            cursor = page.last.first
            page.each do |_, file|
              yield envelope("file", model_invocation_public_id: invocation.public_id, role: body.role,
                file: file.merge(bytes_path: Rails.application.routes.url_helpers.upload_bytes_path(file.fetch(:public_id))))
            end
          end
        end

        def attempts(invocation)
          ceiling = read { invocation.attempts.maximum(:ordinal) }
          cursor = 0
          while ceiling && cursor < ceiling
            page = read do
              invocation.attempts.where(ordinal: (cursor + 1)..ceiling).order(:ordinal).limit(DiagnosticExport::PAGE_SIZE).map do |attempt|
                { public_id: attempt.public_id, ordinal: attempt.ordinal, status: attempt.status,
                  admission_shape: attempt.admission_shape, provider_started_at: attempt.provider_started_at,
                  terminal_at: attempt.terminal_at }
              end
            end
            break if page.empty?

            cursor = page.last.fetch(:ordinal)
            page.each { |attempt| yield envelope("attempt", model_invocation_public_id: invocation.public_id, attempt: attempt) }
          end
        end

        def usage(invocation)
          scope = UsageRecord.where(account_id: @run.account_id, model_invocation_public_id: invocation.public_id)
          ceiling = read { scope.maximum(:id) }
          cursor = 0
          while ceiling && cursor < ceiling
            page = read do
              scope.where(id: (cursor + 1)..ceiling).order(:id).limit(DiagnosticExport::PAGE_SIZE)
                .map { |receipt| [receipt.id, UsageRecords::PublicUsage.diagnostic(receipt)] }
            end
            break if page.empty?

            cursor = page.last.first
            page.each { |_, receipt| yield envelope("usage", usage: receipt) }
          end
        end
    end
  end
end
