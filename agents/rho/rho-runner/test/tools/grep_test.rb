require "test_helper"
require "rbconfig"
require "timeout"

module Rho
  class Runner
    module Tools
      # Exercises the real rg binary end to end: formatting, limits, context
      # blocks, truncation notices, and the (verified) gitignore semantics.
      class GrepTest < Minitest::Test
        include RunnerTest::Helpers

        def grep(env, args)
          Grep.new(env:).call(args)
        end

        def test_matches_nested_directories_with_relative_paths
          with_tool_env do |env, root|
            File.write(File.join(root, "top.txt"), "alpha needle\nbeta\n")
            FileUtils.mkdir_p(File.join(root, "sub/deep"))
            File.write(File.join(root, "sub/deep/inner.txt"), "first\nneedle here\n")

            result = grep(env, { "pattern" => "needle" })
            refute result.is_error
            assert_includes result.content, "top.txt:1: alpha needle"
            assert_includes result.content, "sub/deep/inner.txt:2: needle here"
            assert_nil result.structured_content
          end
        end

        def test_single_file_path_displays_basename
          with_tool_env do |env, root|
            FileUtils.mkdir_p(File.join(root, "sub"))
            File.write(File.join(root, "sub/notes.txt"), "plain line\nneedle two\n")

            result = grep(env, { "pattern" => "needle", "path" => "sub/notes.txt" })
            refute result.is_error
            assert_equal "notes.txt:2: needle two", result.content
          end
        end

        def test_ignore_case
          with_tool_env do |env, root|
            File.write(File.join(root, "case.txt"), "NEEDLE HERE\n")

            assert_match(/\ANo matches found in /, grep(env, { "pattern" => "needle" }).content)

            result = grep(env, { "pattern" => "needle", "ignoreCase" => true })
            refute result.is_error
            assert_equal "case.txt:1: NEEDLE HERE", result.content
          end
        end

        def test_literal_pattern_matches_regex_special_characters
          with_tool_env do |env, root|
            File.write(File.join(root, "lit.txt"), "val = a.b(x)\naXbY\n")

            result = grep(env, { "pattern" => "a.b(", "literal" => true })
            refute result.is_error
            assert_equal "lit.txt:1: val = a.b(x)", result.content
          end
        end

        def test_invalid_regex_returns_rg_error
          with_tool_env do |env, root|
            File.write(File.join(root, "lit.txt"), "val = a.b(x)\n")

            result = grep(env, { "pattern" => "a.b(" })
            assert result.is_error
            assert_includes result.content, "regex parse error"
          end
        end

        def test_glob_filter
          with_tool_env do |env, root|
            File.write(File.join(root, "a.rb"), "needle\n")
            File.write(File.join(root, "a.txt"), "needle\n")

            result = grep(env, { "pattern" => "needle", "glob" => "*.rb" })
            refute result.is_error
            assert_equal "a.rb:1: needle", result.content
          end
        end

        def test_limit_reached_notice_and_flag
          with_tool_env do |env, root|
            File.write(File.join(root, "match.txt"), (1..5).map { |n| "needle #{n}\n" }.join)

            result = grep(env, { "pattern" => "needle", "limit" => 2 })
            refute result.is_error
            expected =
              "match.txt:1: needle 1\n" \
              "match.txt:2: needle 2" \
              "\n\n[2 matches limit reached. Use limit=4 for more, or refine pattern]"
            assert_equal expected, result.content
            assert_equal({ "match_limit_reached" => true }, result.structured_content)
          end
        end

        # The caps are the SCHEMA's (types and ranges on `inputSchema`, no hand check beside the
        # layer that refuses before the handler); the sentence the model reads is
        # json_schemer's, naming the field and the bound.
        def test_the_context_cap_is_the_schemas_refusal
          refusal = schema_refusal({ "pattern" => "needle", "context" => Grep::MAX_CONTEXT + 1 })

          assert_equal "number at `/context` is greater than: #{Grep::MAX_CONTEXT}", refusal
          assert_equal Grep::MAX_CONTEXT, Grep::SCHEMA.dig("properties", "context", "maximum")
          assert_nil schema_refusal({ "pattern" => "needle", "context" => 0 })
        end

        def test_the_limit_range_is_the_schemas_refusal
          assert_equal "number at `/limit` is greater than: #{Grep::MAX_LIMIT}",
            schema_refusal({ "pattern" => "needle", "limit" => Grep::MAX_LIMIT + 1 })
          assert_equal "number at `/limit` is less than: 1", schema_refusal({ "pattern" => "needle", "limit" => 0 })
          assert_equal "value at `/limit` is not an integer", schema_refusal({ "pattern" => "needle", "limit" => "3" })
          assert_equal Grep::MAX_LIMIT, Grep::SCHEMA.dig("properties", "limit", "maximum")
        end

        def schema_refusal(arguments)
          InputSchema.refusal(InputSchema.compile(Grep::SCHEMA), arguments)
        end

        def test_context_blocks_use_dash_separators_around_match
          with_tool_env do |env, root|
            File.write(File.join(root, "ctx.txt"), <<~TEXT)
              line one
              line two
              has needle here
              line four
              line five
            TEXT

            result = grep(env, { "pattern" => "needle", "context" => 1 })
            refute result.is_error
            expected =
              "ctx.txt-2- line two\n" \
              "ctx.txt:3: has needle here\n" \
              "ctx.txt-4- line four"
            assert_equal expected, result.content
            assert_nil result.structured_content
          end
        end

        def test_context_blocks_stream_the_matched_file_without_a_whole_file_read
          with_tool_env do |env, root|
            path = File.join(root, "large-context.txt")
            File.open(path, "wb") do |file|
              10_000.times { |index| file.puts("line #{index}") }
              file.puts("needle")
              file.puts("after")
            end

            result = forbid_file_read do
              grep(env, { "pattern" => "needle", "context" => 1 })
            end

            refute result.is_error
            assert_equal "large-context.txt-10000- line 9999\n" \
                         "large-context.txt:10001: needle\n" \
                         "large-context.txt-10002- after", result.content
          end
        end

        def test_multiple_context_matches_scan_a_large_file_once
          with_tool_env do |env, root|
            path = File.join(root, "many-contexts.txt")
            File.open(path, "wb") do |file|
              50_000.times do |index|
                file.puts(index == 99 || index == 199 || index == 299 ? "needle #{index}" : "line #{index}")
              end
            end

            result, open_count, read_count = count_context_file_io do
              grep(env, { "pattern" => "needle", "context" => 1 })
            end

            refute result.is_error
            assert_includes result.content, "many-contexts.txt:100: needle 99"
            assert_includes result.content, "many-contexts.txt:200: needle 199"
            assert_includes result.content, "many-contexts.txt:300: needle 299"
            assert_equal 1, open_count
            assert_equal 1, read_count
          end
        end

        def test_long_lines_truncated_with_notice
          with_tool_env do |env, root|
            line = "needle #{"x" * 600}"
            File.write(File.join(root, "long.txt"), "#{line}\n")

            result = grep(env, { "pattern" => "needle" })
            refute result.is_error
            expected =
              "long.txt:1: #{line[0, 500]}... [truncated]" \
              "\n\n[Some lines truncated to 500 chars. Use read tool to see full lines]"
            assert_equal expected, result.content
            assert_equal({ "lines_truncated" => true }, result.structured_content)
          end
        end

        def test_long_context_lines_are_actually_truncated
          with_tool_env do |env, root|
            line = "needle #{"x" * 600}"
            File.write(File.join(root, "long-context.txt"), "before\n#{line}\nafter\n")

            result = grep(env, { "pattern" => "needle", "context" => 1 })

            refute result.is_error
            expected =
              "long-context.txt-1- before\n" \
              "long-context.txt:2: #{line[0, 500]}... [truncated]\n" \
              "long-context.txt-3- after\n\n" \
              "[Some lines truncated to 500 chars. Use read tool to see full lines]"
            assert_equal expected, result.content
            assert_equal({ "lines_truncated" => true }, result.structured_content)
          end
        end

        def test_all_notices_join_into_one_bracket
          with_tool_env do |env, root|
            # 120 long matching lines: hits the 100-match limit, each line is
            # truncated to 500 chars, and the joined output tops 50KB — all
            # three notices land in a single bracket joined by ". ".
            content = (1..120).map { |n| "needle#{n} #{"y" * 600}\n" }.join
            File.write(File.join(root, "big.txt"), content)

            result = grep(env, { "pattern" => "needle" })
            refute result.is_error
            assert result.content.end_with?(
              "\n\n[100 matches limit reached. Use limit=200 for more, or refine pattern. " \
              "50.0KB limit reached. " \
              "Some lines truncated to 500 chars. Use read tool to see full lines]"
            )
            details = result.structured_content
            assert_equal true, details["match_limit_reached"]
            assert_equal true, details["lines_truncated"]
            assert_equal true, details.dig("truncation", "truncated")
            assert_operator details.dig("truncation", "output_bytes"), :<=, 50 * 1024
          end
        end

        def test_zero_matches
          with_tool_env do |env, root|
            File.write(File.join(root, "a.txt"), "nothing to see\n")

            result = grep(env, { "pattern" => "needle" })
            refute result.is_error
            assert_match(/\ANo matches found in /, result.content)
            assert_nil result.structured_content
          end
        end

        # Verified against ripgrep 15: .gitignore is respected only when the
        # search root is inside a git repository (rg's --require-git default).
        def test_gitignore_respected_inside_git_repo
          with_tool_env do |env, root|
            system("git", "init", "-q", root, exception: true)
            write_gitignore_fixture(root)

            result = grep(env, { "pattern" => "needle" })
            refute result.is_error
            assert_includes result.content, "kept.txt:1: needle kept"
            refute_includes result.content, "skip.txt"
          end
        end

        def test_gitignore_not_respected_outside_git_repo
          with_tool_env do |env, root|
            write_gitignore_fixture(root)

            result = grep(env, { "pattern" => "needle" })
            refute result.is_error
            assert_includes result.content, "kept.txt:1: needle kept"
            assert_includes result.content, "ignored/skip.txt:1: needle ignored"
          end
        end

        def test_path_not_found
          with_tool_env do |env, _root|
            result = grep(env, { "pattern" => "needle", "path" => "missing-dir" })
            assert result.is_error
            assert_includes result.content, "Path not found: "
          end
        end

        def test_missing_rg_reports_install_hint
          with_tool_env do |env, root|
            File.write(File.join(root, "a.txt"), "needle\n")
            original_path = ENV["PATH"]
            begin
              ENV["PATH"] = ""
              result = grep(env, { "pattern" => "needle" })
              assert result.is_error
              assert_includes result.content, "Install ripgrep"
            ensure
              ENV["PATH"] = original_path
            end
          end
        end

        def test_cancellation_kills_and_reaps_the_fake_ripgrep_process_group
          with_tool_env do |env, _root|
            with_blocking_executable("rg") do |ready, leader_terminated, descendant_terminated, release,
                                               leader_terminated_writer, descendant_terminated_writer|
              task = nil
              cancellation = nil
              cancellation_started_reader = nil
              cancellation_started_writer = nil
              leader_pid = nil
              descendant_pid = nil
              begin
                task = run_async { grep(env, { "pattern" => "needle" }) }
                leader_pid = Integer(ready.gets)
                descendant_pid = Integer(ready.gets)
                leader_process_group = Process.getpgid(leader_pid)
                descendant_process_group = Process.getpgid(descendant_pid)
                leader_terminated_writer.close
                descendant_terminated_writer.close

                cancellation_started_reader, cancellation_started_writer = IO.pipe
                cancellation = run_async do
                  cancellation_started_writer.write(".")
                  task.stop
                ensure
                  cancellation_started_writer.close unless cancellation_started_writer.closed?
                end
                cancellation_started_reader.read(1)
                assert IO.select([leader_terminated], nil, nil, 1), "cancellation must terminate the fake leader"
                assert_nil leader_terminated.read(1)
                assert IO.select([descendant_terminated], nil, nil, 1),
                       "cancellation must terminate the fake leader's child"
                assert_nil descendant_terminated.read(1)
                # Either lawful end of a cancelled handler (a Result, or `Cancelled`
                # when the checkpoint won the race) — `settle`, never `wait`: the
                # re-raise failed this pin one run in five under load.
                task.settle
                cancellation.wait

                refute_equal leader_pid, leader_process_group
                assert_equal leader_process_group, descendant_process_group
                assert_process_gone(leader_pid)
                assert_process_gone(descendant_pid)
              ensure
                release&.close unless release&.closed?
                cancellation&.wait
                task&.stop unless task&.finished?
                task&.settle
                terminate_process(leader_pid)
                terminate_process(descendant_pid)
                cancellation_started_reader&.close unless cancellation_started_reader&.closed?
                cancellation_started_writer&.close unless cancellation_started_writer&.closed?
              end
            end
          end
        end

        def test_normal_exit_cleans_a_long_lived_descendant_after_reaping_the_leader
          assert_exiting_ripgrep_cleans_descendant(stdout: "", stderr: "", exit_status: 0) do |result|
            refute result.is_error
            assert_match(/\ANo matches found in /, result.content)
          end
        end

        def test_error_exit_cleans_a_long_lived_descendant_after_reaping_the_leader
          assert_exiting_ripgrep_cleans_descendant(
            stdout: "", stderr: "synthetic rg failure\n", exit_status: 2
          ) do |result|
            assert result.is_error
            assert_equal "synthetic rg failure", result.content
          end
        end

        def test_cancellation_returns_while_a_detached_process_holds_stderr_open
          assert_cancellation_returns_with_detached_stderr_holder("rg") do |env|
            grep(env, { "pattern" => "needle" })
          end
        end

        # A single giant match line (a minified file, say) must not fail the
        # whole search: that match is skipped with a visible notice while
        # every other match survives — the advertised long-lines-truncated
        # contract stays honest.
        def test_oversized_ripgrep_json_line_is_skipped_with_a_notice
          max_bytes = Subprocess::MAX_STDOUT_LINE_BYTES
          source = <<~RUBY
            require "json"
            oversized = {
              "type" => "match",
              "data" => {
                "path" => { "text" => "huge.txt" },
                "line_number" => 1,
                "lines" => { "text" => "x" * #{max_bytes} },
              },
            }
            normal = {
              "type" => "match",
              "data" => {
                "path" => { "text" => "small.txt" },
                "line_number" => 3,
                "lines" => { "text" => "needle here" },
              },
            }
            STDOUT.puts(JSON.generate(oversized))
            STDOUT.puts(JSON.generate(normal))
          RUBY

          with_tool_env do |env, _root|
            with_fake_executable("rg", source) do
              result = grep(env, { "pattern" => "needle" })

              refute result.is_error
              assert_includes result.content, "small.txt:3: needle here"
              assert_includes result.content, "1 match(es) skipped: output line over #{max_bytes} bytes"
              assert_equal 1, result.structured_content&.dig("oversized_lines_skipped")
            end
          end
        end

        def test_oversized_ripgrep_stderr_returns_a_stable_truncated_error
          max_bytes = Truncation::DEFAULT_MAX_BYTES
          notice = "[stderr truncated after #{max_bytes} bytes]"
          source = <<~RUBY
            STDERR.write("e" * #{max_bytes + 1024})
            exit(2)
          RUBY

          with_tool_env do |env, _root|
            with_fake_executable("rg", source) do
              result = grep(env, { "pattern" => "needle" })

              assert result.is_error
              assert result.content.end_with?("\n#{notice}")
              assert_equal max_bytes + 1 + notice.bytesize, result.content.bytesize
            end
          end
        end

        private

        def write_gitignore_fixture(root)
          File.write(File.join(root, ".gitignore"), "ignored/\n")
          FileUtils.mkdir_p(File.join(root, "ignored"))
          File.write(File.join(root, "ignored/skip.txt"), "needle ignored\n")
          File.write(File.join(root, "kept.txt"), "needle kept\n")
        end

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

        def count_context_file_io
          opens = 0
          reads = 0
          trace = TracePoint.new(:call, :c_call) do |event|
            opens += 1 if event.self.equal?(File) && event.method_id == :open
            reads += 1 if event.self.is_a?(File) && event.method_id == :read
          end
          result = trace.enable { yield }
          [result, opens, reads]
        ensure
          trace&.disable
        end

        def with_blocking_executable(name)
          with_tmpdir do |bin_dir|
            executable = File.join(bin_dir, name)
            File.write(executable, <<~RUBY)
              #!#{RbConfig.ruby}
              ready = IO.for_fd(Integer(ENV.fetch("RHO_RUNNER_TEST_READY_FD")))
              leader_terminated = IO.for_fd(Integer(ENV.fetch("RHO_RUNNER_TEST_LEADER_TERMINATED_FD")))
              descendant_terminated = IO.for_fd(Integer(ENV.fetch("RHO_RUNNER_TEST_DESCENDANT_TERMINATED_FD")))
              child_code = <<~'CHILD'
                descendant_terminated = IO.for_fd(Integer(ENV.fetch("RHO_RUNNER_TEST_DESCENDANT_TERMINATED_FD")))
                IO.for_fd(Integer(ENV.fetch("RHO_RUNNER_TEST_RELEASE_FD"))).read
              CHILD
              child_pid = Process.spawn(
                #{RbConfig.ruby.dump}, "-e", child_code,
                ready => :close,
                leader_terminated => :close,
                close_others: false
              )
              descendant_terminated.close
              ready.puts(Process.pid, child_pid)
              ready.flush
              IO.for_fd(Integer(ENV.fetch("RHO_RUNNER_TEST_RELEASE_FD"))).read
            RUBY
            FileUtils.chmod("u+x", executable)

            ready_reader, ready_writer = IO.pipe
            leader_terminated_reader, leader_terminated_writer = IO.pipe
            descendant_terminated_reader, descendant_terminated_writer = IO.pipe
            release_reader, release_writer = IO.pipe
            ready_writer.close_on_exec = false
            leader_terminated_writer.close_on_exec = false
            descendant_terminated_writer.close_on_exec = false
            release_reader.close_on_exec = false
            original_path = ENV["PATH"]
            original_ready_fd = ENV["RHO_RUNNER_TEST_READY_FD"]
            original_leader_terminated_fd = ENV["RHO_RUNNER_TEST_LEADER_TERMINATED_FD"]
            original_descendant_terminated_fd = ENV["RHO_RUNNER_TEST_DESCENDANT_TERMINATED_FD"]
            original_release_fd = ENV["RHO_RUNNER_TEST_RELEASE_FD"]
            ENV["PATH"] = [bin_dir, original_path].compact.join(File::PATH_SEPARATOR)
            ENV["RHO_RUNNER_TEST_READY_FD"] = ready_writer.fileno.to_s
            ENV["RHO_RUNNER_TEST_LEADER_TERMINATED_FD"] = leader_terminated_writer.fileno.to_s
            ENV["RHO_RUNNER_TEST_DESCENDANT_TERMINATED_FD"] = descendant_terminated_writer.fileno.to_s
            ENV["RHO_RUNNER_TEST_RELEASE_FD"] = release_reader.fileno.to_s

            yield ready_reader, leader_terminated_reader, descendant_terminated_reader, release_writer,
                  leader_terminated_writer, descendant_terminated_writer
          ensure
            ENV["PATH"] = original_path
            ENV["RHO_RUNNER_TEST_READY_FD"] = original_ready_fd
            ENV["RHO_RUNNER_TEST_LEADER_TERMINATED_FD"] = original_leader_terminated_fd
            ENV["RHO_RUNNER_TEST_DESCENDANT_TERMINATED_FD"] = original_descendant_terminated_fd
            ENV["RHO_RUNNER_TEST_RELEASE_FD"] = original_release_fd
            [
              ready_reader, ready_writer,
              leader_terminated_reader, leader_terminated_writer,
              descendant_terminated_reader, descendant_terminated_writer,
              release_reader, release_writer,
            ].compact.each do |io|
              io.close unless io.closed?
            end
          end
        end

        def assert_exiting_ripgrep_cleans_descendant(stdout:, stderr:, exit_status:)
          with_tool_env do |env, _root|
            with_exiting_executable_and_descendant(
              "rg", stdout:, stderr:, exit_status:
            ) do |ready, descendant_terminated, descendant_terminated_writer, release|
              task = nil
              leader_pid = nil
              descendant_pid = nil
              begin
                task = run_async { grep(env, { "pattern" => "needle" }) }
                leader_pid = Integer(ready.gets)
                descendant_pid = Integer(ready.gets)
                descendant_terminated_writer.close

                result = task.wait

                yield result
                assert IO.select([descendant_terminated], nil, nil, 1),
                       "tool exit must terminate the fake leader's child"
                assert_nil descendant_terminated.read(1)
                assert_process_gone(descendant_pid)
              ensure
                release&.close unless release&.closed?
                task&.stop unless task&.finished?
                task&.wait
                terminate_process(leader_pid)
                terminate_process(descendant_pid)
              end
            end
          end
        end

        def with_exiting_executable_and_descendant(name, stdout:, stderr:, exit_status:)
          with_tmpdir do |bin_dir|
            executable = File.join(bin_dir, name)
            File.write(executable, <<~RUBY)
              #!#{RbConfig.ruby}
              ready = IO.for_fd(Integer(ENV.fetch("RHO_RUNNER_TEST_EXIT_READY_FD")))
              descendant_terminated = IO.for_fd(
                Integer(ENV.fetch("RHO_RUNNER_TEST_EXIT_DESCENDANT_TERMINATED_FD"))
              )
              child_code = <<~'CHILD'
                descendant_terminated = IO.for_fd(
                  Integer(ENV.fetch("RHO_RUNNER_TEST_EXIT_DESCENDANT_TERMINATED_FD"))
                )
                IO.for_fd(Integer(ENV.fetch("RHO_RUNNER_TEST_EXIT_RELEASE_FD"))).read
              CHILD
              child_pid = Process.spawn(
                #{RbConfig.ruby.dump}, "-e", child_code,
                ready => :close,
                out: File::NULL,
                err: File::NULL,
                close_others: false
              )
              descendant_terminated.close
              ready.puts(Process.pid, child_pid)
              ready.flush
              STDOUT.write(#{stdout.dump})
              STDERR.write(#{stderr.dump})
              exit(#{exit_status})
            RUBY
            FileUtils.chmod("u+x", executable)

            ready_reader, ready_writer = IO.pipe
            descendant_terminated_reader, descendant_terminated_writer = IO.pipe
            release_reader, release_writer = IO.pipe
            ready_writer.close_on_exec = false
            descendant_terminated_writer.close_on_exec = false
            release_reader.close_on_exec = false
            original_path = ENV["PATH"]
            original_ready_fd = ENV["RHO_RUNNER_TEST_EXIT_READY_FD"]
            original_descendant_terminated_fd = ENV["RHO_RUNNER_TEST_EXIT_DESCENDANT_TERMINATED_FD"]
            original_release_fd = ENV["RHO_RUNNER_TEST_EXIT_RELEASE_FD"]
            ENV["PATH"] = [bin_dir, original_path].compact.join(File::PATH_SEPARATOR)
            ENV["RHO_RUNNER_TEST_EXIT_READY_FD"] = ready_writer.fileno.to_s
            ENV["RHO_RUNNER_TEST_EXIT_DESCENDANT_TERMINATED_FD"] = descendant_terminated_writer.fileno.to_s
            ENV["RHO_RUNNER_TEST_EXIT_RELEASE_FD"] = release_reader.fileno.to_s

            yield ready_reader, descendant_terminated_reader, descendant_terminated_writer, release_writer
          ensure
            ENV["PATH"] = original_path
            ENV["RHO_RUNNER_TEST_EXIT_READY_FD"] = original_ready_fd
            ENV["RHO_RUNNER_TEST_EXIT_DESCENDANT_TERMINATED_FD"] = original_descendant_terminated_fd
            ENV["RHO_RUNNER_TEST_EXIT_RELEASE_FD"] = original_release_fd
            [
              ready_reader, ready_writer,
              descendant_terminated_reader, descendant_terminated_writer,
              release_reader, release_writer,
            ].compact.each do |io|
              io.close unless io.closed?
            end
          end
        end

        def assert_cancellation_returns_with_detached_stderr_holder(name)
          with_tool_env do |env, _root|
            with_detached_stderr_holder(name) do |ready, holder_terminated, holder_terminated_writer, release|
              baseline_threads = Thread.list.map(&:object_id)
              task = nil
              leader_pid = nil
              holder_pid = nil
              timed_out = false
              begin
                task = run_async { yield env }
                leader_pid = Integer(ready.gets)
                holder_pid = Integer(ready.gets)
                holder_terminated_writer.close
                refute_equal Process.getpgid(leader_pid), Process.getpgid(holder_pid)

                begin
                  Timeout.timeout(1) { task.stop }
                rescue Timeout::Error
                  timed_out = true
                ensure
                  release&.close unless release&.closed?
                  terminate_process(holder_pid)
                  task&.stop unless task&.finished?
                  task&.settle
                end

                refute timed_out, "cancellation must not wait for an unrelated stderr holder"
                # NOTHING OF OURS LINGERS. The predecessor could assert this
                # over every thread because its handler ran on a fiber;
                # ours runs on one, and `Timeout` spawns another — both are
                # this test's own scaffolding, so the check is scoped to
                # what the TOOL might have left behind.
                leaked = Thread.list.reject do |thread|
                  baseline_threads.include?(thread.object_id) ||
                    thread.to_s.include?("timeout.rb") ||
                    thread == Thread.current
                end
                assert_empty leaked, "the tool must not leave a reader thread behind"
              ensure
                release&.close unless release&.closed?
                terminate_process(holder_pid)
                task&.stop unless task&.finished?
                task&.settle
                terminate_process(leader_pid)
              end

              assert IO.select([holder_terminated], nil, nil, 1), "test cleanup must release the stderr holder"
              assert_nil holder_terminated.read(1)
            end
          end
        end

        def with_detached_stderr_holder(name)
          with_tmpdir do |bin_dir|
            executable = File.join(bin_dir, name)
            File.write(executable, <<~RUBY)
              #!#{RbConfig.ruby}
              ready = IO.for_fd(Integer(ENV.fetch("RHO_RUNNER_TEST_HOLDER_READY_FD")))
              holder_terminated = IO.for_fd(Integer(ENV.fetch("RHO_RUNNER_TEST_HOLDER_TERMINATED_FD")))
              holder_code = <<~'HOLDER'
                holder_terminated = IO.for_fd(Integer(ENV.fetch("RHO_RUNNER_TEST_HOLDER_TERMINATED_FD")))
                IO.for_fd(Integer(ENV.fetch("RHO_RUNNER_TEST_HOLDER_RELEASE_FD"))).read
              HOLDER
              holder_pid = Process.spawn(
                #{RbConfig.ruby.dump}, "-e", holder_code,
                out: File::NULL,
                pgroup: true,
                close_others: false
              )
              holder_terminated.close
              ready.puts(Process.pid, holder_pid)
              ready.flush
              IO.for_fd(Integer(ENV.fetch("RHO_RUNNER_TEST_HOLDER_RELEASE_FD"))).read
            RUBY
            FileUtils.chmod("u+x", executable)

            ready_reader, ready_writer = IO.pipe
            holder_terminated_reader, holder_terminated_writer = IO.pipe
            release_reader, release_writer = IO.pipe
            ready_writer.close_on_exec = false
            holder_terminated_writer.close_on_exec = false
            release_reader.close_on_exec = false
            original_path = ENV["PATH"]
            original_ready_fd = ENV["RHO_RUNNER_TEST_HOLDER_READY_FD"]
            original_holder_terminated_fd = ENV["RHO_RUNNER_TEST_HOLDER_TERMINATED_FD"]
            original_release_fd = ENV["RHO_RUNNER_TEST_HOLDER_RELEASE_FD"]
            ENV["PATH"] = [bin_dir, original_path].compact.join(File::PATH_SEPARATOR)
            ENV["RHO_RUNNER_TEST_HOLDER_READY_FD"] = ready_writer.fileno.to_s
            ENV["RHO_RUNNER_TEST_HOLDER_TERMINATED_FD"] = holder_terminated_writer.fileno.to_s
            ENV["RHO_RUNNER_TEST_HOLDER_RELEASE_FD"] = release_reader.fileno.to_s

            yield ready_reader, holder_terminated_reader, holder_terminated_writer, release_writer
          ensure
            ENV["PATH"] = original_path
            ENV["RHO_RUNNER_TEST_HOLDER_READY_FD"] = original_ready_fd
            ENV["RHO_RUNNER_TEST_HOLDER_TERMINATED_FD"] = original_holder_terminated_fd
            ENV["RHO_RUNNER_TEST_HOLDER_RELEASE_FD"] = original_release_fd
            [
              ready_reader, ready_writer,
              holder_terminated_reader, holder_terminated_writer,
              release_reader, release_writer,
            ].compact.each do |io|
              io.close unless io.closed?
            end
          end
        end

        def with_fake_executable(name, source)
          with_tmpdir do |bin_dir|
            executable = File.join(bin_dir, name)
            File.write(executable, "#!#{RbConfig.ruby}\n#{source}")
            FileUtils.chmod("u+x", executable)
            original_path = ENV["PATH"]
            ENV["PATH"] = [bin_dir, original_path].compact.join(File::PATH_SEPARATOR)

            yield
          ensure
            ENV["PATH"] = original_path
          end
        end

        def terminate_process(pid)
          return unless pid

          Process.kill("KILL", pid)
        rescue Errno::ESRCH
          nil
        end
      end
    end
  end
end
