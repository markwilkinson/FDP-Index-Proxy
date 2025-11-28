# frozen_string_literal: true

require_relative "lib/fdp_index_proxy/version.rb"

Gem::Specification.new do |spec|
  spec.name = "fdp_index_proxy"
  spec.version = FdpIndexProxy::VERSION
  spec.authors = ["Mark Wilkinson"]
  spec.email = ["mark.wilkinson@upm.es"]

  spec.summary = "FDP Index Proxy"
  spec.description = "Allow FDP index to consume DCAT files"
  spec.homepage = "https://wkilkinsonlab.info"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/markwilkinson/FDP-Index-Proxy"
  spec.metadata["rubygems_mfa_required"] = "true"
  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir[File.join(__dir__, '{bin,exe,lib}', '**', '*')] + Dir[File.join(__dir__, '*.{md,md.erb,txt}')] + [File.join(__dir__, 'fdp_index_proxy.gemspec')]
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
