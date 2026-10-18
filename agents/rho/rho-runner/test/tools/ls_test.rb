require "test_helper"

module Rho
  class Runner
    module Tools
      class LsTest < Minitest::Test
        include RunnerTest::Helpers

        def test_description_matches_pi_verbatim
          assert_equal(
            "List directory contents. Returns entries sorted alphabetically, with '/' suffix for directories. " \
            "Includes dotfiles. Output is truncated to 500 entries or 50KB (whichever is hit first).",
            Ls::DESCRIPTION
          )
        end

        def test_lists_entries_sorted_case_insensitively_with_dir_suffix_and_dotfiles
          with_tool_env do |env, root|
            FileUtils.touch(File.join(root, "beta.txt"))
            FileUtils.touch(File.join(root, "Alpha.txt"))
            FileUtils.touch(File.join(root, ".hidden"))
            FileUtils.mkdir(File.join(root, "Zeta"))

            result = Ls.new(env:).call({})

            refute result.is_error
            assert_equal ".hidden\nAlpha.txt\nbeta.txt\nZeta/", result.content
            assert_nil result.structured_content
          end
        end

        def test_worker_context_preserves_case_insensitive_sorting
          with_tool_env do |env, root|
            FileUtils.touch(File.join(root, "beta.txt"))
            FileUtils.touch(File.join(root, "Alpha.txt"))
            FileUtils.touch(File.join(root, ".hidden"))
            FileUtils.mkdir(File.join(root, "Zeta"))

            result = ExecutionContext.with(ExecutionContext.new) { Ls.new(env:).call({}) }

            refute result.is_error
            assert_equal ".hidden\nAlpha.txt\nbeta.txt\nZeta/", result.content
          end
        end

        # The tool-result envelope rejects non-UTF-8 content, and directory
        # names arrive in the FILESYSTEM encoding: US-ASCII under a C locale
        # (the rho daemon can be spawned without a UTF-8 LANG), or bytes that
        # are not valid UTF-8. Stub the enumeration so this reproduces on a
        # UTF-8 host (APFS re-reads real names as UTF-8) — without the
        # force-encode/scrub the joined listing is not UTF-8 and the tool
        # result is rejected. The raw name still stats (bytes unchanged), the
        # non-existent scrubbed name is silently skipped.
        def test_listing_normalizes_non_utf8_directory_names
          with_tool_env do |env, root|
            FileUtils.touch(File.join(root, "note.txt"))
            ascii_tagged = "note.txt".dup.force_encoding(Encoding::US_ASCII)
            latin1_bytes = "caf\xE9.txt".dup.force_encoding(Encoding::ASCII_8BIT)

            result = with_each_child_returning(ascii_tagged, latin1_bytes) do
              Ls.new(env:).call({})
            end

            refute result.is_error, result.content
            assert_equal Encoding::UTF_8, result.content.encoding
            assert result.content.valid_encoding?, "the listing must be valid UTF-8"
            assert_includes result.content, "note.txt"
          end
        end

        def test_lists_explicit_relative_path
          with_tool_env do |env, root|
            sub = File.join(root, "sub")
            FileUtils.mkdir_p(File.join(sub, "nested"))
            FileUtils.touch(File.join(sub, "inner.txt"))
            FileUtils.touch(File.join(root, "outer.txt"))

            result = Ls.new(env:).call({ "path" => "sub" })

            refute result.is_error
            assert_equal "inner.txt\nnested/", result.content
          end
        end

        def test_path_not_found
          with_tool_env do |env, root|
            result = Ls.new(env:).call({ "path" => "missing" })

            assert result.is_error
            assert_equal "Path not found: #{File.join(root, "missing")}", result.content
          end
        end

        def test_not_a_directory
          with_tool_env do |env, root|
            file = File.join(root, "file.txt")
            FileUtils.touch(file)

            result = Ls.new(env:).call({ "path" => "file.txt" })

            assert result.is_error
            assert_equal "Not a directory: #{file}", result.content
          end
        end

        def test_entry_cap_appends_notice_and_structured_content
          with_tool_env do |env, root|
            %w[a.txt b.txt c.txt d.txt].each { |name| FileUtils.touch(File.join(root, name)) }

            result = Ls.new(env:).call({ "limit" => 2 })

            refute result.is_error
            assert_equal "a.txt\nb.txt\n\n[2 entries limit reached. Use limit=4 for more]", result.content
            assert_equal({ "entry_limit_reached" => true }, result.structured_content)
          end
        end

        def test_byte_cap_appends_notice_and_truncation_details
          with_tool_env do |env, root|
            touch_long_named_files(root, 300)

            result = Ls.new(env:).call({})

            refute result.is_error
            assert result.content.end_with?("\n\n[50.0KB limit reached]")
            truncation = result.structured_content.fetch("truncation")
            assert truncation.fetch("truncated")
            assert_equal :bytes, truncation.fetch("truncated_by")
            refute result.structured_content.key?("entry_limit_reached")
          end
        end

        def test_entry_cap_and_byte_cap_append_both_notices
          with_tool_env do |env, root|
            touch_long_named_files(root, 300)

            result = Ls.new(env:).call({ "limit" => 280 })

            refute result.is_error
            assert result.content.end_with?(
              "\n\n[280 entries limit reached. Use limit=560 for more. 50.0KB limit reached]"
            )
            assert_equal true, result.structured_content.fetch("entry_limit_reached")
            assert result.structured_content.fetch("truncation").fetch("truncated")
          end
        end

        def test_empty_directory
          with_tool_env do |env, root|
            result = Ls.new(env:).call({})

            refute result.is_error
            # NAMES WHERE IT LOOKED: an empty listing and a listing of the wrong
            # directory are otherwise the same four words.
            assert_equal "(empty directory: #{root})", result.content
            assert_nil result.structured_content
          end
        end

        # The floor is the SCHEMA's (the type and the range on `inputSchema`, no hand check or
        # coercion beside the layer that refuses before the handler); the sentence the model
        # reads is json_schemer's, naming the field and the bound.
        def test_the_limit_floor_is_the_schemas_refusal
          assert_equal "number at `/limit` is less than: 1", schema_refusal({ "limit" => 0 })
          assert_equal "number at `/limit` is less than: 1", schema_refusal({ "limit" => -1 })
          assert_equal "value at `/limit` is not an integer", schema_refusal({ "limit" => "1" })
          assert_equal "value at `/limit` is not an integer", schema_refusal({ "limit" => "abc" })
          assert_equal 1, Ls::SCHEMA.dig("properties", "limit", "minimum")
          assert_nil schema_refusal({ "limit" => 1 })
        end

        def schema_refusal(arguments)
          InputSchema.refusal(InputSchema.compile(Ls::SCHEMA), arguments)
        end

        def test_cancellation_interrupts_directory_enumeration_before_the_entry_limit
          with_tool_env do |env, root|
            touch_numbered_files(root, 50)
            context = deadline_context_on_check(4)

            assert_raises(ExecutionContext::Cancelled) do
              ExecutionContext.with(context) { Ls.new(env:).call({ "limit" => 1 }) }
            end
          end
        end

        def test_cancellation_interrupts_directory_sorting
          with_tool_env do |env, root|
            count = 300
            touch_numbered_files(root, count)
            # Behavioral pin, not an exact check sequence: expire the
            # deadline just past the per-entry enumeration checks, so the
            # first observer must be one of the comparator's bounded
            # checkpoints (~count*log2(count)/128 of them) — sorting itself
            # is cancellable, wherever the surrounding constant checks move.
            context = deadline_context_on_check(count + 4)

            assert_raises(ExecutionContext::Cancelled) do
              ExecutionContext.with(context) { Ls.new(env:).call({}) }
            end
          end
        end

        private

        def deadline_context_on_check(target)
          checks = 0
          ExecutionContext.new(deadline: 1, clock: -> { (checks += 1) >= target ? 1 : 0 })
        end

        # Simulate a filesystem/locale that hands Dir.each_child names not
        # tagged UTF-8 (no minitest/mock in this toolchain, so override the
        # singleton method directly and restore it).
        def with_each_child_returning(*names)
          original = Dir.singleton_method(:each_child)
          Dir.singleton_class.send(:define_method, :each_child) do |_dir, &block|
            names.each { |name| block.call(name) }
          end
          begin
            yield
          ensure
            Dir.singleton_class.send(:define_method, :each_child, original)
          end
        end

        def touch_numbered_files(root, count)
          names = Array.new(count) { |index| File.join(root, format("entry-%03d", index)) }
          FileUtils.touch(names)
        end

        # Enough long-named entries that the joined listing crosses the 50KB
        # byte cap while staying under the default 500-entry cap.
        def touch_long_named_files(root, count)
          names = Array.new(count) { |i| File.join(root, format("%03d-#{"x" * 200}", i)) }
          FileUtils.touch(names)
        end
      end
    end
  end
end
