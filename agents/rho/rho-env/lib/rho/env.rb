require "etc"
require "monitor"
require "time"
require "cybros_agent"

require_relative "env/version"
require_relative "env/errors"
require_relative "env/truncation"
require_relative "env/file_mutation_queue"
require_relative "env/tool_env"
require_relative "env/environment"
require_relative "env/owned_process"
require_relative "env/redact"
require_relative "env/secrets"
require_relative "env/child_env"
require_relative "env/subprocess"
require_relative "env/tools/read"
require_relative "env/tools/write"
require_relative "env/tools/edit"
require_relative "env/tools/ls"
require_relative "env/tools/grep"
require_relative "env/tools/find"
require_relative "env/tools/bash"
require_relative "env/files"
require_relative "env/tools/files_bytes"
require_relative "env/tools/git_review"
require_relative "env/tools/file_import"
require_relative "env/tools/file_publish"
require_relative "env/skills"
require_relative "env/tools/skill"
require_relative "env/checkpoints/record"
require_relative "env/checkpoints/git"
require_relative "env/checkpoints/store"
require_relative "env/tools/checkpoint_restore"
require_relative "env/tools/checkpoints"
require_relative "env/execution_context"
require_relative "env/fs_port"
require_relative "env/deadline_extension"
require_relative "env/claim_status_poller"
require_relative "env/claim_realtime"
require_relative "env/claim_attachments"
require_relative "env/progress"
require_relative "env/result"
require_relative "env/claim_orchestration"
require_relative "env/storable_text"
require_relative "env/admission"
require_relative "env/pool"
require_relative "env/extensions/tool"
require_relative "env/extensions/hooks"
require_relative "env/extensions/resources"
require_relative "env/extensions/api"
require_relative "env/extensions/registry"
require_relative "env/extensions/loader"
require_relative "env/input_schema"
require_relative "env/toolset"
require_relative "env/placement"
# AFTER `toolset`, because the built-ins' own extension names the tool
# classes and the registry that will hold them.
require_relative "env/extensions/coding/report"
require_relative "env/extensions/coding"
require_relative "env/extensions/terminal"
require_relative "env/extensions/checkpoints"
# AFTER the extensions: `Toolsets.fixed` builds the coding set.
require_relative "env/toolsets"
require_relative "env/task_run"


module Rho
  module Env
    # THE PROGRAM'S ROOT: the directory this gem is loaded from — a checkout in development,
    # the installed gem in production — which rho's self-modification deny rules protect
    # beside its own: the toolset gem is the program too.
    def self.root = File.expand_path("../..", __dir__)
  end
end

require_relative "env/executor"
