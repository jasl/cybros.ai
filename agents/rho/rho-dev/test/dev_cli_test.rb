require "test_helper"
require "json"

# THE SHIPPED BINARY UNDER A DEV HOME: `exe/rho` with this gem's `lib` on
# `RUBYLIB` and a home whose settings name `rho/dev` — the way the e2e
# harness and a developer's shell run it. What it lists (the thirty-eight
# under `Extension rho.dev:`, `run` still under Commands), what it parses
# (the `do` flags folded into the one POST, `--var`'s several words, the
# usage-line law over every verb), and that the load is whole: a verb
# collision is a `RegistrationError` that kills every non-core verb, so
# `rho help` succeeding under this home is the guard against it.
class DevCliTest < Minitest::Test
  include RhoTest::CliHarness

  # This gem's installed bundle and load path, with a home that names it.
  def run_rho(*argv, env: {})
    dev_home!
    out = IO.popen(
      RhoDevTest::CHILD_BUNDLE_ENV.merge("RHO_HOME" => @root, "RUBYLIB" => RhoDevTest::LIB).merge(env),
      [Gem.ruby, RhoDevTest::EXE, *argv], err: [:child, :out]
    ) { |io| io.read }
    # UTF-8 by name: this machine has no LANG, and the binary's own em
    # dashes come back as an invalid string that every regex raises on.
    [out.to_s.force_encoding(Encoding::UTF_8).scrub, $?.exitstatus]
  end

  # Running rho through the extension's bundle must preserve its lockfile.
  def test_the_spawned_binary_leaves_this_gems_lockfile_alone
    lock = File.expand_path("../Gemfile.lock", __dir__)
    before = File.binread(lock)

    _out, status = run_rho("help")

    assert_equal 0, status
    assert_equal before, File.binread(lock), "the child rewrote rho-dev's Gemfile.lock"
  end

  def dev_home!
    home.prepare
    return if File.file?(home.settings_path)

    home.write_settings("settings_version" => 1, "plugins" => { "rho.dev" => { "enabled" => true } })
  end

  def test_help_lists_the_dev_verbs_under_their_own_heading_and_run_under_commands
    out, status = run_rho("help")

    assert_equal 0, status, out
    core, *extensions = out.split(/^Extension /)
    assert_match(/^\s+rho run \[PROMPT\]/, core, "`run` is the core's own verb")
    %w[do say stop watch].each { |verb| refute_match(/^\s+rho #{verb}\b/, core, "#{verb} is this gem's, not the core's") }
    section = extensions.find { |candidate| candidate.start_with?("rho.dev:") }
    refute_nil section, "`rho help` must head a section for rho.dev:\n#{out}"
    RhoDevTest::VERBS.each { |verb| assert_match(/^\s+rho #{verb}\b/, section, "#{verb} must be listed under rho.dev") }
    ops = extensions.find { |candidate| candidate.start_with?("rho.ops:") }
    refute_nil ops, "`rho help` must head a section for rho.ops:\n#{out}"
    assert_match(/^\s+rho models\s/, ops, "model discovery remains available on a development home")
    refute_match(/did not load/, out, "the gem loaded whole")
  end

  def test_the_explicit_path_entry_loads_the_same_development_commands
    home.prepare
    home.write_settings("settings_version" => 1, "plugins" => {
      "rho.dev" => { "enabled" => true,
        "source" => { "kind" => "path", "path" => File.join(RhoDevTest::LIB, "rho", "dev_plugin.rb") } },
    })

    out, status = run_rho("help")

    assert_equal 0, status, out
    section = out.split(/^Extension /).find { |candidate| candidate.start_with?("rho.dev:") }
    refute_nil section, out
    RhoDevTest::VERBS.each { |verb| assert_match(/^\s+rho #{verb}\b/, section) }
    refute_match(/did not load/, out)
  end

  def test_the_explicit_path_entry_does_not_need_the_development_lib_on_the_load_path
    entry = File.join(RhoDevTest::LIB, "rho", "dev_plugin.rb")
    script = <<~RUBY
      require "rho"
      $LOAD_PATH.delete(ARGV.shift)
      wrapper = Module.new
      Kernel.load(ARGV.shift, wrapper)
      puts wrapper.const_get(:Dev)::NAME
    RUBY
    out = IO.popen(RhoDevTest::CHILD_BUNDLE_ENV.merge("RUBYLIB" => nil),
      [Gem.ruby, "-rbundler/setup", "-e", script, RhoDevTest::LIB, entry], err: [:child, :out]) { |io| io.read }

    assert_equal 0, $?.exitstatus, out
    assert_equal "rho.dev\n", out
  end

  # `help VERB` for the four that left the core and the three whose usage
  # once broke the arity law: the flags reach Thor, the usage names the
  # positionals alone.
  def test_help_shows_the_moved_verbs_options
    do_help, status = run_rho("help", "do")
    assert_equal 0, status, do_help
    assert_match(/rho do \[PROMPT\]/, do_help, "the prompt is optional: a promptless open")
    %w[--model --instructions --dir --runner --restricted --agent --attach --approval --stream --until --attempts --code-mode]
      .each { |flag| assert_match(/#{flag}/, do_help, "#{flag} is `do`'s") }
    assert_match(/--agent=AGENT/, do_help, "a human names the answerer")

    say_help, status = run_rho("help", "say")
    assert_equal 0, status, say_help
    assert_match(/rho say ID WORDS/, say_help)
    %w[--mode --attach --to --in --at --approval --model --code-mode].each { |flag| assert_match(/#{flag}/, say_help) }

    turns_help, status = run_rho("help", "turns")
    assert_equal 0, status, turns_help
    assert_match(/rho turns CONVERSATION_ID/, turns_help)
    %w[--after --limit --json].each { |flag| assert_match(/#{flag}/, turns_help) }

    attach_help, status = run_rho("help", "attach")
    assert_equal 0, status, attach_help
    assert_match(/rho attach ID/, attach_help)
    assert_match(/--conversation/, attach_help)

    retried, status = run_rho("help", "retry")
    assert_equal 0, status, "a keyword-named verb is still a verb"
    assert_match(/rho retry RUN_ID \[TASK_KEY\]/, retried)
    %w[--model --effort --reasoning-enabled].each { |flag| assert_match(/#{flag}/, retried, "#{flag} is `retry`'s, an option never a usage word") }

    # An option is never a word of the usage line (Thor counts the line's
    # words as the verb's arity): `--prefix` reaches `help` as an option and
    # `rho transcript RUN_ID` is one word.
    thread, status = run_rho("help", "transcript")
    assert_equal 0, status
    assert_match(/rho transcript RUN_ID$/, thread)
    assert_match(/--prefix/, thread)
    assert_match(/--follow/, thread)
  end

  def test_approve_help_explains_web_fetch_site_grants
    help, status = run_rho("help", "approve")

    assert_equal 0, status, help
    assert_includes help, "web_fetch's site (scheme://authority/*)"
    assert_includes help, "same scheme://authority, with an optional trailing /"
    assert_includes help, "no path, query, fragment or credentials"
  end

  def test_side_parses_each_tool_posture_and_refuses_unknown_choices
    seen = []
    announce(endpoint: recording_endpoint(seen, 200,
      "side" => { "public_id" => "c-1-side" }, "parent" => { "public_id" => "c-1" },
      "reused" => true, "lead" => "Side conversation"))

    %w[read write].each do |tools|
      out, status = run_rho("side", "c-1", "--tools", tools)
      assert_equal 0, status, out
    end
    bodies = seen.grep(%r{\APOST /side }).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal %w[read write].map { |tools| { "parent_public_id" => "c-1", "tools" => tools } }, bodies

    %w[none unknown].each do |tools|
      out, status = run_rho("side", "c-1", "--tools", tools)
      assert_equal 1, status, out
      assert_includes out, "read, write"
    end
    assert_equal 2, seen.grep(%r{\APOST /side }).length
  end

  # Too few or too many words is Thor's own usage error, and the flags are
  # options, never usage words.
  def test_a_dev_verb_counts_its_words_and_its_flags_are_options
    out, status = run_rho("transcript", "al-9")
    assert_equal 1, status
    assert_match(/\Arho transcript: no local daemon is running/, out,
      "one word reaches the verb: `--prefix` is an option, never a usage word")

    # `fetch UPLOAD_ID` with `--thumbnail` / `--preview` declared as OPTIONS:
    # a bracketed `[--thumbnail | --preview]` on the usage line
    # once counted as words (and `|` as an alternative) and refused every
    # `rho fetch ID` at the door — one word reaches the verb, plain or flagged.
    out, status = run_rho("fetch", "u-1")
    assert_equal 1, status
    assert_match(/\Arho fetch: no local daemon is running/, out, "one word reaches fetch")
    out, status = run_rho("fetch", "u-1", "--thumbnail")
    assert_equal 1, status
    assert_match(/\Arho fetch: no local daemon is running/, out, "the flag is an option, never a usage word")

    # `append` takes its file through `-f` (an option with an alias), so the
    # one usage word reaches the verb and the alias parses.
    out, status = run_rho("append", "al-9", "-f", "/nonexistent/steps.json")
    assert_equal 1, status
    assert_match(/\Arho append: cannot read steps from \/nonexistent\/steps.json/, out, "-f parsed as the file option")

    out, status = run_rho("stop")
    assert_equal 1, status
    assert_match(/"rho stop" was called with no arguments/, out)
  end

  # THE USAGE-LINE LAW over the dev listing too (`cli_command_test` runs
  # it over the product home): Thor counts a usage line's words as the
  # verb's arity, so a usage names POSITIONALS only — uppercase
  # placeholders, bracketed when optional, lowercase sub-verbs — never an
  # option. Read at a width nothing is cut at.
  def test_every_usage_line_names_positionals_only
    help, status = run_rho("help", env: { "THOR_COLUMNS" => "400" })
    assert_equal 0, status
    listed = help.lines.count { |line| line.match?(/^\s+rho \S/) }
    usages = help.scan(/^\s*rho (\S.*?)\s{2,}#/).flatten
    refute_empty usages, "help lists the verbs with their usage lines"
    assert_equal listed, usages.length, "every listed verb's usage line is scanned; Thor cut one:\n#{help}"
    offenders = usages.flat_map do |usage|
      usage.split("|").flat_map do |alternative|
        alternative.split.drop(1).reject { |word| word.match?(/\A\[?(?:[A-Z][A-Z0-9_]*|[a-z][a-z_-]*)(?:\.\.\.)?\]?\z/) }
                   .map { |word| "#{usage.strip}: #{word.inspect}" }
      end
    end
    assert_empty offenders, "an option is never a word of a usage line"
  end

  # A USAGE LINE WITH ALTERNATIVES (`request RUN_ID TASK_KEY | request CONVERSATION_ID
  # TURN_ID`; `inputs …`) counts each alternative's words on its own: two words reach
  # `request`, and `inputs` takes one, three or four — never two.
  def test_a_usage_with_alternatives_counts_each_alternatives_words
    out, status = run_rho("request", "al-9", "r1")
    assert_equal 1, status
    assert_match(/\Arho request: no local daemon is running/, out, "two words reach the verb")

    out, status = run_rho("inputs", "rm", "c-1")
    assert_equal 1, status
    assert_match(/was called with arguments \["rm", "c-1"\]/, out)

    out, status = run_rho("inputs", "edit", "c-1", "cin-1", "again")
    assert_match(/\Arho inputs: no local daemon is running/, out, "four words reach the verb")
  end

  # `do` AND THE FLAGS IT FOLDS INTO THE ONE POST: the argv `live_until_test`
  # types, parsed by the shipped binary and sent to a daemon that keeps
  # what it was sent — `POST /conversations`, and the three-line output
  # every paid lane parses `run:` off.
  def test_do_parses_the_until_flags_and_folds_them_into_the_request
    seen = []
    announce(endpoint: recording_endpoint(seen, 201,
      "conversation" => { "public_id" => "c-9" }, "turn" => { "public_id" => "t-9" },
      "run" => { "public_id" => "al-9" },
      "until" => { "command" => "sh check.sh", "attempts" => 3, "directory" => @root }))

    out, status = run_rho("do", "Create note.txt", "--model", "dev/mock-text", "--dir", @root,
      "--until", "sh check.sh", "--attempts", "3", "--nexus-url", "https://nexus.example")

    assert_equal 0, status, out
    sent = seen.grep(/\APOST \/conversations /).first
    refute_nil sent, "the request must reach the daemon"
    body = JSON.parse(sent.partition("\r\n\r\n").last)
    assert_equal({ "command" => "sh check.sh", "attempts" => 3 }, body.fetch("until"))
    # `--dir` BINDS: the directory
    # rides as the descriptive `working_directory` AND as the environment
    # the daemon validates and records.
    assert_equal @root, body.fetch("working_directory")
    assert_equal({ "root" => @root, "directories" => [] }, body.fetch("environment"))
    assert_equal "dev/mock-text", body.fetch("model")
    assert_match(/^conversation:\s+c-9/, out)
    assert_match(/^turn:\s+t-9/, out)
    assert_match(/^run:\s+al-9/, out)
    assert_match(/^until:\s+sh check\.sh \(3 checks, in #{Regexp.escape(@root)}\)/, out)
    refute_match(/^(status|tools):/, out, "no status line and no tools line: the declaration is the profile's")
  end

  # `rho prompt preview` THROUGH THE SHIPPED BINARY: Thor's
  # parse of `--var` (ONE flag, several `name=value` words after it — a
  # repeated flag keeps only the last; each word keeps its spaces and its
  # own `=`), `--to`, `--prompt` and `--json` — what a person types, sent
  # as the one POST the daemon reads.
  def test_prompt_preview_parses_the_repeatable_var_flag_and_posts_one_body
    seen = []
    preview = { "mechanism" => "assembly", "input_tokens" => 9, "tokenizer_exact" => true,
                "catalog_input_token_limit" => 100, "advisory_input_token_limit" => nil, "message_count" => 1,
                "history" => { "selected" => 0, "skipped" => 0 }, "entries" => [], "storage" => { "bytes" => 2, "bound" => 4, "within_bound" => true },
                "blocks" => [], "memory" => { "included" => 0, "omitted" => 0 }, "slots" => {} }
    announce(endpoint: recording_endpoint(seen, 200, "preview" => preview))

    out, status = run_rho("prompt", "preview", "c-9", "--model", "dev/mock-text", "--prompt", "and so?",
      "--to", "@narrator", "--var", "scene=a rainy night", "mood=calm=ish", "--json",
      "--nexus-url", "https://nexus.example")

    assert_equal 0, status, out
    sent = seen.grep(%r{\APOST /conversations/prompt_preview }).first
    refute_nil sent, "the request must reach the daemon"
    body = JSON.parse(sent.partition("\r\n\r\n").last)
    assert_equal({ "public_id" => "c-9", "model" => "dev/mock-text", "prompt" => "and so?", "to" => "@narrator",
                   "variables" => { "scene" => "a rainy night", "mood" => "calm=ish" } }, body)
    assert_equal preview, JSON.parse(out[out.index("{")..]), "--json prints the document whole"

    out, status = run_rho("prompt", "--nexus-url", "https://nexus.example")
    assert_equal 1, status
    assert_match(/was called with no arguments|was called with arguments/, out, "the usage line's arity refuses a bare `prompt`")
  end

  # `--attach PATH`: `say --attach` QUEUES the turn (the
  # kernel refuses a picture on a steer) unless `--mode steer` is typed,
  # which is refused before any call with the kernel's word; `do --attach`
  # posts the path beside the prompt.
  def test_say_attach_implies_queue_and_do_attach_posts_the_path
    seen = []
    announce(endpoint: recording_endpoint(seen, 200,
      "input" => { "public_id" => "in-1", "state" => "pending" },
      "attachments" => [{ "filename" => "diagram.png", "content_type" => "image/png", "byte_size" => 70 }]))
    picture = File.join(@root, "diagram.png")
    File.binwrite(picture, "png")

    out, status = run_rho("say", "c-9", "what is this?", "--attach", picture, "--nexus-url", "https://nexus.example")
    assert_equal 0, status, out
    body = JSON.parse(seen.grep(%r{\APOST /say }).first.partition("\r\n\r\n").last)
    assert_equal "queue", body.fetch("delivery_mode"), "--attach implies --mode queue"
    assert_equal [picture], body.fetch("attachments")
    assert_match(%r{^attached:\s+diagram\.png \(image/png, 70 B\)$}, out)

    out, status = run_rho("say", "c-9", "plain", "--nexus-url", "https://nexus.example")
    assert_equal 0, status, out
    assert_equal "steer", JSON.parse(seen.grep(%r{\APOST /say }).last.partition("\r\n\r\n").last).fetch("delivery_mode"),
      "no --attach: steer stays the default"

    seen.clear
    out, status = run_rho("say", "c-9", "now", "--attach", picture, "--mode", "steer", "--nexus-url", "https://nexus.example")
    assert_equal 1, status
    assert_match(/attachments_not_steerable/, out, "the kernel's word, one sentence")
    assert_empty seen.grep(%r{/say}), "refused before any call"

    out, status = run_rho("say", "c-9", "now", "--attach", File.join(@root, "gone.png"), "--nexus-url", "https://nexus.example")
    assert_equal 1, status
    assert_match(/no such file to attach: .*gone\.png/, out)
  end

  def test_do_attach_posts_the_path_beside_the_prompt
    seen = []
    announce(endpoint: recording_endpoint(seen, 201,
      "conversation" => { "public_id" => "c-9" }, "turn" => { "public_id" => "t-9" },
      "run" => { "public_id" => "al-9" },
      "attachments" => [{ "filename" => "shot.png", "content_type" => "image/png", "byte_size" => 2048 }]))
    picture = File.join(@root, "shot.png")
    File.binwrite(picture, "png")

    out, status = run_rho("do", "what is this?", "--model", "dev/mock-text", "--attach", picture,
      "--nexus-url", "https://nexus.example")

    assert_equal 0, status, out
    body = JSON.parse(seen.grep(%r{\APOST /conversations }).first.partition("\r\n\r\n").last)
    assert_equal [picture], body.fetch("attachments")
    assert_match(%r{^attached:\s+shot\.png \(image/png, 2 KiB\)$}, out)
  end

  # THE APPROVAL KNOB: `--approval ask|rules` lands on
  # the body as the input's `approval_mode`, `--no-stream` as `stream:
  # false`; a third word is Thor's refusal in one sentence; no flag sends
  # no key (the profile's word).
  def test_do_parses_the_approval_and_stream_flags_and_writes_them_into_the_request
    seen = []
    announce(endpoint: recording_endpoint(seen, 201,
      "conversation" => { "public_id" => "c-9" }, "turn" => { "public_id" => "t-9" },
      "run" => { "public_id" => "al-9" }))

    out, status = run_rho("do", "push it", "--model", "dev/mock-text", "--dir", @root,
      "--approval", "ask", "--no-stream", "--nexus-url", "https://nexus.example")
    assert_equal 0, status, out
    body = JSON.parse(seen.grep(/\APOST \/conversations /).first.partition("\r\n\r\n").last)
    assert_equal "ask", body.fetch("approval_mode")
    assert_equal false, body.fetch("stream")
    assert_match(/^run:\s+al-9/, out)

    seen.clear
    out, status = run_rho("do", "push it", "--model", "dev/mock-text", "--nexus-url", "https://nexus.example")
    assert_equal 0, status, out
    body = JSON.parse(seen.grep(/\APOST \/conversations /).first.partition("\r\n\r\n").last)
    refute body.key?("approval_mode"), "no flag sends no key: the turn runs under the profile's word"
    refute body.key?("stream"), "the default holds the feed: no key is sent"

    seen.clear
    out, status = run_rho("do", "push it", "--model", "dev/mock-text", "--approval", "telepathy",
      "--nexus-url", "https://nexus.example")
    refute_equal 0, status, out
    assert_match(/Expected '--approval' to be one of ask, rules; got telepathy/, out)
    assert_empty seen.grep(/\APOST \/conversations /), "a refused flag opens nothing"
  end

  def test_do_and_say_preserve_enabled_disabled_and_inherited_code_mode
    cases = [
      [["do", "Compare the files"], "/conversations", 201, { "conversation" => { "public_id" => "c-9" }, "pending" => true }],
      [["say", "c-9", "Continue"], "/say", 200, { "input" => { "public_id" => "cin-2", "state" => "pending" } }],
    ]
    cases.each do |arguments, path, status_code, response|
      seen = []
      announce(endpoint: recording_endpoint(seen, status_code, response))
      { "--code-mode" => true, "--no-code-mode" => false, nil => nil }.each do |flag, expected|
        seen.clear
        out, status = run_rho(*arguments, *Array(flag), "--nexus-url", "https://nexus.example")
        assert_equal 0, status, out
        request = seen.find { |entry| entry.start_with?("POST #{path} ") }
        refute_nil request, out
        body = JSON.parse(request.partition("\r\n\r\n").last)
        if flag
          assert_equal expected, body.fetch("code_mode")
        else
          refute body.key?("code_mode"), "no flag preserves the conversation or global choice"
        end
      end
    end
  end

  def test_retry_preserves_enabled_disabled_and_unspecified_reasoning
    seen = []
    announce(endpoint: recording_endpoint(seen, 200, "task" => { "key" => "r2", "status" => "waiting" }))

    { "--reasoning-enabled" => true, "--no-reasoning-enabled" => false, nil => nil }.each do |flag, expected|
      seen.clear
      out, status = run_rho("retry", "al-9", "r2", *Array(flag), "--nexus-url", "https://nexus.example")
      assert_equal 0, status, out
      request = seen.find { |entry| entry.start_with?("POST /runs/retry ") }
      refute_nil request, out
      body = JSON.parse(request.partition("\r\n\r\n").last)
      refute body.key?("model"), "the reasoning switch can keep the current model"
      if flag
        assert_equal expected, body.fetch("reasoning_enabled")
      else
        refute body.key?("reasoning_enabled"), "no flag preserves the existing switch"
      end
    end
  end

  # `--model` is optional: the daemon holds the default, so an absent flag
  # sends no model at all rather than an empty one; a pending turn prints
  # the verb that follows it.
  def test_do_without_a_model_sends_none_and_a_pending_turn_names_watch
    seen = []
    announce(endpoint: recording_endpoint(seen, 201,
      "conversation" => { "public_id" => "c-9" }, "pending" => true))

    out, status = run_rho("do", "Create note.txt", "--nexus-url", "https://nexus.example")

    assert_equal 0, status, out
    body = JSON.parse(seen.grep(/\APOST \/conversations /).first.partition("\r\n\r\n").last)
    refute body.key?("model")
    assert_equal "Create note.txt", body.fetch("prompt")
    assert_match(/^pending:\s+the turn has not started yet; `rho watch` follows it$/, out)
  end

  # THE PROMPTLESS OPEN through the binary: `rho
  # do` with no PROMPT posts no `prompt` key and prints the conversation
  # alone — no turn, no run, no pending line — then the verb that speaks
  # in it; a flag only a turn carries is still parsed and sent (the
  # daemon refuses it by name).
  def test_do_without_a_prompt_posts_no_prompt_and_prints_the_conversation_alone
    seen = []
    announce(endpoint: recording_endpoint(seen, 201,
      "conversation" => { "public_id" => "c-9" }, "default_runner" => { "executor_public_id" => "0199-r" }))

    out, status = run_rho("do", "--model", "dev/mock-text", "--dir", @root, "--nexus-url", "https://nexus.example")

    assert_equal 0, status, out
    body = JSON.parse(seen.grep(/\APOST \/conversations /).first.partition("\r\n\r\n").last)
    refute body.key?("prompt"), "no prompt: the key is absent"
    assert_equal "dev/mock-text", body.fetch("model")
    assert_equal @root, body.fetch("working_directory")
    assert_match(/^conversation:\s+c-9$/, out)
    assert_match(/^next:\s+rho say c-9 "…"$/, out)
    refute_match(/^(turn|run|pending):/, out, "nothing a turn carries is printed: none was opened")
  end

  # `rho say --approval MODE --model ID`: the two turn fields ride the one POST as themselves, and the
  # answer's turn and run print as `turn:`/`run:` lines after the queued
  # row — the ids a scripted lane parses.
  def test_say_parses_the_approval_and_model_flags_and_prints_the_turn_and_run
    seen = []
    announce(endpoint: recording_endpoint(seen, 200,
      "input" => { "public_id" => "cin-2", "state" => "pending" },
      "turn" => { "public_id" => "t-2" }, "run" => { "public_id" => "al-2" }))

    out, status = run_rho("say", "c-9", "carry on", "--mode", "queue", "--approval", "ask", "--model", "dev/mock-text",
      "--nexus-url", "https://nexus.example")

    assert_equal 0, status, out
    body = JSON.parse(seen.grep(%r{\APOST /say }).first.partition("\r\n\r\n").last)
    assert_equal({ "public_id" => "c-9", "text" => "carry on", "delivery_mode" => "queue", "approval_mode" => "ask",
                   "model" => "dev/mock-text" }, body)
    assert_match(/^queued:\s+cin-2 \(pending\)\nturn:\s+t-2\nrun:\s+al-2$/, out)

    out, status = run_rho("say", "c-9", "carry on", "--approval", "telepathy", "--nexus-url", "https://nexus.example")
    refute_equal 0, status, out
    assert_match(/Expected '--approval' to be one of ask, rules; got telepathy/, out)
  end

  # `rho turns ID` and `rho attach ID --conversation` through the binary:
  # the query and the body as the primitives
  # spell them.
  def test_turns_and_attach_conversation_reach_their_routes_through_the_binary
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /conversations/turns?public_id=c-9&after_position=2&limit=5" => [[200, {
        "turns" => [{ "public_id" => "t-3", "position" => 3, "kind" => "direct_reply", "role" => "user",
                      "status" => "completed", "origin" => "person", "active_variant" => { "content" => "hi", "source" => "inference" } }],
        "pagination" => { "after_position" => 3, "has_more" => false },
      }]],
      "POST /followers/attach" => [[200, { "conversation" => { "public_id" => "c-9" }, "run" => { "public_id" => "c-9" } }]]))

    out, status = run_rho("turns", "c-9", "--after", "2", "--limit", "5", "--nexus-url", "https://nexus.example")
    assert_equal 0, status, out
    assert_match(/^\s+3  t-3  user  direct_reply  completed  "hi"$/, out)

    out, status = run_rho("attach", "c-9", "--conversation", "--nexus-url", "https://nexus.example")
    assert_equal 0, status, out
    body = JSON.parse(seen.grep(%r{\APOST /followers/attach }).first.partition("\r\n\r\n").last)
    assert_equal({ "public_id" => "c-9", "live" => true, "host_type" => "conversation" }, body)
    assert_match(/^c-9  conversation  followed$/, out)
  end

  # `rho adaptations` left the core with the three: its
  # lines through the binary, from the files alone.
  def test_adaptations_prints_the_row_a_model_resolves_to
    dev_home!
    home.write_settings(Rho::Config.read(home.settings_path).merge("default_model" => "dev/mock-text"))

    out, status = run_rho("adaptations", "--nexus-url", "https://nexus.example")

    assert_equal 0, status, out
    assert_match(/^model:             dev\/mock-text$/, out)
    assert_match(/^facts:             \(no daemon\)$/, out)
  end

  # NO TRANSPORT IN THE VERBS (the core law, `core_surface_test`): every
  # daemon call is a named `cli.core.*` primitive — never a raw request,
  # never a route literal behind `get`/`post`/`put`.
  def test_the_verbs_hold_no_transport
    files = Dir.glob(File.join(RhoDevTest::LIB, "rho", "**", "*.rb")).sort
    refute_empty files
    offenders = files.flat_map do |path|
      File.read(path, encoding: "UTF-8").lines.map.with_index(1) do |line, number|
        code = line.chomp.sub(/(?<!["'\\])#(?!\{).*\z/, "")
        "#{path}:#{number} #{code.strip}" if code.match?(/Net::HTTP|send_request|\b(get|post|put)\(/)
      end.compact
    end
    assert_empty offenders
  end
end
