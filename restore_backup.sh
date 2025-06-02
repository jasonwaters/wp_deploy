#!/bin/bash

# WordPress Backup Restore Script
# This script helps restore a production backup in case of emergency

set -euo pipefail

# =============================================================================
# LOAD CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/deploy_config.sh"

# Check if config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    echo "Please ensure deploy_config.sh exists and is configured."
    exit 1
fi

# Load configuration
source "$CONFIG_FILE"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

list_backups() {
    echo "Available backups:"
    echo "=================="

    # Create temporary file to store backup list
    local temp_list="${BACKUP_DIR}/.backup_list_temp"
    > "$temp_list"  # Clear the file

    if ls "$BACKUP_DIR"/prod_backup_*.tar.gz &>/dev/null; then
        local counter=1

        # Sort by modification time (newest first)
        ls -t "$BACKUP_DIR"/prod_backup_*.tar.gz | while read -r filepath; do
            filename=$(basename "$filepath")
            timestamp=$(echo "$filename" | sed 's/prod_backup_\(.*\)\.tar\.gz/\1/')

            # Format timestamp for display (works on both macOS and Linux)
            if [[ ${#timestamp} -eq 15 ]]; then
                # Format: YYYYMMDD_HHMMSS -> YYYY-MM-DD HH:MM:SS
                formatted_date="${timestamp:0:4}-${timestamp:4:2}-${timestamp:6:2} ${timestamp:9:2}:${timestamp:11:2}:${timestamp:13:2}"
            else
                formatted_date="$timestamp"
            fi

            # Get file size
            size=$(ls -lh "$filepath" | awk '{print $5}')
            echo "$counter. $filename - $formatted_date ($size)"

            # Store filename in temp file
            echo "$filename" >> "$temp_list"
            ((counter++))
        done
    else
        echo "No backups found in $BACKUP_DIR"
        exit 1
    fi
    echo ""
}

restore_backup() {
    local backup_file="$1"
    local backup_path="${BACKUP_DIR}/${backup_file}"

    # Verify backup file exists
    if [[ ! -f "$backup_path" ]]; then
        error_exit "Backup file not found: $backup_path"
    fi

    log "Starting restore from: $backup_file"

    # Create temporary directory for extraction
    local temp_dir="${BACKUP_DIR}/restore_temp_$(date '+%Y%m%d_%H%M%S')"
    mkdir -p "$temp_dir"

    # Extract backup
    log "Extracting backup..."
    cd "$BACKUP_DIR"
    tar -xzf "$backup_file" -C "$temp_dir"

    # Show backup info if available
    if [[ -f "$temp_dir/backup_info.txt" ]]; then
        echo ""
        echo "Backup Information:"
        echo "==================="
        cat "$temp_dir/backup_info.txt"
        echo ""
    fi

    # Confirm restore
    echo "This will REPLACE your current production site with the backup."
    echo "Current production path: $PROD_PATH"
    echo "Are you sure you want to continue? (y/N)"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log "Restore cancelled by user"
        rm -rf "$temp_dir"
        exit 0
    fi

    # Backup current wp-config.php
    if [[ -f "$PROD_PATH/wp-config.php" ]]; then
        cp "$PROD_PATH/wp-config.php" "${BACKUP_DIR}/wp-config.php.pre-restore"
        log "Current wp-config.php backed up"
    fi

    # Restore files
    if [[ -d "$temp_dir/files" ]]; then
        log "Restoring files..."
        rsync -av --delete "$temp_dir/files/" "$PROD_PATH/"

        # Restore the current wp-config.php
        if [[ -f "${BACKUP_DIR}/wp-config.php.pre-restore" ]]; then
            cp "${BACKUP_DIR}/wp-config.php.pre-restore" "$PROD_PATH/wp-config.php"
            log "wp-config.php restored to current version"
        fi
    fi

    # Restore database
    if [[ -f "$temp_dir/database.sql" ]]; then
        log "Restoring database..."
        cd "$PROD_PATH"

        log "Dropping existing database tables..."
        wp db reset --yes --allow-root

        log "Importing backup data..."
        wp db import "$temp_dir/database.sql" --allow-root
        log "Database restored successfully"
    fi

    # Set proper permissions
    log "Setting file permissions..."
    find "$PROD_PATH" -type f -exec chmod 644 {} \;
    find "$PROD_PATH" -type d -exec chmod 755 {} \;
    chmod 600 "$PROD_PATH/wp-config.php"

    # Flush caches
    log "Flushing caches..."
    cd "$PROD_PATH"

    # Try to flush caches, but don't fail if WP-CLI has connection issues
    if wp core is-installed --allow-root &>/dev/null; then
        wp rewrite flush --allow-root 2>/dev/null || log "Could not flush rewrite rules"
        wp cache flush --allow-root 2>/dev/null || log "Object cache flush not available"
        log "WordPress caches flushed"
    else
        log "Warning: Could not connect to WordPress for cache flushing. You may need to flush caches manually."
    fi

    # Clean up
    rm -rf "$temp_dir"

    log "Restore completed successfully!"
    echo ""
    echo "Please verify your site is working correctly:"
    echo "1. Visit your production site"
    echo "2. Test critical functionality"
    echo "3. Check database connections"
    echo ""
}

# =============================================================================
# MAIN FUNCTION
# =============================================================================

main() {
    echo "WordPress Backup Restore Script"
    echo "==============================="
    echo ""

    # Check if backup directory exists
    if [[ ! -d "$BACKUP_DIR" ]]; then
        error_exit "Backup directory not found: $BACKUP_DIR"
    fi

    # List available backups
    list_backups

    # Get backup selection from user
    echo "Enter the backup number to restore (or 'q' to quit):"
    read -r backup_choice

    if [[ "$backup_choice" == "q" || "$backup_choice" == "Q" ]]; then
        echo "Restore cancelled."
        # Clean up temp file
        rm -f "${BACKUP_DIR}/.backup_list_temp"
        exit 0
    fi

    # Validate selection is a number
    if [[ ! "$backup_choice" =~ ^[0-9]+$ ]]; then
        error_exit "Please enter a valid backup number"
    fi

    # Read backup files from temporary file into array
    local backup_files=()
    while IFS= read -r line; do
        backup_files+=("$line")
    done < "${BACKUP_DIR}/.backup_list_temp"

    # Validate backup number is within range
    if [[ "$backup_choice" -lt 1 || "$backup_choice" -gt "${#backup_files[@]}" ]]; then
        error_exit "Backup number out of range. Please select a number between 1 and ${#backup_files[@]}"
    fi

    # Get selected backup filename
    local selected_backup="${backup_files[$((backup_choice - 1))]}"

    # Clean up temp file
    rm -f "${BACKUP_DIR}/.backup_list_temp"

    # Perform restore
    restore_backup "$selected_backup"
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

# Trap to handle script interruption
trap 'log "Restore interrupted. Check for partial restoration."; exit 1' INT TERM

# Run main function
main "$@"
