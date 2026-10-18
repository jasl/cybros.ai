# ACP reference: https://github.com/agentclientprotocol/agent-client-protocol/tree/main/schema/v1
module Rho
  module Acp
    # THE NAMES ON THE WIRE, both directions: data, no behaviour. The method and
    # notification names as the stable v1 schema spells them, the JSON-RPC and ACP error
    # codes with their canonical sentences, the capability key lists (camelCase, the
    # schema's spelling) with the two baseline documents, and the discriminator vocabularies
    # (snake_case, the schema's spelling): stop reasons, permission option kinds and
    # outcomes, content block types, session update kinds, tool kinds and statuses, plan
    # words, auth method types, elicitation modes and actions, config option types and
    # categories. Both roles — `rho acp` and `delegate_agent` — spell
    # every name through here, so a rename is one edit and `methods_test` pins each string
    # to the facts sheet.
    module Methods
      PROTOCOL_VERSION = 1
      JSONRPC = "2.0".freeze

      # Client → agent.
      INITIALIZE = "initialize".freeze
      AUTHENTICATE = "authenticate".freeze
      LOGOUT = "logout".freeze
      SESSION_NEW = "session/new".freeze
      SESSION_LOAD = "session/load".freeze
      SESSION_RESUME = "session/resume".freeze
      SESSION_CLOSE = "session/close".freeze
      SESSION_LIST = "session/list".freeze
      SESSION_DELETE = "session/delete".freeze
      SESSION_SET_MODE = "session/set_mode".freeze
      SESSION_SET_CONFIG_OPTION = "session/set_config_option".freeze
      SESSION_PROMPT = "session/prompt".freeze
      SESSION_CANCEL = "session/cancel".freeze

      AGENT_REQUESTS = [
        INITIALIZE, AUTHENTICATE, LOGOUT, SESSION_NEW, SESSION_LOAD, SESSION_RESUME, SESSION_CLOSE, SESSION_LIST,
        SESSION_DELETE, SESSION_SET_MODE, SESSION_SET_CONFIG_OPTION, SESSION_PROMPT,
      ].freeze
      AGENT_NOTIFICATIONS = [SESSION_CANCEL].freeze

      # Agent → client.
      SESSION_REQUEST_PERMISSION = "session/request_permission".freeze
      SESSION_UPDATE = "session/update".freeze
      FS_READ_TEXT_FILE = "fs/read_text_file".freeze
      FS_WRITE_TEXT_FILE = "fs/write_text_file".freeze
      TERMINAL_CREATE = "terminal/create".freeze
      TERMINAL_OUTPUT = "terminal/output".freeze
      TERMINAL_WAIT_FOR_EXIT = "terminal/wait_for_exit".freeze
      TERMINAL_KILL = "terminal/kill".freeze
      TERMINAL_RELEASE = "terminal/release".freeze
      ELICITATION_CREATE = "elicitation/create".freeze
      ELICITATION_COMPLETE = "elicitation/complete".freeze

      CLIENT_REQUESTS = [
        SESSION_REQUEST_PERMISSION, FS_READ_TEXT_FILE, FS_WRITE_TEXT_FILE, TERMINAL_CREATE, TERMINAL_OUTPUT,
        TERMINAL_WAIT_FOR_EXIT, TERMINAL_KILL, TERMINAL_RELEASE, ELICITATION_CREATE,
      ].freeze
      CLIENT_NOTIFICATIONS = [SESSION_UPDATE, ELICITATION_COMPLETE].freeze

      # Either direction (custom methods start with `_`; an unknown request returns -32601,
      # while an unknown notification is ignored).
      CANCEL_REQUEST = "$/cancel_request".freeze
      CUSTOM_PREFIX = "_".freeze

      # The schema's `ErrorCode` with JSON-RPC's own sentences.
      module ErrorCode
        PARSE = -32700
        INVALID_REQUEST = -32600
        METHOD_NOT_FOUND = -32601
        INVALID_PARAMS = -32602
        INTERNAL = -32603
        AUTH_REQUIRED = -32000
        RESOURCE_NOT_FOUND = -32002
        REQUEST_CANCELLED = -32800

        MESSAGES = {
          PARSE => "Parse error".freeze,
          INVALID_REQUEST => "Invalid Request".freeze,
          METHOD_NOT_FOUND => "Method not found".freeze,
          INVALID_PARAMS => "Invalid params".freeze,
          INTERNAL => "Internal error".freeze,
          AUTH_REQUIRED => "Authentication required".freeze,
          RESOURCE_NOT_FOUND => "Resource not found".freeze,
          REQUEST_CANCELLED => "Request cancelled".freeze,
        }.freeze
      end

      # `PromptResponse.stopReason`.
      module StopReason
        END_TURN = "end_turn".freeze
        MAX_TOKENS = "max_tokens".freeze
        MAX_TURN_REQUESTS = "max_turn_requests".freeze
        REFUSAL = "refusal".freeze
        CANCELLED = "cancelled".freeze
      end
      STOP_REASONS = [
        StopReason::END_TURN, StopReason::MAX_TOKENS, StopReason::MAX_TURN_REQUESTS, StopReason::REFUSAL,
        StopReason::CANCELLED,
      ].freeze

      # `session/request_permission`.
      module PermissionOptionKind
        ALLOW_ONCE = "allow_once".freeze
        ALLOW_ALWAYS = "allow_always".freeze
        REJECT_ONCE = "reject_once".freeze
        REJECT_ALWAYS = "reject_always".freeze
      end
      PERMISSION_OPTION_KINDS = [
        PermissionOptionKind::ALLOW_ONCE, PermissionOptionKind::ALLOW_ALWAYS, PermissionOptionKind::REJECT_ONCE,
        PermissionOptionKind::REJECT_ALWAYS,
      ].freeze
      module PermissionOutcome
        SELECTED = "selected".freeze
        CANCELLED = "cancelled".freeze
      end
      PERMISSION_OUTCOMES = [PermissionOutcome::SELECTED, PermissionOutcome::CANCELLED].freeze

      # `ContentBlock.type`.
      module ContentBlock
        TEXT = "text".freeze
        IMAGE = "image".freeze
        AUDIO = "audio".freeze
        RESOURCE_LINK = "resource_link".freeze
        RESOURCE = "resource".freeze
      end
      CONTENT_BLOCK_TYPES = [
        ContentBlock::TEXT, ContentBlock::IMAGE, ContentBlock::AUDIO, ContentBlock::RESOURCE_LINK, ContentBlock::RESOURCE,
      ].freeze

      # `session/update` params `{sessionId, update: {sessionUpdate: <kind>, …}}`, stable
      # kinds only.
      SESSION_UPDATE_DISCRIMINATOR = "sessionUpdate".freeze
      module SessionUpdate
        USER_MESSAGE_CHUNK = "user_message_chunk".freeze
        AGENT_MESSAGE_CHUNK = "agent_message_chunk".freeze
        AGENT_THOUGHT_CHUNK = "agent_thought_chunk".freeze
        TOOL_CALL = "tool_call".freeze
        TOOL_CALL_UPDATE = "tool_call_update".freeze
        PLAN = "plan".freeze
        AVAILABLE_COMMANDS_UPDATE = "available_commands_update".freeze
        CURRENT_MODE_UPDATE = "current_mode_update".freeze
        CONFIG_OPTION_UPDATE = "config_option_update".freeze
        SESSION_INFO_UPDATE = "session_info_update".freeze
        USAGE_UPDATE = "usage_update".freeze
      end
      SESSION_UPDATE_KINDS = [
        SessionUpdate::USER_MESSAGE_CHUNK, SessionUpdate::AGENT_MESSAGE_CHUNK, SessionUpdate::AGENT_THOUGHT_CHUNK,
        SessionUpdate::TOOL_CALL, SessionUpdate::TOOL_CALL_UPDATE, SessionUpdate::PLAN,
        SessionUpdate::AVAILABLE_COMMANDS_UPDATE, SessionUpdate::CURRENT_MODE_UPDATE,
        SessionUpdate::CONFIG_OPTION_UPDATE, SessionUpdate::SESSION_INFO_UPDATE, SessionUpdate::USAGE_UPDATE,
      ].freeze

      # Tool calls: `ToolKind`, `ToolCallStatus`, `ToolCallContent.type`.
      module ToolKind
        READ = "read".freeze
        EDIT = "edit".freeze
        DELETE = "delete".freeze
        MOVE = "move".freeze
        SEARCH = "search".freeze
        EXECUTE = "execute".freeze
        THINK = "think".freeze
        FETCH = "fetch".freeze
        SWITCH_MODE = "switch_mode".freeze
        OTHER = "other".freeze
      end
      TOOL_KINDS = [
        ToolKind::READ, ToolKind::EDIT, ToolKind::DELETE, ToolKind::MOVE, ToolKind::SEARCH, ToolKind::EXECUTE,
        ToolKind::THINK, ToolKind::FETCH, ToolKind::SWITCH_MODE, ToolKind::OTHER,
      ].freeze
      module ToolCallStatus
        PENDING = "pending".freeze
        IN_PROGRESS = "in_progress".freeze
        COMPLETED = "completed".freeze
        FAILED = "failed".freeze
      end
      TOOL_CALL_STATUSES = [
        ToolCallStatus::PENDING, ToolCallStatus::IN_PROGRESS, ToolCallStatus::COMPLETED, ToolCallStatus::FAILED,
      ].freeze
      TOOL_CALL_CONTENT_TYPES = %w[content diff terminal].freeze

      # The plan.
      PLAN_PRIORITIES = %w[high medium low].freeze
      PLAN_STATUSES = %w[pending in_progress completed].freeze

      # Auth, elicitation, config options, MCP entries.
      module AuthMethodType
        AGENT = "agent".freeze
        TERMINAL = "terminal".freeze
      end
      AUTH_METHOD_TYPES = [AuthMethodType::AGENT, AuthMethodType::TERMINAL].freeze
      ELICITATION_MODES = %w[form url].freeze
      module ElicitationAction
        ACCEPT = "accept".freeze
        DECLINE = "decline".freeze
        CANCEL = "cancel".freeze
      end
      ELICITATION_ACTIONS = [ElicitationAction::ACCEPT, ElicitationAction::DECLINE, ElicitationAction::CANCEL].freeze
      CONFIG_OPTION_TYPES = %w[select boolean].freeze
      CONFIG_OPTION_CATEGORIES = %w[mode model model_config thought_level].freeze
      # A stdio entry carries no `type`; the other two forms name theirs.
      MCP_SERVER_TYPES = %w[http sse].freeze

      # The capability shapes: key lists as the schema spells them, and the document each role
      # sends when it claims only the baseline (the schema's defaults, spelled out).
      CLIENT_CAPABILITY_KEYS = %w[fs terminal auth elicitation session].freeze
      FS_CAPABILITY_KEYS = %w[readTextFile writeTextFile].freeze
      ELICITATION_CAPABILITY_KEYS = %w[form url].freeze
      AGENT_CAPABILITY_KEYS = %w[loadSession promptCapabilities mcpCapabilities sessionCapabilities auth].freeze
      PROMPT_CAPABILITY_KEYS = %w[image audio embeddedContext].freeze
      MCP_CAPABILITY_KEYS = %w[http sse].freeze
      SESSION_CAPABILITY_KEYS = %w[list delete additionalDirectories resume close].freeze

      BASELINE_CLIENT_CAPABILITIES = {
        "fs" => { "readTextFile" => false, "writeTextFile" => false }.freeze,
        "terminal" => false,
        "auth" => { "terminal" => false }.freeze,
      }.freeze
      BASELINE_AGENT_CAPABILITIES = {
        "loadSession" => false,
        "promptCapabilities" => { "image" => false, "audio" => false, "embeddedContext" => false }.freeze,
        "mcpCapabilities" => { "http" => false, "sse" => false }.freeze,
      }.freeze
    end
  end
end
