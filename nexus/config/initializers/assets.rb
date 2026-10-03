# Be sure to restart your server when you modify this file.

# Version of your assets, change this if you want to expire all your assets.
Rails.application.config.assets.version = "1.0"

# Add additional assets to the asset load path.
# Rails.application.config.assets.paths << Emoji.images_path

# THE BUILD'S INPUT IS NOT AN ASSET. Propshaft digests every file on its load
# path, so `app/assets/stylesheets/application.tailwind.css` — the source the
# Tailwind CLI compiles into `builds/application.css` — was being served as a
# second, public stylesheet nothing links. Same rule as the sourcemap in
# bun.config.js: what lands under app/assets is what production serves.
Rails.application.config.assets.excluded_paths << Rails.root.join("app/assets/stylesheets")
