#!/bin/bash

# --- Configuration ---
# List the directories you want to monitor here, separated by spaces.
WATCH_DIRS=("/etc" "/bin" "/sbin" "/var/www/html")
DB_NAME="File System Integrity Database"

# --- Function to log to Syslog ---
# This sends an alert to /var/log/syslog (or /var/log/messages)
log_alert() {
    local message="$1"
    # 'logger' is the standard CLI tool for system logging
    # -p local0.crit sets a high priority alert
    # -t FIM_MONITOR adds a tag for easy searching
    logger -p local0.crit -t FIM_MONITOR "$message"
}

# --- Main Monitoring Loop ---
for DIR in "${WATCH_DIRS[@]}"; do
    DB_PATH="$DIR/$DB_NAME"

    # 1. Skip if the database doesn't exist yet
    if [ ! -f "$DB_PATH" ]; then
        log_alert "Check failed: No database found in $DIR. Run check_integrity.sh first."
        continue
    fi

    # 2. Check for Modified Files (Hash Mismatch)
    # We capture only the failures
    MODIFIED=$(sha256sum --check "$DB_PATH" 2>&1 | grep "FAILED")
    
    if [ ! -z "$MODIFIED" ]; then
        while read -r line; do
            log_alert "MODIFICATION DETECTED: $line in directory $DIR"
        done <<< "$MODIFIED"
    fi

    # 3. Identify Added and Deleted Files
    # Generate a temporary snapshot of current files
    CURRENT_SCAN=$(mktemp)
    find "$DIR" -type f -not -name "$DB_NAME" -print0 | xargs -0 sha256sum > "$CURRENT_SCAN"

    # Compare filenames using the 'comm' utility
    # Added files (present in current scan but not in DB)
    ADDED=$(comm -13 <(awk '{print $2}' "$DB_PATH" | sort) <(awk '{print $2}' "$CURRENT_SCAN" | sort))
    for file in $ADDED; do
        log_alert "NEW FILE DETECTED: $file in $DIR"
    done

    # Deleted files (present in DB but not in current scan)
    DELETED=$(comm -23 <(awk '{print $2}' "$DB_PATH" | sort) <(awk '{print $2}' "$CURRENT_SCAN" | sort))
    for file in $DELETED; do
        log_alert "FILE MISSING: $file from $DIR"
    done

    # Cleanup temp file for this iteration
    rm "$CURRENT_SCAN"
done
