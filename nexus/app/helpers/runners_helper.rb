# The one word for each machine kind: the runners console and the
# device-grant pages name the same thing the same way, or a person connects
# a "Tools provider" and then finds a "Runner" on the management page.
module RunnersHelper
  MACHINE_KIND_LABELS = {
    "runner" => "Runner",
    "tool_provider" => "Tools provider",
  }.freeze

  def machine_kind_label(executor_kind)
    MACHINE_KIND_LABELS.fetch(executor_kind.to_s)
  end
end
