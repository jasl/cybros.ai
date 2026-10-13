# Candidate A.
def slugify(text)
  slug = text.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
  slug = "n-a" if slug.empty?
  slug[0, 40]
end
