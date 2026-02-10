#!/bin/sh
set -e  # Exit on any error

# Ensure cache directory exists
mkdir -p /server/cache

# Start cron in background
cron

# Optional: Tail cron logs for debugging (in background)
tail -f /var/log/cron.log &

# Run the main app, forwarding signals for graceful shutdown
exec /usr/local/bin/ruby /server/run.rb -o 0.0.0.0