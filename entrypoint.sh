#!/bin/sh
set -e  # Exit on any error

# Start cron in background
service cron start

# Optional: Tail cron logs for debugging (in background)
tail -f /var/log/cron.log &

# Run the main app, forwarding signals for graceful shutdown
exec /usr/local/bin/ruby /server/application/controllers/application_controller.rb -o 0.0.0.0