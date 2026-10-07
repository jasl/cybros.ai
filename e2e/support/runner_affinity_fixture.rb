require "json"
require "json_schemer"
require "securerandom"

module E2E
  # A fixed, fictional machine list. Nothing here runs a command or changes a
  # real Runner. The prototype's index belongs to this draw's last delivered list.
  class RunnerAffinityFixture
    USER_REQUEST = "我个人电脑在运行Codex，帮我检查工作状态".freeze
    CLARIFICATION = "选列表中的第2个。".freeze
    INSTRUCTIONS = "You are a helpful assistant. Identify the requested machine using the available tool metadata. " \
                   "When exactly one machine matches, carry out the user's request without additional confirmation. " \
                   "Ask the user only when the available information cannot distinguish the intended machine.".freeze
    QUESTIONS = /[?？]|请.{0,25}(?:确认|选择|指定|告诉)|哪(?:个|一|台)|(?:which|choose|select|confirm|clarif)/i
    STATUS_COMMAND = /codex|\bps\b|pgrep|\btop\b|launchctl|lsof/i

    def self.tools(vocabulary)
      noun = vocabulary == "runners" ? "Runner" : "environment"
      [
        tool("#{vocabulary}_current", "Return the current #{noun}, the machine where bash runs. " \
          "Its identity and description let you check whether it is the user's requested machine."),
        tool("#{vocabulary}_list", "List available #{noun}s and identify the current one. Each entry has a 1-based index. " \
          "Use names, descriptions and hostnames to find the user's requested machine. If entries remain indistinguishable, " \
          "ask the user to identify the intended entry before switching or inspecting a machine. " \
          "When presenting choices to the user, preserve the original index values exactly; never renumber a filtered list. " \
          "Use bullets labelled with the original indices instead of a new numbered list."),
        tool("#{vocabulary}_change", "Change the current #{noun} for subsequent bash calls. Select the 1-based index from " \
          "the most recent #{vocabulary}_list result in your current model context; never guess an index. " \
          "Wait for this call's result before calling bash on the selected machine. Do not switch when it is already current.",
          properties: { index: { type: "integer", minimum: 1, description: "The 1-based index in that most recent list result." } },
          required: ["index"]),
        tool("bash", "Run a shell command on the currently selected machine.",
          properties: { command: { type: "string" } }, required: ["command"]),
      ]
    end

    def self.tool(name, description, properties: {}, required: [])
      { type: "function", name: name, description: description,
        parameters: { type: "object", properties: properties, required: required, additionalProperties: false } }
    end
    private_class_method :tool

    attr_reader :events, :violations, :question, :rows, :target_id

    def initialize(vocabulary:, scenario:, ids: Array.new(3) { SecureRandom.uuid_v7 })
      @vocabulary = vocabulary
      @scenario = scenario
      @schemas = self.class.tools(vocabulary).to_h do |tool|
        [tool.fetch(:name), JSONSchemer.schema(JSON.parse(JSON.generate(tool.fetch(:parameters))))]
      end
      @rows = [
        row(ids.fetch(0), "Linux服务器", "运行助手服务的 Linux 服务器。", "assistant-server", "linux"),
        row(ids.fetch(1), "个人电脑", "我的日常个人电脑。", "personal-mac", "macos"),
        row(ids.fetch(2), "开发容器", "用于构建和测试的隔离容器。", "dev-container", "linux"),
      ]
      @rows[2] = @rows.fetch(1).merge("id" => ids.fetch(2)) if scenario == "ambiguous"
      @target_id = ids.fetch(1)
      @current_id = scenario == "already_current" ? @target_id : ids.fetch(0)
      @observed = false
      @last_list = nil
      @clarified = false
      @events = []
      @violations = []
    end

    # Calls in one model response are a batch, not a sequence. Every bash in
    # that batch stays on its entry target; a just-returned list cannot supply
    # an index to another call the model already emitted beside it.
    def apply(calls)
      prior_target = @current_id
      prior_list = @last_list
      observed = @observed
      names = calls.map { |call| call.fetch("name") }
      if names.include?("#{@vocabulary}_change") && names.include?("bash")
        @violations << "parallel_change_and_bash"
      end
      if names.count("#{@vocabulary}_change") > 1
        @violations << "parallel_changes"
      end
      calls.map do |call|
        arguments = JSON.parse(call.fetch("arguments"))
        name = call.fetch("name")
        schema = @schemas[name]
        output = if schema.nil? || !schema.valid?(arguments)
          @violations << (schema.nil? ? "unknown_tool" : "invalid_tool_arguments")
          { "error" => "The call does not match a declared tool schema." }
        else
          answer(name, arguments, prior_target: prior_target, prior_list: prior_list, observed: observed)
        end
        event = { "name" => call.fetch("name"), "arguments" => arguments, "output" => output,
                  "batch_target_id" => prior_target, "before_clarification" => ambiguous? && !@clarified }
        @events << event
        { "type" => "function_call_output", "call_id" => call.fetch("id"), "output" => JSON.generate(output) }
      rescue JSON::ParserError => error
        @violations << "invalid_tool_arguments"
        output = { "error" => "Invalid tool arguments: #{error.class}" }
        @events << { "name" => call.fetch("name"), "raw_arguments" => call.fetch("arguments"), "output" => output }
        { "type" => "function_call_output", "call_id" => call.fetch("id"), "output" => JSON.generate(output) }
      end
    end

    def clarification_needed?(text)
      ambiguous? && !@clarified && @last_list && @violations.empty? && text.match?(QUESTIONS)
    end

    def clarify(text)
      @question = text
      @clarified = true
      CLARIFICATION
    end

    def grade(reply)
      changes = @events.select { |event| event["name"] == "#{@vocabulary}_change" }
      checks = @events.select { |event| event["name"] == "bash" }
      errors = @violations.dup
      errors << "target_not_observed" unless @observed
      errors << "no_status_inspection" unless checks.any? { |event| event.dig("arguments", "command").to_s.match?(STATUS_COMMAND) }
      errors << "wrong_inspection_target" unless checks.all? { |event| event["batch_target_id"] == @target_id }
      if @scenario == "already_current"
        errors << "unnecessary_change" unless changes.empty?
      else
        errors << "target_not_selected" unless @current_id == @target_id && changes.any?
      end
      errors << "did_not_ask_user" if ambiguous? && @question.nil?
      errors << "empty_final_reply" if reply.to_s.strip.empty?
      { "pass" => errors.empty?, "violations" => errors.uniq, "current_id" => @current_id,
        "target_id" => @target_id, "clarification_question" => @question, "user_clarification" => (@clarified ? CLARIFICATION : nil) }
    end

    private

      def row(id, name, description, hostname, platform)
        { "id" => id, "name" => name, "description" => description,
          "hostname" => hostname, "platform" => platform, "available" => true }
      end

      def projected(id, current_id: @current_id)
        @rows.find { |item| item.fetch("id") == id }.merge("current" => id == current_id)
      end

      def ambiguous? = @scenario == "ambiguous"

      def answer(name, arguments, prior_target:, prior_list:, observed:)
        case name
        when "#{@vocabulary}_current"
          @observed = true
          projected(prior_target, current_id: prior_target)
        when "#{@vocabulary}_list"
          @observed = true
          @last_list = @rows.map.with_index(1) { |item, index| projected(item.fetch("id"), current_id: prior_target).merge("index" => index) }
          { "items" => @last_list }
        when "#{@vocabulary}_change"
          if ambiguous? && !@clarified
            @violations << "changed_before_clarification"
            { "error" => "The intended machine is ambiguous." }
          elsif prior_list.nil?
            @violations << "index_without_prior_list"
            { "error" => "No prior list result supplies this index." }
          else
            selected = prior_list.find { |item| item.fetch("index").eql?(arguments.fetch("index")) }
            if selected.nil?
              @violations << "index_not_in_prior_list"
              { "error" => "This index is absent from the prior list." }
            else
              @violations << "wrong_selection" unless selected.fetch("id") == @target_id
              @current_id = selected.fetch("id")
              projected(@current_id)
            end
          end
        when "bash"
          @violations << "bash_before_target_observation" unless observed
          @violations << "inspected_before_clarification" if ambiguous? && !@clarified
          { "exit_status" => 0, "executed_on" => prior_target,
            "stdout" => "PID 4242  Codex  running  Current task: reviewing local changes; no errors reported.\n" }
        else
          @violations << "unknown_tool"
          { "error" => "Unknown tool: #{name}" }
        end
      end
  end
end
