require "test_helper"
require "stringio"

class ClaimAttachmentsTest < Minitest::Test
  class Task
    attr_reader :calls

    def initialize
      @calls = []
    end
    def attachment(id, claim_token:)
      @calls << [:descriptor, id, claim_token, Thread.current]
      CybrosAgent::Api::Upload.new(public_id: id, filename: "file.txt", content_type: "text/plain",
        byte_size: 12, created_at: "2026-10-01T00:00:00Z")
    end
    def attachment_bytes(id, io, claim_token:)
      @calls << [:bytes, id, claim_token, Thread.current]
      io.write("actual bytes")
    end
  end

  def test_kernel_io_stays_on_the_pool_calling_thread_and_handler_gets_the_streamed_result
    task = Task.new
    attachments = Rho::Runner::ClaimAttachments.new(task: task, claim_token: "proof")
    context = Rho::Runner::ExecutionContext.new(attachments: attachments)
    pool = Rho::Runner::Pool.new(worker_threads: 1)
    io = StringIO.new
    worker = nil
    result = pool.run(pool.reserve, context) do
      worker = Thread.current
      attachments.read("upload", io)
    end
    assert_equal "upload", result.public_id
    assert_equal "actual bytes", io.string
    refute_equal Thread.current, worker
    assert_equal [[:descriptor, "upload", "proof", Thread.current], [:bytes, "upload", "proof", Thread.current]], task.calls
  ensure
    pool&.stop
  end

  def test_cancelled_worker_does_not_wait_forever_for_a_transfer_that_never_started
    attachments = Rho::Runner::ClaimAttachments.new(task: Task.new, claim_token: "proof")
    context = Rho::Runner::ExecutionContext.new(attachments: attachments)
    context.cancel(:canceled)
    assert_raises(Rho::Runner::ExecutionContext::Cancelled) do
      Rho::Runner::ExecutionContext.with(context) { attachments.read("upload", StringIO.new) }
    end
  end
end
