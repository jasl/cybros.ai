require "test_helper"

class FileTransferTest < Minitest::Test
  include RunnerTest::Helpers

  UPLOAD_ID = "019e2140-1b76-7000-8000-000000000001".freeze
  Upload = Data.define(:filename, :content_type, :byte_size)

  class Attachments < Rho::Runner::ClaimAttachments
    attr_reader :reads

    def initialize(bytes:, size: bytes.bytesize, failure: nil, filename: "../../paper.pdf")
      @bytes, @size, @failure, @filename, @reads = bytes, size, failure, filename, []
    end

    def read(id, io)
      @reads << id
      io.write(@bytes)
      raise @failure if @failure

      Upload.new(filename: @filename, content_type: "application/pdf", byte_size: @size)
    end
  end

  def test_import_writes_complete_working_bytes_outside_the_workspace_without_republishing
    with_tool_env do |env, root|
      attachments = Attachments.new(bytes: "%PDF-1.7\nhello")
      context = Rho::Runner::ExecutionContext.new(attachments: attachments)
      result = Rho::Runner::ExecutionContext.with(context) do
        Rho::Runner::Tools::FileImport.new(env: env).call("upload" => "nexus://uploads/#{UPLOAD_ID}")
      end
      refute_predicate result, :is_error
      path = result.structured_content.fetch("path")
      assert_equal File.join(env.artifacts_dir, "#{UPLOAD_ID}-paper.pdf"), path
      assert_equal "%PDF-1.7\nhello", File.binread(path)
      assert_equal [UPLOAD_ID], attachments.reads
      assert_empty Dir.children(root)
      assert_empty result.files
      assert_equal [File.basename(path)], Dir.children(env.artifacts_dir)
    end
  end

  def test_truncated_or_failed_downloads_leave_no_imported_file
    with_tool_env do |env, _root|
      [Attachments.new(bytes: "short", size: 20),
        Attachments.new(bytes: "partial", failure: IOError.new("connection lost"))].each do |attachments|
        context = Rho::Runner::ExecutionContext.new(attachments: attachments)
        result = Rho::Runner::ExecutionContext.with(context) do
          Rho::Runner::Tools::FileImport.new(env: env).call("upload" => UPLOAD_ID)
        end
        assert_predicate result, :is_error
        assert_empty result.files
        assert_empty Dir.children(env.artifacts_dir)
      end
    end
  end

  def test_import_preserves_the_extension_of_a_long_unicode_filename
    with_tool_env do |env, _root|
      attachments = Attachments.new(bytes: "document bytes", filename: "报告" * 80 + ".docx")
      context = Rho::Runner::ExecutionContext.new(attachments: attachments)
      result = Rho::Runner::ExecutionContext.with(context) do
        Rho::Runner::Tools::FileImport.new(env: env).call("upload" => UPLOAD_ID)
      end
      refute_predicate result, :is_error
      path = result.structured_content.fetch("path")
      assert_equal ".docx", File.extname(path)
      assert_equal "document bytes", File.binread(path)
    end
  end

  def test_import_requires_a_claim_and_never_accepts_arbitrary_urls_or_paths
    with_tool_env do |env, _root|
      tool = Rho::Runner::Tools::FileImport.new(env: env)
      [UPLOAD_ID, "https://example.test/file.pdf", "/private/file", "../#{UPLOAD_ID}"].each do |id|
        assert_predicate tool.call("upload" => id), :is_error
      end
      refute File.exist?(env.artifacts_dir)
    end
  end

  def test_publish_explicitly_selects_any_existing_file_for_the_existing_capture_path
    with_tool_env do |env, root|
      path = File.join(root, "report.pdf")
      File.binwrite(path, "%PDF-report")
      tool = Rho::Runner::Tools::FilePublish.new(env: env)
      result = tool.call("path" => "report.pdf")
      refute_predicate result, :is_error
      assert_equal [path], result.files
      assert_includes result.content, "resource link"
      assert_predicate tool.call("path" => "missing.pdf"), :is_error
      assert_predicate tool.call("path" => root), :is_error
    end
  end
end
