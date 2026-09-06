# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require_relative "../lib/rcodex"

class GemTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_gem_metadata_and_package_contents
    spec = Gem::Specification.load(File.join(ROOT, "rcodex.gemspec"))
    assert_equal "rcodex", spec.name
    assert_equal RCodex::VERSION, spec.version.to_s
    assert_equal ["rcodex"], spec.executables
    assert_equal "bin", spec.bindir
    assert_includes spec.files, "bin/rcodex"
    assert_includes spec.files, "lib/rcodex.rb"
    assert_includes spec.files, "lib/rcodex/version.rb"
    refute spec.files.any? { |path| path.end_with?(".swp", ".gem") }
    assert File.executable?(File.join(ROOT, "bin/rcodex"))
  end

  def test_executable_runs_outside_the_checkout
    output, error, status = Open3.capture3(
      RbConfig.ruby, File.join(ROOT, "bin/rcodex"), "--version", chdir: File.dirname(ROOT)
    )
    assert status.success?, error
    assert_equal "rcodex #{RCodex::VERSION}\n", output
    assert_empty error
  end

  def test_requiring_library_has_no_cli_side_effects
    output, error, status = Open3.capture3(
      RbConfig.ruby, "-I", File.join(ROOT, "lib"), "-e", 'require "rcodex"'
    )
    assert status.success?, error
    assert_empty output
    assert_empty error
  end
end
