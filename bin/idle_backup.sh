#!/bin/bash

# --- Configuration ---
# Directory to backup
SOURCE="/home/$USER/"
# Where to store the incremental backups (must exist)
DEST="/path/to/your/backup/drive/incremental/"
# Log file location
LOG_FILE="/home/$USER/backup_log.txt"
# Idle time in milliseconds (5 minutes = 300000ms)
IDLE_THRESHOLD=300000

# --- Functions ---
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

do_backup() {
    log "System idle. Starting incremental backup..."
    
    # rsync options:
    # -a: archive mode (preserves permissions, times, etc.)
    # -v: verbose
    # --delete: delete files in backup that no longer exist in source
    # --link-dest: hardlink unchanged files to previous backup (creates snapshots)
    
    # Create a timestamped folder for the snapshot format
    DATE_SUFFIX=$(date '+%Y-%m-%d_%H-%M-%S')
    LATEST_LINK="$DEST/latest"
    
    # Run rsync
    rsync -av --delete \
        --link-dest="$LATEST_LINK" \
        "$SOURCE" "${DEST}${DATE_SUFFIX}/" \
        >> "$LOG_FILE" 2>&1

    # Update the 'latest' symbolic link to point to the new backup
    # We remove the old link and create a new one atomically
    ln -s "${DEST}${DATE_SUFFIX}" "${DEST}/latest_tmp"
    mv -Tf "${DEST}/latest_tmp" "$LATEST_LINK"

    log "Backup finished."
}

# --- Main Loop ---
log "Idle backup service started."

# Initial state: We assume we are ready to backup once we go idle.
# We set this to 0 so the first loop iteration doesn't trigger immediately if we just woke up.
BACKUP_READY=0

while true; do
    # Get idle time in milliseconds
    IDLE_TIME=$(xprintidle)
    
    # Check if idle time command failed (e.g. not in X session)
    if [ -z "$IDLE_TIME" ]; then
        sleep 60
        continue
    fi

    if [ "$IDLE_TIME" -ge "$IDLE_THRESHOLD" ]; then
        # We are idle
        if [ "$BACKUP_READY" -eq 1 ]; then
            do_backup
            # Flip the switch: don't backup again until activity is detected
            BACKUP_READY=0
        fi
    else
        # We are active (mouse/keyboard input detected)
        # Reset the trigger so we can backup next time we go idle
        if [ "$BACKUP_READY" -eq 0 ]; then
             log "User activity detected. Ready for next idle backup."
        fi
        BACKUP_READY=1
    fi

    # Check every 10 seconds
    sleep 10
done
