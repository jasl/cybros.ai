require "test_helper"

# `rho doctor` on a fabricated prefix: every row
# kind the receipt can carry, the (ruby, gems) pair, the launcher, and the
# checkout case with no prefix at all.
class DoctorTest < Minitest::Test
  RECEIPT = {
    "receipt_version" => 1, "installed_at" => "2026-09-13T00:00:00Z", "profile" => "full",
    "platform" => "darwin-arm64", "app" => { "version" => "0.1.0" },
    "ruby" => { "version" => "4.0.6_2", "bundler" => "4.0.18" }, "current" => "0.1.0-r4.0.6_2",
    "tools" => { "rg" => { "version" => "15.2.0" }, "jq" => { "version" => "1.8.2" } },
  }.freeze

  def fabricate(prefix, receipt: RECEIPT)
    FileUtils.mkdir_p(File.join(prefix, "bin"))
    FileUtils.mkdir_p(File.join(prefix, "ruby", "4.0.6_2", "bin"))
    FileUtils.mkdir_p(File.join(prefix, "versions", "0.1.0-r4.0.6_2"))
    File.symlink("4.0.6_2", File.join(prefix, "ruby", "current"))
    File.symlink("versions/0.1.0-r4.0.6_2", File.join(prefix, "current"))
    File.write(File.join(prefix, "versions", "0.1.0-r4.0.6_2", ".ruby"), "4.0.6_2\n")
    script(File.join(prefix, "bin", "rg"), "ripgrep 15.2.0")
    script(File.join(prefix, "bin", "jq"), "jq-1.8.2")
    launcher = File.join(prefix, "launcher", "rho")
    FileUtils.mkdir_p(File.dirname(launcher))
    script(launcher, "rho")
    File.write(File.join(prefix, "receipt.json"), JSON.generate(receipt.merge("launcher" => launcher)))
    launcher
  end

  def script(path, answer)
    File.write(path, "#!/bin/sh\necho '#{answer}'\n")
    File.chmod(0o755, path)
  end

  def rows_by_name(report) = report.rows.to_h { |row| [row.name, row] }

  def test_a_fabricated_prefix_answers_every_row_kind
    Dir.mktmpdir("rho-doctor") do |dir|
      prefix = File.realpath(dir)
      launcher = fabricate(prefix)
      env = { "RHO_PREFIX" => prefix, "RHO_HOME" => File.join(prefix, "home"), "PATH" => "#{File.dirname(launcher)}:/usr/bin:/bin", "LANG" => "C.UTF-8" }
      home = Rho::Home.resolve(base_url: "https://nexus.example", root: env["RHO_HOME"])
      report = Rho::Doctor.run(env: env, home: home)
      rows = rows_by_name(report)

      assert_match(/profile full, darwin-arm64, rho 0\.1\.0/, report.heading)
      assert_equal :ok, rows.fetch("rg").status
      assert_equal :ok, rows.fetch("jq").status
      assert_equal :ok, rows.fetch("current").status, rows.fetch("current").detail
      assert_equal :ok, rows.fetch("launcher").status, rows.fetch("launcher").detail
      assert_equal :ok, rows.fetch("locale").status
      assert_equal :warn, rows.fetch("home").status, "a home that does not exist yet is a warning"
      assert_equal :fail, rows.fetch("ruby").status, "this suite's Ruby is not the prefix's"
      assert_match(/not the prefix's|the receipt says/, rows.fetch("ruby").detail)
      assert_equal :ok, rows.fetch("bundler").status, rows.fetch("bundler").detail
      assert_predicate report, :failed?
      assert_match(/\bFAIL  ruby\b/, report.render)
    end
  end

  def test_a_wrong_tool_a_broken_pair_and_a_launcher_off_path_are_red
    Dir.mktmpdir("rho-doctor") do |dir|
      prefix = File.realpath(dir)
      fabricate(prefix)
      script(File.join(prefix, "bin", "rg"), "ripgrep 14.1.0")
      File.write(File.join(prefix, "versions", "0.1.0-r4.0.6_2", ".ruby"), "4.0.5_1\n")
      env = { "RHO_PREFIX" => prefix, "RHO_HOME" => File.join(prefix, "home"), "PATH" => "/usr/bin:/bin", "LANG" => "C.UTF-8" }
      rows = rows_by_name(Rho::Doctor.run(env: env, home: nil))

      assert_equal :fail, rows.fetch("rg").status
      assert_match(/answers "ripgrep 14\.1\.0", the receipt says 15\.2\.0/, rows.fetch("rg").detail)
      assert_equal :fail, rows.fetch("current").status
      assert_match(/built against "4\.0\.5_1", ruby\/current is "4\.0\.6_2"/, rows.fetch("current").detail)
      assert_equal :warn, rows.fetch("launcher").status
      assert_match(/is not on PATH/, rows.fetch("launcher").detail)
      assert_equal :warn, rows.fetch("home").status
    end
  end

  def test_the_heading_names_the_checkout_commit_when_the_receipt_carries_one
    Dir.mktmpdir("rho-doctor") do |dir|
      prefix = File.realpath(dir)
      fabricate(prefix, receipt: RECEIPT.merge("app" => { "version" => "0.1.0", "commit" => "0123456789abcdef" }))
      report = Rho::Doctor.run(env: { "RHO_PREFIX" => prefix, "PATH" => "/usr/bin:/bin", "LANG" => "C.UTF-8" }, home: nil)
      assert_match(/rho 0\.1\.0 at 0123456, installed/, report.heading)
    end
  end

  # THE PREVIEWERS ROW: `pdftoppm` and `ffmpeg` reported, never
  # required — a host without them is a warning that names the missing
  # tool, the kernel's typed word, and the platform's package names.
  def test_the_previewers_row_warns_naming_the_missing_tool_and_is_ok_with_both_on_path
    Dir.mktmpdir("rho-doctor") do |dir|
      bare = rows_by_name(Rho::Doctor.run(env: { "LANG" => "C.UTF-8", "PATH" => "/nonexistent" }, home: nil))
      assert_equal :warn, bare.fetch("previewers").status
      assert_match(/no pdftoppm or ffmpeg on PATH/, bare.fetch("previewers").detail)
      assert_match(/representation_unavailable/, bare.fetch("previewers").detail)
      assert_match(/brew install poppler ffmpeg|apt install poppler-utils ffmpeg/, bare.fetch("previewers").detail)
      refute_predicate bare.fetch("previewers"), :failed?

      script(File.join(dir, "pdftoppm"), "pdftoppm version 25.04.0")
      half = rows_by_name(Rho::Doctor.run(env: { "LANG" => "C.UTF-8", "PATH" => dir }, home: nil))
      assert_equal :warn, half.fetch("previewers").status
      assert_match(/no ffmpeg on PATH/, half.fetch("previewers").detail)
      assert_match(/pdftoppm 25\.04\.0/, half.fetch("previewers").detail, "the one that is there is named")

      script(File.join(dir, "ffmpeg"), "ffmpeg version 8.0 Copyright (c) 2000-2026")
      both = rows_by_name(Rho::Doctor.run(env: { "LANG" => "C.UTF-8", "PATH" => dir }, home: nil))
      assert_equal :ok, both.fetch("previewers").status, both.fetch("previewers").detail
      assert_match(/pdftoppm 25\.04\.0; ffmpeg 8\.0/, both.fetch("previewers").detail)
    end
  end

  # THE CHECKPOINT STORES' ROW: under a home, the work root's
  # `checkpoints/` — the directory the Store names, so the doctor lists
  # where the daemon opens — none yet, or the stores counted with their
  # records through the Store's own read (packed refs count) and bytes;
  # no home, no row.
  def test_the_checkpoints_row_counts_the_stores_and_their_records_under_the_home
    Dir.mktmpdir("rho-doctor-checkpoints") do |dir|
      home = Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(dir, "home"))
      env = { "LANG" => "C.UTF-8", "PATH" => ENV.fetch("PATH") }
      none = rows_by_name(Rho::Doctor.run(env: env, home: home)).fetch("store")
      assert_equal :ok, none.status
      assert_equal "checkpoints", none.section
      assert_equal "#{File.join(home.work_root, "checkpoints")}: none yet", none.detail
      refute rows_by_name(Rho::Doctor.run(env: env, home: nil)).key?("store"), "no home, no row"

      root = File.join(dir, "project")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "a.txt"), "a")
      assert_equal "checkpoints", Rho::Runner::Checkpoints::Store::DIRECTORY, "the one spelling of the stores' directory"
      store = Rho::Runner::Checkpoints::Store.open(dir: File.join(home.work_root, Rho::Runner::Checkpoints::Store::DIRECTORY), root: root)
      store.capture(loop: "al-1")
      File.write(File.join(root, "a.txt"), "b")
      store.capture(loop: "al-2")
      row = rows_by_name(Rho::Doctor.run(env: env, home: home)).fetch("store")
      assert_equal :ok, row.status
      assert_match(/\A#{Regexp.escape(File.join(home.work_root, "checkpoints"))}: 1 store, 2 records, \d+\.\d MB\z/, row.detail)
      assert_equal "checkpoints", row.section

      env_git = { "GIT_DIR" => store.path, "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1" }
      assert system(env_git, "git", "pack-refs", "--all", out: File::NULL, err: File::NULL)
      assert_empty Dir.glob(File.join(store.path, "refs", "checkpoints", "*")), "the refs are packed"
      packed = rows_by_name(Rho::Doctor.run(env: env, home: home)).fetch("store")
      assert_match(/: 1 store, 2 records, /, packed.detail, "a packed ref is still a record")
    end
  end

  # THE TRUST STORE ROW:
  # the file SSL_CERT_FILE names, its roots counted, and the default store
  # — built the way every client builds one — shown to trust one of them,
  # offline; a file that is not there, with no cert dir standing in, is
  # red and says what to install. `set_default_paths` reads the process
  # environment, so the test sets both it and the context's env.
  def test_the_tls_row_names_the_store_it_trusts_and_is_red_without_one
    Dir.mktmpdir("rho-doctor-tls") do |dir|
      bundle = File.join(dir, "roots.pem")
      File.write(bundle, self_signed_root.to_pem)
      env = { "LANG" => "C.UTF-8", "PATH" => "/usr/bin:/bin", "SSL_CERT_FILE" => bundle, "SSL_CERT_DIR" => File.join(dir, "no-dir") }
      row = with_env(env.slice("SSL_CERT_FILE", "SSL_CERT_DIR")) { rows_by_name(Rho::Doctor.run(env: env, home: nil)).fetch("tls") }
      assert_equal :ok, row.status, row.detail
      assert_equal "runtime", row.section
      assert_match(/\A#{Regexp.escape(bundle)} \(SSL_CERT_FILE, 1 root, the store trusts them\); openssl \d+\.\d+\.\d+ \((the Ruby's own|from \S+)\), OpenSSL /, row.detail)

      missing = env.merge("SSL_CERT_FILE" => File.join(dir, "absent.pem"))
      row = with_env(missing.slice("SSL_CERT_FILE", "SSL_CERT_DIR")) { rows_by_name(Rho::Doctor.run(env: missing, home: nil)).fetch("tls") }
      assert_equal :fail, row.status, row.detail
      assert_match(/\A#{Regexp.escape(missing["SSL_CERT_FILE"])} \(SSL_CERT_FILE\) holds no root: .*ca-certificates/, row.detail)

      compiled = env.reject { |key, _| key.start_with?("SSL_CERT_") }
      row = with_env("SSL_CERT_FILE" => nil, "SSL_CERT_DIR" => nil) { rows_by_name(Rho::Doctor.run(env: compiled, home: nil)).fetch("tls") }
      assert_match(/\(OpenSSL's compiled (path|dir)[,)]/, row.detail, "unset, the row names OpenSSL's own default")
    end
  end

  def self_signed_root
    key = OpenSSL::PKey::EC.generate("prime256v1")
    root = OpenSSL::X509::Certificate.new
    root.version = 2
    root.serial = 1
    root.subject = root.issuer = OpenSSL::X509::Name.parse("/CN=rho doctor test root")
    root.public_key = key
    root.not_before = Time.now - 60
    root.not_after = Time.now + 3600
    factory = OpenSSL::X509::ExtensionFactory.new(root, root)
    root.add_extension(factory.create_extension("basicConstraints", "CA:TRUE", true))
    root.add_extension(factory.create_extension("keyUsage", "keyCertSign, cRLSign", true))
    root.add_extension(factory.create_extension("subjectKeyIdentifier", "hash"))
    root.sign(key, OpenSSL::Digest.new("SHA256"))
  end

  def with_env(values)
    saved = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def test_no_prefix_checks_the_environment_alone
    report = Rho::Doctor.run(env: { "LANG" => "C.UTF-8", "PATH" => ENV.fetch("PATH") }, home: nil)
    names = report.rows.map(&:name)
    assert_match(/no RHO_PREFIX/, report.heading)
    assert_includes names, "git"
    assert_includes names, "ruby"
    refute_includes names, "current"
    refute_includes names, "launcher"
    assert_equal :ok, rows_by_name(report).fetch("ruby").status
  end
end
