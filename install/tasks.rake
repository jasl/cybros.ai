# The installer's rake tasks, loaded by
# agents/rho/rho/Rakefile: `install:render` writes install/manifest.sh and
# the standalone install/install.sh from src/*.sh and install/manifest.json;
# `install:check` refuses a stale rendering (no network; part of
# `install:test`); `install:bump` refreshes the manifest from every
# publisher (network; never in CI).
namespace :install do
  desc "Render the manifest and source fragments into the standalone installer"
  task :render do
    require_relative "lib/rho_install/render"
    RhoInstall::Render.run.each { |path| puts "rendered #{path}" }
  end

  desc "Fail when the rendered installer or manifest differs from its sources"
  task :check do
    require_relative "lib/rho_install/render"
    stale = RhoInstall::Render.stale
    abort "stale against install/src or manifest.json: #{stale.join(", ")} — run `rake install:render`" unless stale.empty?
    puts "install/manifest.sh and install/install.sh match install/src and manifest.json"
  end

  desc "Refresh install/manifest.json from every publisher (network), then render"
  task bump: [] do
    require_relative "lib/rho_install/bump"
    puts "wrote #{RhoInstall::Bump.new.run}"
    Rake::Task["install:render"].invoke
  end

  desc "shellcheck and the installer's shell tests (install/test/run.sh)"
  task test: :check do
    sh File.expand_path("test/run.sh", __dir__)
  end
end
