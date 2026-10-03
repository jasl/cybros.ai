# What this executor serves: the announcement, stored canonical and replaced
# whole by one verb, read by addressing and discovery. It never shapes the per-round
# tools list — the declaration is the model's fact with its own writer
# (User::AgentConfiguration) — with ONE bounded exception: the `skill`
# entry's PRESENCE, omitted at the wire when no source (announced, workspace
# or user) holds a skill; no entry's bytes are ever shaped. The environment
# document rides the same verb: opaque, whole-replaced with the list, read
# by discovery and never by the kernel. The DOCUMENTS ride it too: what this
# executor can LOAD for a model — a project's skills; an MCP server's
# prompts and resources curated into the same shape — as `{name,
# description}` entries, kept as the announcement and never as rows, read by
# the turn's skills catalog and by the `skill` load's addressing.
module TaskExecutor::Announcement
  extend ActiveSupport::Concern

  included do
    validates :served_tools, bounded_json: { bound: :envelope_bound, shape: Array }
    validates :served_documents, bounded_json: { bound: :envelope_bound, shape: Array }
    validates :environment, bounded_json: { bound: :executor_environment_bound, shape: Hash }
  end

  # Whole replacement, the `declare_configuration` shape: a plain save with
  # no explicit lock — a single-row overwrite with no invariant across rows,
  # last writer wins. An absent environment is `{}` and an absent documents
  # list is `[]` — one write shape on one verb, never a partial update.
  def announce(tools:, environment: nil, documents: nil)
    refusal = Nexus::ToolAnnouncements.refusal(tools) ||
      Nexus::ToolAnnouncements.environment_refusal(environment) ||
      Nexus::ToolAnnouncements.document_refusal(documents)
    if refusal
      TaskExecutors::Outcome.new(outcome: refusal.code.to_sym, executor: self, detail: refusal.detail)
    else
      self.served_tools = Nexus::ToolAnnouncements.canonical(tools)
      self.environment = environment || {}
      self.served_documents = Nexus::ToolAnnouncements.canonical_documents(documents)
      TaskExecutors::Outcome.new(outcome: save ? :announced : :invalid, executor: self)
    end
  end

  def served?(name) = serving(name).present?

  # The announcement ENTRY for a name — `{name, effect_profile, timeout_ms?,
  # description?, input_schema?}`; nil when unserved.
  def serving(name)
    served_tools.find { |entry| entry["name"] == name.to_s }
  end

  # The effect-profile document addressing freezes onto the row at dispatch:
  # the five keys plus the announced `timeout_ms`, the one shape a kernel
  # row's registry profile also takes, so the sweep's SQL twin reads
  # `effect_profile->>'timeout_ms'` on every row alike.
  def effect_profile_for(name)
    entry = serving(name)
    return if entry.nil?

    entry.fetch("effect_profile").merge(entry.slice("timeout_ms"))
  end
end
