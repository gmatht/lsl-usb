#!/bin/bash
SOURCE="/home/$USER/" 
# Note: $USER might not be set in a systemd root context. 
# It is better to hardcode the username or pass it as an argument.

# HARDCODE YOUR USERNAME HERE IF RUNNING AS ROOT:
USERNAME="your_username_here"
SOURCE="/home/$USERNAME/"
DEST="/path/to/your/backup/drive/full/"
LOG_FILE="/home/$USERNAME/shutdown_backup.log"

echo "$(date) - Shutdown initiated. Starting full backup..." >> "$LOG_FILE"

# Run a full backup
# We use a shorter timeout here because the system is shutting down.
# If the backup takes too long, the system might force-kill it.
rsync -av --delete "$SOURCE" "$DEST" >> "$LOG_FILE" 2>&1

echo "$(date) - Full backup completed." >> "$LOG_FILE"
