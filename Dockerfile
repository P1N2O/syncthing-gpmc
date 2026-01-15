FROM python:slim

# Install dependencies
RUN apt-get update && apt-get install -y \
    inotify-tools \
    gosu \
    git \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Install gpmc
RUN pip install "https://github.com/xob0t/google_photos_mobile_client/archive/refs/heads/main.zip" --force-reinstall

WORKDIR /app

# Create the sync logic script
RUN cat <<'EOF' > /app/sync_logic.sh
#!/bin/bash
echo "Starting Background Watcher..."

# 1. Start the Continuous Monitor in the background (&)
# -m: Monitor mode (don't exit)
# -r: Recursive
# We pipe the output to a loop that creates a trigger file
inotifywait -m -r -e moved_to -e close_write --format '%f' /watch | while read filename; do
    # Create the trigger file whenever a change is detected
    touch /tmp/sync_needed
done &

echo "Watcher active. Starting Main Loop..."

# 2. Main Upload Loop
while true; do
    # Check if the trigger file exists (meaning a change happened)
    # OR if enough time has passed (Safety Interval)
    current_time=$(date +%s)
    last_run=${LAST_RUN:-0}
    diff=$((current_time - last_run))
    
    if [ -f /tmp/sync_needed ] || [ "$diff" -ge "$SYNC_INTERVAL" ]; then
        echo "[$(date)] Trigger detected (or interval). Debouncing..."
        
        # Wait 5 seconds to let a batch of files finish arriving
        sleep 5
        
        # Remove the trigger flag *before* uploading.
        # If a new file arrives *during* the upload, the flag will be recreated, 
        # ensuring we run again immediately after this finishes.
        rm -f /tmp/sync_needed
        
        echo "Running Upload..."
        gpmc /watch --progress --delete-from-host --recursive --threads $THREADS
        
        # Update the last run time
        LAST_RUN=$(date +%s)
        echo "[$(date)] Sync Cycle Finished."
    else
        # Sleep briefly to save CPU
        sleep 2
    fi
done
EOF

# Make logic script executable
RUN chmod +x /app/sync_logic.sh

# Create the Entrypoint
RUN cat <<'EOF' > /entrypoint.sh
#!/bin/bash
set -e

USER_ID=${PUID:-1000}
GROUP_ID=${PGID:-1000}
export THREADS=${THREADS:-4}
# Default safety interval to 1 hour (3600s) if not set
export SYNC_INTERVAL=${SYNC_INTERVAL:-3600}

# Thread Cap
if [ "$THREADS" -gt 4 ]; then
    export THREADS=4
fi

# User/Group Setup
if ! getent group "$GROUP_ID" >/dev/null; then
    groupadd -g "$GROUP_ID" appgroup
fi
if ! id -u "$USER_ID" >/dev/null 2>&1; then
    useradd -u "$USER_ID" -g "$GROUP_ID" -o -m -d /config appuser
fi

echo "-----------------------------------------"
echo "Container Started"
echo "User: $USER_ID | Group: $GROUP_ID"
echo "Threads: $THREADS"
echo "Sync Interval: ${SYNC_INTERVAL}s"
echo "-----------------------------------------"

chown -R "$USER_ID":"$GROUP_ID" /config

# Execute the logic script as the specific user
exec gosu "$USER_ID":"$GROUP_ID" /app/sync_logic.sh
EOF

RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]