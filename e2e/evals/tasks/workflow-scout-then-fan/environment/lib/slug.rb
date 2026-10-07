# Turns a title into a lower-case, dash-separated slug.
module Slug
  module_function

  def slugify(title)
    title.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")
  end
end
