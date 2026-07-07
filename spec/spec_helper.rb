# frozen_string_literal: true

require "fdp_index_proxy"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # FDP's cache/registry are process-global class variables; reset them
  # between examples so tests don't leak state into each other, and never
  # let a test write into the real (git-tracked) cache/registry.json.
  config.before do
    FDP.class_variable_set(:@@cache, {})
    FDP.class_variable_set(:@@url_registry, [])
    allow(File).to receive(:write)
    allow(FileUtils).to receive(:mkdir_p)
  end
end
