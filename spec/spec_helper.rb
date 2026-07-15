# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Must be set before lib/fdp.rb is loaded — FDP::REGISTRY_PATH is resolved at
# require time.  Points the persistent URL registry at a throwaway temp file
# so the suite can exercise real read-merge-write behaviour without ever
# touching the git-tracked cache/registry.json.
ENV["FDP_REGISTRY_PATH"] ||= File.join(Dir.mktmpdir("fdp-index-proxy-spec"), "registry.json")

require "fdp_index_proxy"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # FDP's cache/registry are process-global class variables (plus a persisted
  # registry file); reset all of them between examples so tests don't leak
  # state into each other.
  config.before do
    FDP.class_variable_set(:@@cache, {})
    FDP.class_variable_set(:@@url_registry, [])
    FileUtils.rm_f(FDP::REGISTRY_PATH)
  end
end
