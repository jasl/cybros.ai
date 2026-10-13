require "test_helper"
require "rbconfig"
require "timeout"

module Rho
  class Runner
    module Tools
      # Exercises the real fd binary; with_tool_env roots live under the
      # system tmpdir, outside any git repo, so the --no-require-git leg of
      # the ancestor walk is the default in these tests.
      class FindTest < Minitest::Test
        include RunnerTest::Helpers

        def test_simple_glob_finds_nested_files_with_relative_paths
          with_tool_env do |env, root|
            write_file(root, "a.rb")
            write_file(root, "src/deep/b.rb")
            write_file(root, "notes.txt")
            result = Find.new(env:).call({ "pattern" => "*.rb" })
            refute result.is_error
            assert_equal ["a.rb", "src/deep/b.rb"], result.content.split("\n").sort
            assert_nil result.structured_content
          end
        end

        def test_pattern_with_slash_matches_via_full_path_prefixing
          with_tool_env do |env, root|
            write_file(root, "src/direct.txt")
            write_file(root, "src/x/a.txt")
            write_file(root, "other/b.txt")
            write_file(root, "c.txt")
            result = Find.new(env:).call({ "pattern" => "src/**/*.txt" })
            refute result.is_error
            assert_equal ["src/direct.txt", "src/x/a.txt"], result.content.split("\n").sort
          end
        end

        def test_limit_reached_appends_notice_and_flag
          with_tool_env do |env, root|
            5.times { |i| write_file(root, "f#{i}.rb") }
            result = Find.new(env:).call({ "pattern" => "*.rb", "limit" => 3 })
            refute result.is_error
            body, notice = result.content.split("\n\n", 2)
            assert_equal 3, body.split("\n").length
            assert_equal "[3 results limit reached. Use limit=6 for more, or refine pattern]", notice
            assert_equal({ "result_limit_reached" => true }, result.structured_content)
          end
        end

        def test_maximum_limit_reached_suggests_refining_pattern_or_path
          with_tool_env do |env, root|
            Find::MAX_LIMIT.times { |i| write_file(root, "f#{i}.rb") }

            result = Find.new(env:).call({ "pattern" => "*.rb", "limit" => Find::MAX_LIMIT })

            refute result.is_error
            assert result.content.end_with?(
              "\n\n[#{Find::MAX_LIMIT} results limit reached. Refine pattern or path to reduce results]"
            )
            refute_includes result.content, "limit=#{Find::MAX_LIMIT * 2}"
            assert_equal({ "result_limit_reached" => true }, result.structured_content)
          end
        end

        def test_zero_results_message
          with_tool_env do |env, root|
            write_file(root, "a.rb")
            result = Find.new(env:).call({ "pattern" => "*.zig" })
            refute result.is_error
            assert_equal "No files found matching pattern under #{root}", result.content
            assert_nil result.structured_content
          end
        end

        def test_gitignore_is_honored_outside_a_git_repo
          with_tool_env do |env, root|
            File.write(File.join(root, ".gitignore"), "ignored/\n")
            write_file(root, "ignored/x.rb")
            write_file(root, "kept.rb")
            result = Find.new(env:).call({ "pattern" => "*.rb" })
            refute result.is_error
            assert_equal "kept.rb", result.content
          end
        end

        def test_gitignore_is_honored_inside_a_git_repo
          with_tool_env do |env, root|
            FileUtils.mkdir_p(File.join(root, ".git"))
            File.write(File.join(root, ".gitignore"), "ignored/\n")
            write_file(root, "ignored/x.rb")
            write_file(root, "kept.rb")
            result = Find.new(env:).call({ "pattern" => "*.rb" })
            refute result.is_error
            assert_equal "kept.rb", result.content
          end
        end

        def test_explicit_path_argument_relativizes_against_that_directory
          with_tool_env do |env, root|
            write_file(root, "sub/inner/a.rb")
            write_file(root, "outside.rb")
            result = Find.new(env:).call({ "pattern" => "*.rb", "path" => "sub" })
            refute result.is_error
            assert_equal "inner/a.rb", result.content
          end
        end

        def test_trailing_whitespace_in_a_filename_is_preserved
          with_tool_env do |env, root|
            write_file(root, "report.rb ")

            result = Find.new(env:).call({ "pattern" => "*.rb " })

            refute result.is_error
            assert_equal "report.rb ", result.content
          end
        end

        def test_newline_in_a_filename_keeps_one_display_record_and_an_exact_structured_path
          with_tool_env do |env, root|
            write_file(root, "line\nbreak.rb")

            result = Find.new(env:).call({ "pattern" => "*.rb" })

            refute result.is_error
            assert_equal "line\\nbreak.rb", result.content
            assert_equal ["line\nbreak.rb"], result.structured_content.fetch("paths")
          end
        end

        def test_root_search_path_does_not_drop_the_first_path_character
          source = <<~'RUBY'
            STDOUT.write("/tmp/example\0/var/log/\0")
          RUBY

          with_tool_env do |env, _root|
            with_fake_executable("fd", source) do
              result = Find.new(env:).call({ "pattern" => "*", "path" => "/" })

              refute result.is_error
              assert_equal "tmp/example\nvar/log/", result.content
            end
          end
        end

        def test_directory_results_keep_fd_trailing_slash
          with_tool_env do |env, root|
            write_file(root, "src/widgets/a.rb")
            result = Find.new(env:).call({ "pattern" => "widgets" })
            refute result.is_error
            assert_equal "src/widgets/", result.content
          end
        end

        def test_byte_cap_appends_size_notice_and_truncation_details
          with_tool_env do |env, root|
            stem = "f#{"x" * 180}"
            300.times { |i| write_file(root, "#{stem}#{i}.rb") }
            result = Find.new(env:).call({ "pattern" => "*.rb" })
            refute result.is_error
            assert result.content.end_with?("\n\n[50.0KB limit reached]")
            truncation = result.structured_content.fetch("truncation")
            assert_equal :bytes, truncation.fetch("truncated_by")
            refute result.structured_content.key?("result_limit_reached")
          end
        end

        def test_missing_fd_binary_is_an_operator_facing_error
          with_tool_env do |env, root|
            original_path = ENV.fetch("PATH", "")
            begin
              ENV["PATH"] = "/nonexistent-#{Process.pid}"
              result = Find.new(env:).call({ "pattern" => "*.rb" })
              assert result.is_error
              assert_includes result.content, "fd not found on PATH"
              assert_includes result.content, "install"
            ensure
              ENV["PATH"] = original_path
            end
          end
        end

        # The caps are the SCHEMA's (types and ranges on `inputSchema`, no hand check beside the
        # layer that refuses before the handler — so fd never starts); the sentence the model
        # reads is json_schemer's, naming the field and the bound.
        def test_the_limit_range_is_the_schemas_refusal
          assert_equal "number at `/limit` is less than: 1", schema_refusal({ "pattern" => "*.rb", "limit" => 0 })
          assert_equal "number at `/limit` is greater than: #{Find::DEFAULT_LIMIT}",
            schema_refusal({ "pattern" => "*.rb", "limit" => Find::DEFAULT_LIMIT + 1 })
          assert_equal "value at `/limit` is not an integer", schema_refusal({ "pattern" => "*.rb", "limit" => "3" })
          assert_equal Find::DEFAULT_LIMIT, Find::SCHEMA.dig("properties", "limit", "maximum")
          assert_equal 1, Find::SCHEMA.dig("properties", "limit", "minimum")
        end

        def schema_refusal(arguments)
          InputSchema.refusal(InputSchema.compile(Find::SCHEMA), arguments)
        end

        def test_cancellation_kills_and_reaps_the_fake_fd_process_group
          with_tool_env do |env, _root|
            with_blocking_executable("fd") do |ready, leader_terminated, descendant_terminated, release,
                                               leader_terminated_writer, descendant_terminated_writer|
              task = nil
              cancellation = nil
              cancellation_started_reader = nil
              cancellation_started_writer = nil
              leader_pid = nil
              descendant_pid = nil
              begin
                task = run_async { Find.new(env:).call({ "pattern" => "*.rb" }) }
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
          with_tool_env do |env, root|
            stdout = "#{File.join(root, "a.rb")}\0"
            assert_exiting_fd_cleans_descendant(env, stdout:, limit: Find::DEFAULT_LIMIT) do |result|
              refute result.is_error
              assert_equal "a.rb", result.content
            end
          end
        end

        def test_limit_exit_cleans_a_long_lived_descendant_after_reaping_the_leader
          with_tool_env do |env, root|
            stdout = "#{File.join(root, "a.rb")}\0"
            assert_exiting_fd_cleans_descendant(env, stdout:, limit: 1) do |result|
              refute result.is_error
              assert_equal true, result.structured_content.fetch("result_limit_reached")
            end
          end
        end

        def test_cancellation_returns_while_a_detached_process_holds_stderr_open
          assert_cancellation_returns_with_detached_stderr_holder("fd") do |env|
            Find.new(env:).call({ "pattern" => "*.rb" })
          end
        end

        def test_oversized_fd_stdout_record_returns_a_bounded_error
          max_bytes = Truncation::DEFAULT_MAX_BYTES
          source = <<~RUBY
            STDOUT.write("/" + ("x" * #{max_bytes}) + "\\0")
          RUBY

          with_tool_env do |env, _root|
            with_fake_executable("fd", source) do
              result = Find.new(env:).call({ "pattern" => "*.rb" })

              assert result.is_error
              assert_equal "fd output record exceeded #{max_bytes} bytes", result.content
            end
          end
        end

        def test_oversized_fd_stderr_returns_a_stable_truncated_error
          max_bytes = Truncation::DEFAULT_MAX_BYTES
          notice = "[stderr truncated after #{max_bytes} bytes]"
          source = <<~RUBY
            STDERR.write("e" * #{max_bytes + 1024})
            exit(2)
          RUBY

          with_tool_env do |env, _root|
            with_fake_executable("fd", source) do
              result = Find.new(env:).call({ "pattern" => "*.rb" })

              assert result.is_error
              assert result.content.end_with?("\n#{notice}")
              assert_equal max_bytes + 1 + notice.bytesize, result.content.bytesize
            end
          end
        end

        private

        def write_file(root, relative_path)
          absolute = File.join(root, relative_path)
          FileUtils.mkdir_p(File.dirname(absolute))
          File.write(absolute, "content\n")
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

        def with_recording_executable(name)
          with_tmpdir do |bin_dir|
            executable = File.join(bin_dir, name)
            File.write(executable, <<~RUBY)
              #!#{RbConfig.ruby}
              IO.for_fd(Integer(ENV.fetch("RHO_RUNNER_TEST_STARTED_FD"))).write("started")
            RUBY
            FileUtils.chmod("u+x", executable)

            started_reader, started_writer = IO.pipe
            started_writer.close_on_exec = false
            original_path = ENV["PATH"]
            original_started_fd = ENV["RHO_RUNNER_TEST_STARTED_FD"]
            ENV["PATH"] = [bin_dir, original_path].compact.join(File::PATH_SEPARATOR)
            ENV["RHO_RUNNER_TEST_STARTED_FD"] = started_writer.fileno.to_s

            yield started_reader
          ensure
            ENV["PATH"] = original_path
            ENV["RHO_RUNNER_TEST_STARTED_FD"] = original_started_fd
            [started_reader, started_writer].compact.each do |io|
              io.close unless io.closed?
            end
          end
        end

        def assert_exiting_fd_cleans_descendant(env, stdout:, limit:)
          with_exiting_executable_and_descendant("fd", stdout:) do |ready, descendant_terminated,
                                                                      descendant_terminated_writer, release|
            task = nil
            leader_pid = nil
            descendant_pid = nil
            begin
              task = run_async { Find.new(env:).call({ "pattern" => "*.rb", "limit" => limit }) }
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

        def with_exiting_executable_and_descendant(name, stdout:)
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
              exit(0)
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
