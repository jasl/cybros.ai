# The one word for each machine kind: the runners console and the
# device-grant pages name the same thing the same way, or a person connects
# a "Tools provider" and then finds a "Runner" on the management page.
module RunnersHelper
  def machine_kind_label(executor_kind)
    t("runners.kinds").fetch(executor_kind.to_sym)
  end
end
