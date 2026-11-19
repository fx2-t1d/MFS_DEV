require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

class UpdateDependenciesTest < Minitest::Test
  SCRIPT = File.expand_path("update_dependencies.sh", __dir__)

  def setup
    @directory = Dir.mktmpdir("mfs-dependency-test")
    @environment = {
      "GIT_AUTHOR_NAME" => "Test", "GIT_AUTHOR_EMAIL" => "test@example.com",
      "GIT_COMMITTER_NAME" => "Test", "GIT_COMMITTER_EMAIL" => "test@example.com",
      "GIT_ALLOW_PROTOCOL" => "file"
    }
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def command(*args, chdir: @directory)
    stdout, stderr, status = Open3.capture3(@environment, *args, chdir: chdir)
    assert status.success?, "#{args.inspect}: #{stderr}"
    stdout.strip
  end

  def test_updates_only_selected_submodule_to_remote_head
    source = File.join(@directory, "source")
    app = File.join(@directory, "app")
    FileUtils.mkdir_p([source, app])
    command("git", "init", "-q", source)
    File.write(File.join(source, "file"), "first")
    command("git", "add", "file", chdir: source)
    command("git", "commit", "-qm", "first", chdir: source)
    command("git", "init", "-q", app)
    command("git", "submodule", "add", "-q", source, "LoopKit", chdir: app)
    command("git", "add", ".", chdir: app)
    command("git", "commit", "-qm", "add submodule", chdir: app)
    original = command("git", "rev-parse", "HEAD", chdir: File.join(app, "LoopKit"))

    File.write(File.join(source, "file"), "second")
    command("git", "commit", "-qam", "second", chdir: source)
    latest = command("git", "rev-parse", "HEAD", chdir: source)
    command("bash", SCRIPT, "LoopKit", chdir: app)

    refute_equal original, latest
    assert_equal latest, command("git", "rev-parse", "HEAD", chdir: File.join(app, "LoopKit"))
    assert_includes command("git", "diff", "--name-only", chdir: app), "LoopKit"
  end

  def test_updates_fastlane_pin_without_installing_before_scan
    bin = File.join(@directory, "bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(@directory, "Gemfile"), "source \"https://rubygems.org\"\ngem \"fastlane\", \"2.240.1\"\n")
    File.write(File.join(bin, "curl"), "#!/bin/sh\nprintf '%s' '{\"version\":\"2.241.2\"}'\n")
    File.write(File.join(bin, "bundle"), "#!/bin/sh\nprintf '%s' \"$*\" > bundle-arguments\n")
    FileUtils.chmod(0o755, [File.join(bin, "curl"), File.join(bin, "bundle")])
    @environment["PATH"] = "#{bin}:#{ENV.fetch("PATH")}"
    command("bash", SCRIPT, "fastlane")
    assert_includes File.read(File.join(@directory, "Gemfile")), 'gem "fastlane", "2.241.2"'
    refute File.exist?(File.join(@directory, "bundle-arguments"))
  end

  def test_rejects_missing_or_unknown_selection
    [[], ["unknown"]].each do |args|
      _, stderr, status = Open3.capture3(@environment, "bash", SCRIPT, *args, chdir: @directory)
      refute status.success?
      refute_empty stderr
    end
  end

  def test_tested_commit_can_be_published_from_a_shallow_checkout
    remote = File.join(@directory, "remote")
    checkout = File.join(@directory, "checkout")
    publisher = File.join(@directory, "publisher")
    bundle = File.join(@directory, "update.bundle")
    command("git", "init", "-q", "--bare", remote)
    command("git", "clone", "-q", remote, checkout)
    File.write(File.join(checkout, "file"), "first")
    command("git", "add", "file", chdir: checkout)
    command("git", "commit", "-qm", "base", chdir: checkout)
    command("git", "push", "-q", "origin", "HEAD", chdir: checkout)
    FileUtils.remove_entry(checkout)
    command("git", "clone", "-q", "--depth", "1", "file://#{remote}", checkout)
    File.write(File.join(checkout, "file"), "updated")
    command("git", "commit", "-qam", "update", chdir: checkout)
    commit = command("git", "rev-parse", "HEAD", chdir: checkout)
    command("git", "branch", "dependency-update", commit, chdir: checkout)
    command("git", "bundle", "create", bundle, "refs/heads/dependency-update", "^#{commit}^", chdir: checkout)

    command("git", "clone", "-q", remote, publisher)
    command("git", "fetch", bundle, "refs/heads/dependency-update", chdir: publisher)
    assert_equal commit, command("git", "rev-parse", "FETCH_HEAD", chdir: publisher)
    branch = command("git", "branch", "--show-current", chdir: publisher)
    command("git", "push", "origin", "#{commit}:refs/heads/#{branch}", chdir: publisher)
    assert_equal commit, command("git", "--git-dir", remote, "rev-parse", "refs/heads/#{branch}")
  end
end
