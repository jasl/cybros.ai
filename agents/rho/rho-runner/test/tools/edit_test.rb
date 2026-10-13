require "test_helper"

module Rho
  class Runner
    module Tools
      class EditTest < Minitest::Test
        include RunnerTest::Helpers

        LEFT_SINGLE = 0x2018.chr(Encoding::UTF_8)
        RIGHT_SINGLE = 0x2019.chr(Encoding::UTF_8)
        LEFT_DOUBLE = 0x201C.chr(Encoding::UTF_8)
        RIGHT_DOUBLE = 0x201D.chr(Encoding::UTF_8)
        EN_DASH = 0x2013.chr(Encoding::UTF_8)
        NBSP = 0x00A0.chr(Encoding::UTF_8)
        BOM = 0xFEFF.chr(Encoding::UTF_8)

        def test_single_exact_replacement
          with_tool_env do |env, root|
            File.write(File.join(root, "a.txt"), "hello world\n")
            result = run_edit(env, "a.txt", [["world", "ruby"]])
            refute result.is_error
            assert_equal "Successfully replaced 1 block(s) in a.txt.", result.content
            assert_equal({ "replacements" => 1, "first_changed_line" => 1 }, result.structured_content)
            assert_equal "hello ruby\n", File.read(File.join(root, "a.txt"))
          end
        end

        def test_edits_match_against_original_content_not_incrementally
          with_tool_env do |env, root|
            # After edit 0 is applied, "three" would appear twice; matching
            # against the original keeps edit 1 unambiguous.
            File.write(File.join(root, "o.txt"), "one\nthree\n")
            result = run_edit(env, "o.txt", [["one", "three"], ["three", "four"]])
            refute result.is_error
            assert_equal "Successfully replaced 2 block(s) in o.txt.", result.content
            assert_equal "three\nfour\n", File.read(File.join(root, "o.txt"))
          end
        end

        def test_out_of_order_edits_apply_with_stable_offsets
          with_tool_env do |env, root|
            # Listed later-in-file first with a length-changing replacement:
            # reverse match-index application must keep earlier offsets valid.
            File.write(File.join(root, "r.txt"), "alpha\nbeta\ngamma\n")
            result = run_edit(env, "r.txt", [["gamma", "GAMMA-EXPANDED"], ["alpha", "A"]])
            refute result.is_error
            assert_equal "A\nbeta\nGAMMA-EXPANDED\n", File.read(File.join(root, "r.txt"))
            assert_equal 1, result.structured_content["first_changed_line"]
          end
        end

        def test_duplicate_text_is_rejected_with_occurrence_count
          with_tool_env do |env, root|
            File.write(File.join(root, "dup.txt"), "dup\nmid\ndup\n")
            result = run_edit(env, "dup.txt", [["dup", "x"]])
            assert result.is_error
            assert_equal "Found 2 occurrences of the text in dup.txt. The text must be unique. " \
                         "Please provide more context to make it unique.", result.content
            assert_equal "dup\nmid\ndup\n", File.read(File.join(root, "dup.txt"))
          end
        end

        def test_duplicate_text_error_is_indexed_for_multiple_edits
          with_tool_env do |env, root|
            File.write(File.join(root, "dup.txt"), "dup\nmid\ndup\n")
            result = run_edit(env, "dup.txt", [["mid", "M"], ["dup", "x"]])
            assert result.is_error
            assert_equal "Found 2 occurrences of edits[1] in dup.txt. Each oldText must be unique. " \
                         "Please provide more context to make it unique.", result.content
          end
        end

        def test_overlapping_edits_are_rejected
          with_tool_env do |env, root|
            File.write(File.join(root, "o.txt"), "abcdef\n")
            result = run_edit(env, "o.txt", [["abcd", "x"], ["cdef", "y"]])
            assert result.is_error
            assert_equal "edits[0] and edits[1] overlap in o.txt. " \
                         "Merge them into one edit or target disjoint regions.", result.content
            assert_equal "abcdef\n", File.read(File.join(root, "o.txt"))
          end
        end

        def test_not_found_single_edit_message
          with_tool_env do |env, root|
            File.write(File.join(root, "f.txt"), "content\n")
            result = run_edit(env, "f.txt", [["missing", "x"]])
            assert result.is_error
            assert_equal "Could not find the exact text in f.txt. " \
                         "The old text must match exactly including all whitespace and newlines.", result.content
          end
        end

        def test_not_found_multi_edit_message_is_indexed
          with_tool_env do |env, root|
            File.write(File.join(root, "f.txt"), "content\n")
            result = run_edit(env, "f.txt", [["content", "C"], ["missing", "x"]])
            assert result.is_error
            assert_equal "Could not find edits[1] in f.txt. " \
                         "The oldText must match exactly including all whitespace and newlines.", result.content
          end
        end

        def test_empty_old_text_single_edit
          with_tool_env do |env, root|
            File.write(File.join(root, "f.txt"), "content\n")
            result = run_edit(env, "f.txt", [["", "x"]])
            assert result.is_error
            assert_equal "oldText must not be empty in f.txt.", result.content
          end
        end

        def test_empty_old_text_multi_edit_is_indexed
          with_tool_env do |env, root|
            File.write(File.join(root, "f.txt"), "content\n")
            result = run_edit(env, "f.txt", [["content", "C"], ["", "x"]])
            assert result.is_error
            assert_equal "edits[1].oldText must not be empty in f.txt.", result.content
          end
        end

        def test_fuzzy_smart_quotes_match_and_untouched_lines_keep_original_bytes
          with_tool_env do |env, root|
            original = "say #{LEFT_SINGLE}hi#{RIGHT_SINGLE} now\n" \
                       "keep #{LEFT_DOUBLE}quoted#{RIGHT_DOUBLE} bytes\n" \
                       "plain\n"
            File.binwrite(File.join(root, "q.txt"), original)
            result = run_edit(env, "q.txt", [["say 'hi' now", "say 'bye' now"]])
            refute result.is_error
            expected = "say 'bye' now\n" \
                       "keep #{LEFT_DOUBLE}quoted#{RIGHT_DOUBLE} bytes\n" \
                       "plain\n"
            assert_equal expected.b, File.binread(File.join(root, "q.txt"))
          end
        end

        def test_fuzzy_trailing_whitespace_match_preserves_untouched_trailing_whitespace
          with_tool_env do |env, root|
            File.binwrite(File.join(root, "w.txt"), "code   \nnext\nkeep   \n")
            result = run_edit(env, "w.txt", [["code\nnext", "CODE\nNEXT"]])
            refute result.is_error
            # Touched lines are rewritten from the normalized base; the
            # untouched third line keeps its original trailing spaces.
            assert_equal "CODE\nNEXT\nkeep   \n".b, File.binread(File.join(root, "w.txt"))
          end
        end

        def test_fuzzy_nbsp_and_dash_normalization
          with_tool_env do |env, root|
            original = "value#{NBSP}one\nspan #{EN_DASH} two\n"
            File.binwrite(File.join(root, "n.txt"), original)
            result = run_edit(env, "n.txt", [["value one", "VALUE ONE"], ["span - two", "SPAN TWO"]])
            refute result.is_error
            assert_equal "VALUE ONE\nSPAN TWO\n".b, File.binread(File.join(root, "n.txt"))
          end
        end

        def test_exact_unique_text_that_is_ambiguous_after_normalization_is_rejected
          with_tool_env do |env, root|
            # "don't" appears exactly once verbatim, but twice in fuzzy space
            # (the smart-quote variant normalizes to the same string).
            original = "left don#{RIGHT_SINGLE}t right\nleft don't right\n"
            File.binwrite(File.join(root, "amb.txt"), original)
            result = run_edit(env, "amb.txt", [["don't", "cannot"]])
            assert result.is_error
            assert_equal "Found 2 occurrences of the text in amb.txt. The text must be unique. " \
                         "Please provide more context to make it unique.", result.content
            assert_equal original.b, File.binread(File.join(root, "amb.txt"))
          end
        end

        def test_crlf_line_endings_are_preserved
          with_tool_env do |env, root|
            File.binwrite(File.join(root, "c.txt"), "alpha\r\nbeta\r\ngamma\r\n")
            # LF-normalized oldText spanning lines must match the CRLF file.
            result = run_edit(env, "c.txt", [["alpha\nbeta", "one\ntwo"]])
            refute result.is_error
            assert_equal "one\r\ntwo\r\ngamma\r\n".b, File.binread(File.join(root, "c.txt"))
            assert_equal 1, result.structured_content["first_changed_line"]
          end
        end

        def test_bom_is_preserved_and_invisible_to_matching
          with_tool_env do |env, root|
            File.binwrite(File.join(root, "b.txt"), "#{BOM}hello\nworld\n")
            result = run_edit(env, "b.txt", [["hello", "goodbye"]])
            refute result.is_error
            assert_equal "#{BOM}goodbye\nworld\n".b, File.binread(File.join(root, "b.txt"))
          end
        end

        def test_identical_result_is_an_error
          with_tool_env do |env, root|
            File.write(File.join(root, "i.txt"), "hello\n")
            result = run_edit(env, "i.txt", [["hello", "hello"]])
            assert result.is_error
            assert_equal "No changes made to i.txt. The replacement produced identical content. " \
                         "This might indicate an issue with special characters or the text not existing " \
                         "as expected.", result.content
          end
        end

        def test_missing_file_reports_enoent
          with_tool_env do |env, _root|
            result = run_edit(env, "missing.txt", [["a", "b"]])
            assert result.is_error
            assert_equal "Could not edit file: missing.txt. Error code: ENOENT.", result.content
          end
        end

        def test_invalid_utf8_is_rejected_without_rewriting_the_file
          with_tool_env do |env, root|
            path = File.join(root, "invalid.txt")
            original = "before\xFFafter\n".b
            File.binwrite(path, original)

            result = run_edit(env, "invalid.txt", [["before", "changed"]])

            assert result.is_error
            assert_equal "Could not edit file: invalid.txt. File content must be valid UTF-8.", result.content
            assert_equal original, File.binread(path)
          end
        end

        def test_first_changed_line_points_at_the_edited_line
          with_tool_env do |env, root|
            File.write(File.join(root, "n.txt"), "l1\nl2\nl3\nl4\n")
            result = run_edit(env, "n.txt", [["l3", "l3-changed"]])
            refute result.is_error
            assert_equal 3, result.structured_content["first_changed_line"]
          end
        end

        def test_first_changed_line_reports_the_earliest_change_across_edits
          with_tool_env do |env, root|
            File.write(File.join(root, "n.txt"), "l1\nl2\nl3\nl4\n")
            result = run_edit(env, "n.txt", [["l4", "L4"], ["l2", "L2"]])
            refute result.is_error
            assert_equal 2, result.structured_content["first_changed_line"]
          end
        end

        # Behavioral sweep instead of pinning one internal check position:
        # at EVERY cancellation point the edit passes through (a smart-quote
        # oldText forces the fuzzy normalize/overlay path too), an expired
        # deadline must abort without writing a byte. The sweep ends at the
        # first position past the final check, where the edit completes.
        def test_cancellation_at_every_check_position_never_writes
          with_tool_env do |env, root|
            path = File.join(root, "cancel.txt")
            original = "alpha\nbeta — note\ngamma\n"
            cancelled_positions = 0
            completed = false
            (1..64).each do |position|
              File.write(path, original)
              context = deadline_context_on_check(position)
              begin
                result = ExecutionContext.with(context) do
                  run_edit(env, "cancel.txt", [["beta - note", "changed"]])
                end
                refute result.is_error, result.content.to_s
                completed = true
                break
              rescue ExecutionContext::Cancelled
                cancelled_positions += 1
                assert_equal original.b, File.binread(path),
                             "cancellation at check position #{position} left a partial write"
              end
            end
            assert_operator cancelled_positions, :>=, 3,
                            "the edit must be cancellable during CPU matching"
            assert completed, "the sweep must end with a successful edit past the final check"
          end
        end

        def test_empty_edits_array_is_invalid_input
          with_tool_env do |env, root|
            File.write(File.join(root, "e.txt"), "content\n")
            result = Edit.new(env:).call({ "path" => "e.txt", "edits" => [] })
            assert result.is_error
            assert_equal "Edit tool input is invalid. edits must contain at least one replacement.", result.content
          end
        end

        # The entry shapes are the SCHEMA's (types and `required` on `inputSchema`, refused before the
        # handler runs); the sentence the model reads is json_schemer's, naming the entry and the field.
        # An empty list fits the schema, which sets no minItems, so the handler's own check above stays.
        def test_malformed_edit_entries_are_the_schemas_refusal
          assert_equal "value at `/edits` is not an array", schema_refusal({ "path" => "e.txt", "edits" => "content" })
          assert_equal "value at `/edits/0` is not an object", schema_refusal({ "path" => "e.txt", "edits" => ["content"] })
          assert_equal "object at `/edits/0` is missing required properties: newText",
            schema_refusal({ "path" => "e.txt", "edits" => [{ "oldText" => "content" }] })
          assert_equal "value at `/edits/0/oldText` is not a string",
            schema_refusal({ "path" => "e.txt", "edits" => [{ "oldText" => 1, "newText" => "b" }] })
          assert_nil schema_refusal({ "path" => "e.txt", "edits" => [] })
        end

        private

        def schema_refusal(arguments)
          InputSchema.refusal(InputSchema.compile(Edit::SCHEMA), arguments)
        end

        def deadline_context_on_check(target)
          checks = 0
          ExecutionContext.new(deadline: 1, clock: -> { (checks += 1) >= target ? 1 : 0 })
        end

        def run_edit(env, path, pairs)
          edits = pairs.map { |(old_text, new_text)| { "oldText" => old_text, "newText" => new_text } }
          Edit.new(env:).call({ "path" => path, "edits" => edits })
        end
      end

      # THE PORT BRANCH: `edit`
      # routes only when BOTH flags are advertised — one consistent view
      # per call — reading the buffer whole through the port (existence is the port's answer; the disk gates are skipped), running the
      # unchanged ladder over the port's text and writing back through the
      # port under the same lock; with one flag both halves are the disk.
      class EditPortTest < Minitest::Test
        include RunnerTest::Helpers

        FsPort = Rho::Runner::FsPort

        def test_both_flags_read_the_buffer_and_write_it_back_leaving_the_disk_alone
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            path = File.join(root, "a.txt")
            File.write(path, "hello disk\n")
            port = RunnerTest::PortDouble.new(buffers: { path => "hello buffer\n" })
            result = ported(port, env, "a.txt", [["buffer", "editor"]])

            refute result.is_error, result.content
            assert_equal "Successfully replaced 1 block(s) in a.txt.", result.content
            assert_equal [[:read, path, { line: nil, limit: nil }], [:write, path, "hello editor\n"]], port.calls
            assert_equal "hello editor\n", port.buffers.fetch(path)
            assert_equal "hello disk\n", File.read(path), "the disk is the editor's to save"
          end
        end

        def test_existence_is_the_ports_answer_on_the_port_branch
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            path = File.join(root, "unsaved.txt")
            port = RunnerTest::PortDouble.new(buffers: { path => "new file\n" })
            result = ported(port, env, "unsaved.txt", [["new", "fresh"]])

            refute result.is_error, result.content
            assert_equal "fresh file\n", port.buffers.fetch(path)
            refute File.exist?(path)
          end
        end

        def test_bom_and_crlf_are_preserved_from_the_ports_text
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            path = File.join(root, "w.txt")
            port = RunnerTest::PortDouble.new(buffers: { path => "#{EditTest::BOM}one\r\ntwo\r\n" })
            result = ported(port, env, "w.txt", [["two", "2"]])

            refute result.is_error, result.content
            assert_equal "#{EditTest::BOM}one\r\n2\r\n", port.buffers.fetch(path)
          end
        end

        def test_one_flag_is_the_disk_for_both_halves
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            path = File.join(root, "a.txt")
            File.write(path, "hello disk\n")
            [RunnerTest::PortDouble.new(write: false), RunnerTest::PortDouble.new(read: false)].each do |port|
              File.write(path, "hello disk\n")
              result = ported(port, env, "a.txt", [["disk", "world"]])

              refute result.is_error, result.content
              assert_equal "hello world\n", File.read(path)
              assert_empty port.calls, "neither half asked the port"
            end
          end
        end

        def test_a_path_outside_the_root_set_is_the_disk
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            outside = File.join(File.dirname(root), "outside.txt")
            File.write(outside, "a\n")
            port = RunnerTest::PortDouble.new(buffers: { outside => "buffer\n" })

            refute ported(port, env, outside, [["a", "b"]]).is_error
            assert_equal "b\n", File.read(outside)
            assert_empty port.calls
          end
        end

        # ---- the error table ----

        def test_not_found_is_the_disk_for_both_halves
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            path = File.join(root, "a.txt")
            File.write(path, "hello disk\n")
            port = RunnerTest::PortDouble.new
            result = ported(port, env, "a.txt", [["disk", "world"]])

            refute result.is_error, result.content
            assert_equal "hello world\n", File.read(path)
            assert_equal [[:read, path, { line: nil, limit: nil }]], port.calls, "asked once, then the disk"
            assert_empty port.dropped
          end
        end

        def test_editor_refused_is_an_error_naming_the_client_and_nothing_is_written
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            path = File.join(root, "a.txt")
            File.write(path, "hello disk\n")
            port = RunnerTest::PortDouble.new(client: "zed", fail: { read: FsPort::Refused.new("binary buffer") })
            result = ported(port, env, "a.txt", [["disk", "world"]])

            assert result.is_error
            assert_equal "zed: binary buffer", result.content
            assert_equal "hello disk\n", File.read(path)
          end
        end

        def test_cancelled_is_the_runners_cancel_path
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            path = File.join(root, "a.txt")
            port = RunnerTest::PortDouble.new(buffers: { path => "a\n" }, fail: { write: FsPort::Cancelled.new("-32800") })
            assert_raises(Rho::Runner::ExecutionContext::Cancelled) { ported(port, env, "a.txt", [["a", "b"]]) }
            refute File.exist?(path)
          end
        end

        def test_unavailable_on_the_read_half_is_an_error_and_nothing_is_written
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            path = File.join(root, "a.txt")
            File.write(path, "hello disk\n")
            port = RunnerTest::PortDouble.new(client: "zed", fail: { read: FsPort::Unavailable.new("refused") })
            result = ported(port, env, "a.txt", [["disk", "world"]])

            assert result.is_error
            assert_equal "zed did not answer the read; nothing was written", result.content
            assert_equal "hello disk\n", File.read(path), "an edit never falls to disk after the port was asked"
            assert_equal ["refused"], port.dropped
          end
        end

        def test_unavailable_on_the_write_half_is_an_error_and_nothing_is_written
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            path = File.join(root, "a.txt")
            File.write(path, "hello disk\n")
            port = RunnerTest::PortDouble.new(client: "zed", buffers: { path => "hello buffer\n" },
              fail: { write: FsPort::Unavailable.new("timeout") })
            result = ported(port, env, "a.txt", [["buffer", "world"]])

            assert result.is_error
            assert_equal "zed did not confirm the write; nothing was written", result.content
            assert_equal "hello disk\n", File.read(path)
            assert_equal "hello buffer\n", port.buffers.fetch(path)
            assert_equal ["timeout"], port.dropped
          end
        end

        def test_the_ports_text_must_be_utf8
          with_ported_env(RunnerTest::PortDouble.new) do |env, root|
            path = File.join(root, "a.txt")
            port = RunnerTest::PortDouble.new(buffers: { path => "\xff\xfe".b })
            result = ported(port, env, "a.txt", [["a", "b"]])

            assert result.is_error
            assert_equal "Could not edit file: a.txt. File content must be valid UTF-8.", result.content
          end
        end

        private

        def ported(port, env, path, pairs)
          binding = ExecutionContext.current.binding
          context = ExecutionContext.new(tool_env: env, binding: binding, ports: ->(_anchor) { port })
          edits = pairs.map { |(old_text, new_text)| { "oldText" => old_text, "newText" => new_text } }
          ExecutionContext.with(context) { Edit.new(env:).call({ "path" => path, "edits" => edits }) }
        end
      end
    end
  end
end
