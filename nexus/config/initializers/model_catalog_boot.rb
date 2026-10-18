# Boot compiles and validates the ENTIRE catalog file candidate before the
# process serves anything: missing, malformed, duplicate, or inconsistent
# input fails fast here — partial publication and fallback boot are
# forbidden. `to_prepare` runs at boot AND after every development code
# reload (which unloads the reloadable ModelCatalog constant), so the current
# files are compiled into the fresh module; in production (no code reloading)
# it runs exactly once.
Rails.application.config.to_prepare do
  ModelCatalog.boot
end
