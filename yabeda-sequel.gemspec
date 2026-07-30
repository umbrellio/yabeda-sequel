# frozen_string_literal: true

require_relative "lib/yabeda/sequel/version"

Gem::Specification.new do |spec|
  spec.name = "yabeda-sequel"
  spec.version = Yabeda::Sequel::VERSION
  spec.authors = ["Team Umbrellio"]
  spec.email = ["oss@umbrellio.biz"]

  spec.summary = "Yabeda plugin for Sequel connection pool metrics"
  spec.description = "Connection pool and async thread pool metrics for Sequel, " \
                     "correct under forking servers such as Puma in clustered mode."
  spec.homepage = "https://github.com/umbrellio/yabeda-sequel"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/master/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true",
  }

  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]

  spec.add_dependency("anyway_config", ">= 1.3", "< 3")
  spec.add_dependency("sequel", ">= 5.60")
  spec.add_dependency("yabeda", "~> 0.6")
end
