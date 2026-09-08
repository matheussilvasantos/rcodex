# frozen_string_literal: true

require_relative "lib/rcodex/version"

Gem::Specification.new do |spec|
  spec.name = "rcodex"
  spec.version = RCodex::VERSION
  spec.authors = ["Matheus Oliveira"]
  spec.summary = "A Ruby CLI for inspecting Codex usage"
  spec.description = "Inspect Codex rate-limit quotas with colored, simple, or JSON output via the local Codex app-server."
  spec.required_ruby_version = ">= 2.7"

  spec.files = Dir["lib/**/*.rb", "bin/*"] + ["README.md"]
  spec.bindir = "bin"
  spec.executables = ["rcodex"]
  spec.require_paths = ["lib"]

  spec.add_dependency "dry-inflector", "~> 1.0"
  spec.add_dependency "dry-struct", "~> 1.6"
  spec.add_dependency "dry-types", "~> 1.7"
  spec.add_dependency "json", ">= 2.3", "< 3"
  spec.add_dependency "open3", ">= 0.1", "< 1"
  spec.add_dependency "optparse", ">= 0.1", "< 1"
  spec.add_dependency "time", ">= 0.1", "< 1"
end
