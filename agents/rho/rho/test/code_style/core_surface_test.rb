require "test_helper"

# THE CORE IS A NAMED BOUNDARY: `Rho::Core` is
# the capability module every surface consumes — the terminal (`exe/rho`,
# `Rho::Cli::Terminal`), rho-dev's verbs, later the TUI/ACP/IM — over the
# daemon's control routes and the kernel. One method is ONE capability
# over ONE route, answering a document or raising `Rho::Error` with the
# daemon's sentence; no printing, no polling, no composition, no exit
# code. Three laws, each mechanical: the public surface is pinned, the
# core holds no terminal, and the surfaces hold no transport.
class CoreSurfaceTest < Minitest::Test
  LIB = File.expand_path("../../lib/rho", __dir__)
  EXE = File.expand_path("../../exe/rho", __dir__)

  # The pinned surface, grown only with a reason. The client, the ceremony, the stored
  # facts, the kernel facts, the conversation verbs, the loop verbs, the records. The
  # shared surface contract added three: `turns` (the replay's spine, `GET
  # /conversations/turns`) and `environment`/`repoint_environment` (the two `/environment`
  # calls the Environment extension made through `core.get`/`core.post`, named — the ACP
  # surface binds a session's cwd through them). The conversation's environment added
  # three: `conversation_environment`, `bind_environment` and `environments` — the record
  # read, the bind under ABSENT-means-keep, the live table. `models` is the
  # account catalog read shared by the CLI and the browser control API. The
  # conversation list, detail, title and archive verbs serve the durable UI. Its
  # history/candidate controls and memory verbs are shared by the IM surface.
  SURFACE = %i[
    abandon access activate_variant adaptation_choice answer append approve archive_conversation asks attach bind_environment bind_memory_context cancel_scheduled_job compact config
    change_telegram_access configure_telegram connect_in_process conversation conversation_environment conversations create_scheduled_job create_workspace
    delete_input delete_loop delete_turn deny disconnect edit_turn environment environments failure_message get graph history home host_events inputs
    loop_events loop_row
    loops memory_delete memory_edit memory_grep memory_list memory_read memory_write model_facts models open_conversation open_side parse patch pause pause_scheduled_job phases post prompt_documents prompt_preview providers
    push_skill put regenerate relay remove_skill replace_access repoint_environment request_bytes require_daemon result
    resume resume_scheduled_job retry rewind rules running_daemon say scheduled_job scheduled_job_executions scheduled_jobs search_conversations select_workspace settings settings_status show_skill skills start_ceremony status_document stop
    stored_connection stored_facts stored_identity subscribe task telegram_settings transcript turn_view_state turns unarchive_conversation unsubscribe update_conversation update_input update_scheduled_job update_settings
    upload_bytes variant variants workspace workspaces
  ].sort.freeze
  CLASS_SURFACE = %i[deliver_at_wire schedule_fields].freeze

  # `rake rbs` wraps every signed method in a named hook pair; those are
  # the checker's, not the surface. The mixins are the class's surface all
  # the same: a surface reaches them on the one object it holds.
  def surface
    modules = [Rho::Core, Rho::Core::Conversations, Rho::Core::Events, Rho::Core::Loops, Rho::Core::Memory, Rho::Core::Records,
               Rho::Core::ScheduledJobs, Rho::Core::Settings, Rho::Core::Workspaces]
    modules.flat_map { |mod| mod.public_instance_methods(false) }.grep_v(/__RBS_TEST_/).uniq.sort
  end

  def test_the_core_answers_exactly_the_pinned_primitives
    assert_equal SURFACE, surface
    assert_equal CLASS_SURFACE, Rho::Core.singleton_methods(false).grep_v(/__RBS_TEST_/).sort
  end

  # The deadline the follow's socket raises is the core's own error, so a
  # surface tells a timeout from a refusal without reading a sentence.
  def test_the_follow_deadline_is_a_core_error
    assert_operator Rho::Core::Deadline, :<, Rho::Error
  end

  # The daemon's refusal is the core's own error too: the sentence as the message, the code word
  # and the status as readers — a surface tells refusals apart by code.
  def test_the_daemons_refusal_is_a_core_error_carrying_its_code_and_status
    assert_operator Rho::Core::Refused, :<, Rho::Error
    refused = Rho::Core::Refused.new("the sentence", code: "runner_elsewhere", status: 409)
    assert_equal ["the sentence", "runner_elsewhere", 409], [refused.message, refused.code, refused.status]
  end

  # Source lines with the comment stripped: a law about code, not prose.
  def code_lines(path)
    File.read(path, encoding: "UTF-8").lines.map.with_index(1) do |line, number|
      [number, line.chomp.sub(/(?<!["'\\])#.*\z/, "")]
    end
  end

  def offenders(paths, pattern)
    paths.flat_map do |path|
      code_lines(path).select { |_, code| code.match?(pattern) }.map { |number, code| "#{path}:#{number} #{code.strip}" }
    end
  end

  # NO TERMINAL IN THE CORE: nothing prints, waits, loops or exits — a
  # primitive answers, and what to do with the answer is the surface's.
  def test_the_core_prints_polls_and_exits_nowhere
    files = Dir.glob(File.join(LIB, "core*", "**", "*.rb")) + [File.join(LIB, "core.rb")]
    refute_empty files.select { |path| File.file?(path) }
    assert_empty offenders(files.select { |path| File.file?(path) },
      /\b(puts|print|exit|sleep)\b|\$stdout|@out\b|\bloop do\b/)
  end

  # NO TRANSPORT IN THE SURFACES: the terminal and the dispatcher reach
  # the daemon through NAMED primitives only — never a raw request, never
  # a route literal behind `get`/`post`/`put`. (An extension reaches ITS
  # OWN route through `core.get`/`core.post` — the transport is the core's,
  # the capability stays the extension's; Ops' routes are the loop
  # primitives' own, and its verbs are rho-dev's, whose suite carries the
  # same grep over its own lib.)
  def test_the_surfaces_hold_no_transport
    files = Dir.glob(File.join(LIB, "cli", "**", "*.rb")) + [EXE]
    assert_empty offenders(files.select { |path| File.file?(path) }, /Net::HTTP|send_request|\b(get|post|put)\(/)
  end
end
