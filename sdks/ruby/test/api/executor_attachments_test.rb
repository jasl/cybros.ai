require "test_helper"
require_relative "../support/contract_clients"

class ApiExecutorAttachmentsTest < Minitest::Test
  include CybrosAgentTest::ContractClients

  def test_claim_scoped_descriptor_and_streamed_bytes_keep_proof_out_of_the_url
    descriptor = { "public_id" => "upload-id", "filename" => "paper.pdf", "content_type" => "application/pdf",
      "byte_size" => 5, "created_at" => "2026-10-01T00:00:00Z" }
    transport = CybrosAgentTest::FakeTransport.new([
      [200, {}, { "upload" => descriptor }], [200, {}, "%PDF-"], [206, {}, "PDF"],
    ])
    client = CybrosAgent::ExecutorClient.new(base_url: "https://nexus.test", credential: "executor-key", transport: transport)
    task = client.inbox_task(agent_loop_public_id: "loop", task_key: "task")

    upload = task.attachment("upload-id", claim_token: "claim-proof")
    assert_equal "paper.pdf", upload.filename
    bytes = StringIO.new
    read = task.attachment_bytes("upload-id", bytes, claim_token: "claim-proof")
    assert_equal "%PDF-", bytes.string
    assert_equal 200, read.status
    assert_nil read.etag
    partial = StringIO.new
    assert_equal 206, task.attachment_bytes("upload-id", partial, claim_token: "claim-proof", range: "bytes=1-3").status
    assert_equal "PDF", partial.string
    attachment_contract = contract("uploads.json").fetch("executor_attachment")
    transport.requests.each do |request|
      assert_equal "executor-key", request.fetch(:credential)
      assert_equal "claim-proof", request.fetch(:headers).fetch(attachment_contract.fetch("claim_header"))
      refute_includes request.fetch(:path), "claim-proof"
    end
    values = { "agent_loop_public_id" => "loop", "task_key" => "task", "public_id" => "upload-id" }
    %w[descriptor_path bytes_path].each_with_index do |key, index|
      expected = attachment_contract.fetch(key).gsub(/\{([^}]+)\}/) { values.fetch(Regexp.last_match(1)) }
      assert_equal expected, transport.requests[index].fetch(:path)
    end
    assert_equal "bytes=1-3", transport.requests[2].fetch(:headers).fetch("Range")
  end

  def test_inactive_claim_is_typed_and_writes_no_bytes
    status = contract("uploads.json").dig("executor_attachment", "statuses", "claim_inactive")
    transport = CybrosAgentTest::FakeTransport.new([[status, {}, { "error" => { "code" => "claim_inactive", "message" => "Refused" } }]])
    client = CybrosAgent::ExecutorClient.new(base_url: "https://nexus.test", credential: "executor-key", transport: transport)
    bytes = StringIO.new
    error = assert_raises(CybrosAgent::Api::Conflict) do
      client.inbox_task(agent_loop_public_id: "loop", task_key: "task")
        .attachment_bytes("upload", bytes, claim_token: "proof")
    end
    assert_equal "claim_inactive", error.code
    assert_empty bytes.string
  end
end
