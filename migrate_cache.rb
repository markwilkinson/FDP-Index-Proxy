#!/usr/bin/env ruby
# One-time migration script: reads legacy .marsh files and writes
# ./cache/registry.json so the new in-memory cache system knows which
# URLs were previously registered.
#
# Run from the project root BEFORE starting the new version:
#   ruby migrate_cache.rb
#
# After a successful run you can safely delete the .marsh files, or
# leave them in place — the new code ignores them entirely.

require "json"
require "fileutils"

CACHE_DIR     = "./cache"
REGISTRY_PATH = "#{CACHE_DIR}/registry.json".freeze

marsh_files = Dir.glob("#{CACHE_DIR}/*.marsh")

if marsh_files.empty?
  puts "No .marsh files found in #{CACHE_DIR} — nothing to migrate."
  exit 0
end

puts "Found #{marsh_files.size} .marsh file(s). Extracting addresses...\n\n"

addresses = []
errors    = []

marsh_files.each do |file|
  # Read the raw binary without deserialising — avoids needing RDF gems.
  # The @address string (a plain URL) is stored verbatim in the Marshal
  # stream, so a regex scan reliably extracts it without loading any classes.
  content = File.binread(file)
  urls    = content.scan(%r{https?://[^\x00-\x1F\s"\\]+})

  if urls.empty?
    errors << "#{file}: no http/https URL found in binary content"
    puts "  SKIP #{file} — no URL found"
  else
    # Take the first URL — that is @address (the source DCAT URL).
    # Subsequent URLs in the file are graph data, not the address.
    address = urls.first
    addresses << address
    puts "  OK   #{address}"
  end
rescue StandardError => e
  errors << "#{file}: #{e.message}"
  puts "  ERR  #{file} — #{e.message}"
end

puts "\n#{addresses.size} address(es) extracted."

if addresses.empty?
  puts "Nothing to write — registry.json not created."
  exit 1
end

addresses.uniq!
FileUtils.mkdir_p(CACHE_DIR)
File.write(REGISTRY_PATH, JSON.pretty_generate(addresses))

puts "Written to #{REGISTRY_PATH}"
puts "\nNext steps:"
puts "  1. Start the new service (bundle exec ruby run.rb)"
puts "  2. Call GET /fdp-index-proxy/ping to rebuild all caches and re-register"
puts "     with the FDP Index (or wait for the weekly cron)"
puts "  3. Delete the .marsh files once you are happy everything is working:"
puts "     rm #{CACHE_DIR}/*.marsh"

unless errors.empty?
  puts "\nWarnings (#{errors.size} file(s) could not be read):"
  errors.each { |e| puts "  #{e}" }
end
