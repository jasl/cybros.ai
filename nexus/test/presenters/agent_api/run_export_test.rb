require "test_helper"
require "zlib"
require_relative "../../test_helpers/awaits_test_helper"

class AgentAPI::RunExportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include AwaitsTestHelper

  test "a standalone execution exports its actual attempt request reasoning result and receipt" do
    run = seed(model("answer", "prompt" => "Read the evidence"))
    start!(run)
    attempt = attempt_of(run, "answer")
    apply_via(attempt, sse_success("The result", reasoning: "The reasoning", usage: { "input_tokens" => 3, "output_tokens" => 4 }))
    Runs::ConvergeTerminalSteps.call
    records = decode(run.reload)

    assert_equal "no_conversation_retention", records.first.dig("retention", "applies_to")
    assert_nil records.first.dig("retention", "execution_details_retention_days")
    assert_equal attempt.public_id, records.find { |record| record["type"] == "attempt" }.dig("attempt", "public_id")
    assert_equal "completed", records.find { |record| record["type"] == "attempt" }.dig("attempt", "status")
    assert_equal attempt.model_invocation.public_id, records.find { |record| record["type"] == "model_invocation" }.dig("model_invocation", "public_id")
    assert_includes records.select { |record| record["type"] == "request" }.to_json, "Read the evidence"
    assert_includes records.select { |record| record["role"] == "reasoning" }.to_json, "The reasoning"
    assert_includes records.select { |record| record["role"] == "response" }.to_json, "The result"
    assert_equal 7, records.find { |record| record["type"] == "usage" }.dig("usage", "total_tokens")
    %w[claim_token resolution_token internal_creation_key model_invocation_id payer_public_id].each do |field|
      assert_not_includes records.to_json, %Q("#{field}":)
    end
  end

  test "attached model content names authorized upload reads without downloading bytes" do
    run = seed(model("answer", "prompt" => "Read the file"))
    start!(run)
    invocation = node(run, "answer").selected_model_invocation
    upload = @account.content_uploads.create!(creating_user: @human,
      file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new("attachment"), filename: "note.txt", content_type: "text/plain"))
    body = invocation.content_bodies.find_by!(role: "request")
    body.content_body_uploads.create!(content_upload: upload)
    downloads = []
    listener = ->(*, payload) { downloads << payload }
    records = ActiveSupport::Notifications.subscribed(listener, /service_download.*\.active_storage/) { decode(run) }
    file = records.find { |record| record["type"] == "file" }.fetch("file")
    assert_equal upload.public_id, file.fetch("public_id")
    assert_equal "/uploads/#{upload.public_id}/bytes", file.fetch("bytes_path")
    assert_equal "note.txt", file.fetch("filename")
    assert_empty downloads
  end

  test "pruning during a download reports unavailable material instead of silently completing an empty graph" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    seam = create_run_backed_turn(conversation: conversation, acting_user: @human)
    seam.run.tasks.create!(type: Tasks::ModelTask.sti_name, node_key: "first", authored_by: "author",
      provider_id: "dev", model_ref: "mock-text")
    changed = false
    records = decode(seam.run) do |record|
      if record["type"] == "task" && !changed
        Run.where(id: seam.run.id).update_all(details_pruned_at: Time.current)
        changed = true
      end
    end
    assert records.any? { |record| record["type"] == "execution_unavailable" }
    assert_equal "end", records.last.fetch("type")
  end

  private

    def decode(run)
      inflater = Zlib::Inflate.new(Zlib::MAX_WBITS + 16)
      pending = +""
      records = []
      AgentAPI::RunExport.new(run: run, user: @human).each do |chunk|
        pending << inflater.inflate(chunk)
        while (newline = pending.index("\n"))
          record = JSON.parse(pending.slice!(0..newline))
          records << record
          yield record if block_given?
        end
      end
      assert_predicate inflater, :finished?
      assert_empty pending
      assert_equal records.pluck("type").tally, records.last.fetch("counts")
      records
    ensure
      inflater&.close
    end
end
