require "test_helper"
require "shellwords"

module Rho
  class Runner
    module Tools
      class ReadTest < Minitest::Test
        include RunnerTest::Helpers

        def test_reads_relative_to_execution_root
          with_tool_env do |env, root|
            File.write(File.join(root, "hello.txt"), "line one\nline two\n")
            result = Read.new(env:).call({ "path" => "hello.txt" })
            refute result.is_error
            assert_equal "line one\nline two", result.content
            assert_nil result.structured_content
          end
        end

        def test_missing_file_is_an_error_result
          with_tool_env do |env, root|
            result = Read.new(env:).call({ "path" => "nope.txt" })
            assert result.is_error
            assert_equal "File not found: #{File.join(root, "nope.txt")}", result.content
          end
        end

        def test_offset_and_limit_page_through_the_file
          with_tool_env do |env, root|
            File.write(File.join(root, "n.txt"), (1..10).map(&:to_s).join("\n"))
            result = Read.new(env:).call({ "path" => "n.txt", "offset" => 3, "limit" => 2 })
            refute result.is_error
            assert_equal "3\n4\n\n[6 more lines in file. Use offset=5 to continue.]", result.content
          end
        end

        def test_offset_beyond_eof
          with_tool_env do |env, root|
            File.write(File.join(root, "n.txt"), "a\nb\n")
            result = Read.new(env:).call({ "path" => "n.txt", "offset" => 5 })
            assert result.is_error
            assert_equal "Offset 5 is beyond end of file (2 lines total)", result.content
          end
        end

        def test_trailing_newline_does_not_add_a_line
          with_tool_env do |env, root|
            File.write(File.join(root, "n.txt"), "a\nb\n")
            result = Read.new(env:).call({ "path" => "n.txt", "offset" => 2 })
            refute result.is_error
            assert_equal "b", result.content
          end
        end

        # Review-hardening pin: the chunked scanner keeps a real empty line
        # at the end of the selected window (the old join/re-split path
        # silently dropped it), so shown-line counts and continuation
        # offsets stay consistent with the file's true line numbering.
        def test_window_ending_with_an_empty_line_keeps_it
          with_tool_env do |env, root|
            File.write(File.join(root, "n.txt"), "a\n\nb\n")
            result = Read.new(env:).call({ "path" => "n.txt", "offset" => 1, "limit" => 2 })
            refute result.is_error
            assert_equal "a\n\n\n[1 more lines in file. Use offset=3 to continue.]", result.content
          end
        end

        def test_line_cap_truncation_footer_and_details
          with_tool_env do |env, root|
            File.write(File.join(root, "big.txt"), (1..2500).map(&:to_s).join("\n"))
            result = Read.new(env:).call({ "path" => "big.txt" })
            refute result.is_error
            assert_includes result.content, "\n\n[Showing lines 1-2000 of 2500. Use offset=2001 to continue.]"
            assert_equal 2000, result.structured_content.dig("truncation", "output_lines")
          end
        end

        def test_byte_cap_footer_names_the_limit
          with_tool_env do |env, root|
            File.write(File.join(root, "wide.txt"), Array.new(100, "x" * 1024).join("\n"))
            result = Read.new(env:).call({ "path" => "wide.txt" })
            refute result.is_error
            assert_includes result.content, "(50.0KB limit). Use offset="
          end
        end

        def test_single_oversized_line_gets_the_sed_hint
          with_tool_env do |env, root|
            File.write(File.join(root, "one.txt"), "x" * (60 * 1024))
            result = Read.new(env:).call({ "path" => "one.txt" })
            refute result.is_error
            assert_includes result.content, "[Line 1 is 60.0KB, exceeds 50.0KB limit."
            # The hint must be directly runnable: pi interpolates the
            # model-supplied path, never a placeholder.
            assert_includes result.content, "sed -n '1p' -- one.txt | head -c 51200"
          end
        end

        def test_oversized_line_shell_escapes_its_requested_path_in_the_sed_hint
          with_tool_env do |env, root|
            requested_path = "-unsafe path;$(touch pwned).txt"
            File.write(File.join(root, requested_path), "x" * (60 * 1024))

            result = Read.new(env:).call({ "path" => requested_path })

            refute result.is_error
            assert_includes result.content,
                            "sed -n '1p' -- #{Shellwords.shellescape(requested_path)} | head -c 51200"
          end
        end

        def test_large_files_are_scanned_without_whole_file_read
          with_tool_env do |env, root|
            path = File.join(root, "huge.txt")
            File.open(path, "wb") do |file|
              10_000.times { |index| file.puts("line #{index} #{"x" * 100}") }
            end

            result = forbid_file_read do
              Read.new(env:).call({ "path" => "huge.txt", "offset" => 9_990 })
            end

            refute result.is_error
            assert_includes result.content, "line 9989"
            assert_includes result.content, "line 9999"
          end
        end

        def test_oversized_single_line_is_scanned_in_bounded_chunks
          with_tool_env do |env, root|
            File.open(File.join(root, "huge-line.txt"), "wb") do |file|
              256.times { file.write("x" * 16_384) }
            end

            result = Read.new(env:).call({ "path" => "huge-line.txt" })

            refute result.is_error
            assert_includes result.content, "[Line 1 is 4.0MB, exceeds 50.0KB limit."
          end
        end

        def test_non_positive_offset_clamps_to_line_one
          with_tool_env do |env, root|
            File.write(File.join(root, "n.txt"), "a\nb\n")
            [0, -3].each do |offset|
              result = Read.new(env:).call({ "path" => "n.txt", "offset" => offset })
              refute result.is_error
              assert_equal "a\nb", result.content
            end
          end
        end

        # refs-parity-2: an image is a capture, never a refusal — the text
        # names the file for the model, `files` names the path for the one
        # upload site, and the kernel places the link natively.
        def test_an_image_is_attached_as_a_capture
          with_tool_env do |env, root|
            File.write(File.join(root, "pic.png"), "not really a png")
            result = Read.new(env:).call({ "path" => "pic.png" })
            refute result.is_error
            assert_equal "pic.png: image attached", result.content
            assert_equal [File.join(root, "pic.png")], result.files
            assert_nil result.structured_content
          end
        end

        def test_invalid_utf8_is_scrubbed_not_fatal
          with_tool_env do |env, root|
            File.binwrite(File.join(root, "bin.txt"), "ok\xFF\xFEok")
            result = Read.new(env:).call({ "path" => "bin.txt" })
            refute result.is_error
            assert result.content.valid_encoding?
          end
        end

        def test_empty_file_reads_as_one_empty_line
          with_tool_env do |env, root|
            File.write(File.join(root, "empty.txt"), "")
            result = Read.new(env:).call({ "path" => "empty.txt" })
            refute result.is_error
            assert_equal "", result.content
          end
        end

        def test_nfd_path_variant_is_found
          with_tool_env do |env, root|
            # File on disk carries the NFD spelling; the model asks in NFC. On
            # macOS (APFS normalization-insensitive lookup) the exact try hits;
            # on Linux the NFD-variant fallback does. Both must succeed.
            nfd_name = "caf\u00E9.txt".unicode_normalize(:nfd)
            File.write(File.join(root, nfd_name), "content")
            result = Read.new(env:).call({ "path" => "caf\u00E9.txt".unicode_normalize(:nfc) })
            refute result.is_error
            assert_equal "content", result.content
          end
        end

        private

        def forbid_file_read
          trace = TracePoint.new(:call, :c_call) do |event|
            if event.self.equal?(File) && event.method_id == :read
              raise "whole-file read is forbidden"
            end
          end
          trace.enable { yield }
        ensure
          trace&.disable
        end
      end

      # THE PORT BRANCH: a routed path
      # — inside the root set, `read` advertised — is read through the
      # editor's port as a WINDOW (`{path, line: offset, limit: (limit ||
      # MAX_LINES) + 1}`: a limit always sent, a buffer never crossing
      # whole), scanned by the same `WindowScanner` from line 1 under the
      # identical ceilings, and footed without a total. Images and the NFD
      # variant stay on disk; the error table is one.
      class ReadPortTest < Minitest::Test
        include RunnerTest::Helpers

        FsPort = Rho::Runner::FsPort
        MAX_LINES = Rho::Runner::Truncation::DEFAULT_MAX_LINES

        def test_a_routed_read_answers_the_buffer_not_the_disk
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            path = File.join(root, "a.txt")
            File.write(path, "on disk\n")
            port = RunnerTest::PortDouble.new(buffers: { path => "in the buffer\n" })
            result = ported(port, env, "a.txt")

            refute result.is_error
            assert_equal "in the buffer", result.content
            assert_equal [[:read, path, { line: 1, limit: MAX_LINES + 1 }]], port.calls
            assert_nil result.structured_content
          end
        end

        def test_with_no_port_on_the_context_the_disk_is_read
          with_tool_env do |env, root|
            File.write(File.join(root, "a.txt"), "on disk\n")
            assert_equal "on disk", Read.new(env:).call({ "path" => "a.txt" }).content
          end
        end

        def test_the_window_is_offset_and_limit_plus_one_and_the_footer_has_no_total
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            path = File.join(root, "n.txt")
            port = RunnerTest::PortDouble.new(buffers: { path => (1..10).map(&:to_s).join("\n") })
            result = ported(port, env, "n.txt", "offset" => 3, "limit" => 2)

            refute result.is_error
            assert_equal [[:read, path, { line: 3, limit: 3 }]], port.calls
            assert_equal "3\n4\n\n[Showing lines 3-4; more lines remain. Use offset=5 to continue.]", result.content
          end
        end

        def test_a_window_that_reaches_the_end_has_no_footer
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            path = File.join(root, "n.txt")
            port = RunnerTest::PortDouble.new(buffers: { path => "a\nb\nc\n" })

            assert_equal "b\nc", ported(port, env, "n.txt", "offset" => 2, "limit" => 2).content
            assert_equal "a\nb\nc", ported(port, env, "n.txt").content
          end
        end

        def test_the_line_ceiling_is_identical_through_the_port
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            path = File.join(root, "big.txt")
            port = RunnerTest::PortDouble.new(buffers: { path => (1..(MAX_LINES + 500)).map(&:to_s).join("\n") })
            result = ported(port, env, "big.txt")

            refute result.is_error
            assert_equal MAX_LINES + 1, port.calls.first.last.fetch(:limit)
            assert result.content.end_with?(
              "\n\n[Showing lines 1-#{MAX_LINES}; more lines remain. Use offset=#{MAX_LINES + 1} to continue.]"
            ), result.content[-120..]
            assert_equal MAX_LINES, result.content.lines.length - 2
          end
        end

        def test_the_byte_ceiling_is_identical_through_the_port_and_names_the_limit
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            path = File.join(root, "wide.txt")
            port = RunnerTest::PortDouble.new(buffers: { path => Array.new(100, "x" * 1024).join("\n") })
            result = ported(port, env, "wide.txt")

            refute result.is_error
            limit = Rho::Runner::Truncation.format_size(Rho::Runner::Truncation::DEFAULT_MAX_BYTES)
            assert_includes result.content, "(#{limit} limit); more lines remain. Use offset="
            refute_includes result.content, " of "
            assert_equal :bytes, result.structured_content.dig("truncation", "truncated_by")
          end
        end

        def test_an_image_is_decided_on_the_resolved_path_first_and_stays_on_disk
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            path = File.join(root, "pic.png")
            File.binwrite(path, "\x89PNG")
            port = RunnerTest::PortDouble.new(buffers: { path => "never" })
            result = ported(port, env, "pic.png")

            assert_equal [path], result.files
            assert_empty port.calls
          end
        end

        def test_a_pdf_attaches_the_original_bytes_without_text_paging_or_an_editor_read
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            path = File.join(root, "report.PDF")
            bytes = "%PDF-1.7\n\x00\xFF\n%%EOF\n".b
            File.binwrite(path, bytes)
            port = RunnerTest::PortDouble.new(buffers: { path => "editor text must not replace the PDF" })
            result = ported(port, env, "report.PDF", "offset" => 99, "limit" => 1)

            refute result.is_error
            assert_equal "report.PDF: PDF attached", result.content
            assert_equal [path], result.files
            assert_equal bytes, File.binread(result.files.fetch(0))
            assert_nil result.structured_content
            assert_empty port.calls
          end
        end

        def test_a_path_outside_the_root_set_reads_the_disk
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            outside = File.join(File.dirname(root), "outside.txt")
            File.write(outside, "disk\n")
            port = RunnerTest::PortDouble.new(buffers: { outside => "buffer\n" })

            assert_equal "disk", ported(port, env, outside).content
            assert_empty port.calls
          end
        end

        def test_a_port_not_serving_read_is_the_disk
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            path = File.join(root, "a.txt")
            File.write(path, "disk\n")
            port = RunnerTest::PortDouble.new(read: false, buffers: { path => "buffer\n" })

            assert_equal "disk", ported(port, env, "a.txt").content
            assert_empty port.calls
          end
        end

        # ---- the error table ----

        def test_not_found_falls_to_the_disk_for_this_call_with_no_notice_and_the_nfd_variant_is_disk_only
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            nfc = "caf\u00e9.txt"
            File.write(File.join(root, nfc.unicode_normalize(:nfd)), "disk\n")
            port = RunnerTest::PortDouble.new
            result = ported(port, env, nfc)

            refute result.is_error
            assert_equal "disk", result.content
            assert_equal [[:read, File.join(root, nfc), { line: 1, limit: MAX_LINES + 1 }]], port.calls,
              "one ask, the NFC spelling; the NFD variant was never asked of the port"
            assert_empty port.dropped
          end
        end

        def test_beyond_eof_is_rhos_beyond_eof_error_in_both_client_shapes
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            path = File.join(root, "n.txt")
            typed = RunnerTest::PortDouble.new(fail: { read: FsPort::BeyondEof.new("-32602") })
            assert_equal "Offset 5 is beyond end of file", ported(typed, env, "n.txt", "offset" => 5).content
            assert ported(typed, env, "n.txt", "offset" => 5).is_error

            empty = RunnerTest::PortDouble.new(buffers: { path => "" })
            result = ported(empty, env, "n.txt", "offset" => 2)
            assert result.is_error
            assert_equal "Offset 2 is beyond end of file", result.content

            assert_equal "", ported(empty, env, "n.txt").content, "an empty buffer at line 1 is an empty file"
          end
        end

        def test_editor_refused_is_an_error_naming_the_client
          with_ported_env(RunnerTest::PortDouble.new) do |env, _root|
            port = RunnerTest::PortDouble.new(client: "zed", fail: { read: FsPort::Refused.new("binary buffer") })
            result = ported(port, env, "a.txt")

            assert result.is_error
            assert_equal "zed: binary buffer", result.content
            assert_empty port.dropped
          end
        end

        def test_cancelled_is_the_runners_cancel_path
          with_ported_env(RunnerTest::PortDouble.new) do |env, _root|
            port = RunnerTest::PortDouble.new(fail: { read: FsPort::Cancelled.new("-32800") })
            error = assert_raises(Rho::Runner::ExecutionContext::Cancelled) { ported(port, env, "a.txt") }
            assert_equal :cancelled, error.reason
          end
        end

        def test_unavailable_reads_the_disk_with_one_notice_and_drops_the_port
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            File.write(File.join(root, "a.txt"), "disk\n")
            port = RunnerTest::PortDouble.new(client: "zed", fail: { read: FsPort::Unavailable.new("connection refused") })
            result = ported(port, env, "a.txt")

            refute result.is_error
            assert result.content.start_with?("[zed did not answer the read (connection refused); read from disk.]\n\n"),
              result.content
            assert result.content.end_with?("\n\ndisk")
            assert_equal ["connection refused"], port.dropped
          end
        end

        def test_unavailable_on_a_file_the_disk_lacks_still_opens_the_error_with_the_notice
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            port = RunnerTest::PortDouble.new(client: "zed", fail: { read: FsPort::Unavailable.new("timeout") })
            result = ported(port, env, "gone.txt")

            assert result.is_error
            assert result.content.start_with?("[zed did not answer the read (timeout); read from disk.]\n\n"), result.content
            assert result.content.end_with?("File not found: #{File.join(root, "gone.txt")}")
          end
        end

        private

        # The tool under the port: the helper placed one double; a row's
        # own double replaces it through the resolver for this call.
        def ported(port, env, path, **args)
          binding = ExecutionContext.current.binding
          context = ExecutionContext.new(tool_env: env, binding: binding, ports: ->(_anchor) { port })
          ExecutionContext.with(context) { Read.new(env:).call({ "path" => path, **args }) }
        end
      end
    end
  end
end
