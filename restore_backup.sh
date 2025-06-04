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

clear_production_cache() {
    log "Clearing all production cache files and directories..."

    cd "$PROD_PATH"

    # 1. Clear common cache directories
    local cache_dirs=(
        "wp-content/cache"
        "wp-content/uploads/cache"
        "wp-content/w3tc-config"
        "wp-content/wp-rocket-config"
        "wp-content/litespeed"
        "wp-content/et-cache"
        "wp-content/autoptimize"
        "wp-content/wp-fastest-cache"
        "wp-content/wp-super-cache"
        "wp-content/breeze"
        "wp-content/swift-performance"
        "wp-content/hummingbird-assets"
        "wp-content/sg-cachepress"
        "wp-content/endurance-page-cache"
        "wp-content/object-cache"
        "wp-content/db-cache"
        "wp-content/advanced-cache"
    )

    local dirs_removed=0
    for cache_dir in "${cache_dirs[@]}"; do
        if [[ -d "$cache_dir" ]]; then
            rm -rf "$cache_dir" 2>/dev/null && dirs_removed=$((dirs_removed + 1))
        fi
    done

    # 2. Clear common cache files
    local cache_files=(
        "wp-content/advanced-cache.php"
        "wp-content/object-cache.php"
        "wp-content/db-cache.php"
        "wp-content/wp-cache-config.php"
        ".htaccess.bak"
        "wp-content/.htaccess.bak"
    )

    local files_removed=0
    for cache_file in "${cache_files[@]}"; do
        if [[ -f "$cache_file" ]]; then
            rm -f "$cache_file" 2>/dev/null && files_removed=$((files_removed + 1))
        fi
    done

    # 3. Clear any .cache files and directories recursively
    find . -name "*.cache" -type f -delete 2>/dev/null || true
    find . -name ".cache" -type d -exec rm -rf {} + 2>/dev/null || true

    # 4. Clear temporary files that might be cache-related
    find wp-content -name "*.tmp" -type f -delete 2>/dev/null || true
    find wp-content -name "*.temp" -type f -delete 2>/dev/null || true

    # 5. Clear any minified/optimized files that might be stale
    find wp-content -name "*.min.css.gz" -type f -delete 2>/dev/null || true
    find wp-content -name "*.min.js.gz" -type f -delete 2>/dev/null || true

    if [[ $dirs_removed -gt 0 || $files_removed -gt 0 ]]; then
        log "✓ Cache cleanup completed ($dirs_removed directories, $files_removed files removed)"
    else
        log "✓ Cache cleanup completed (no cache files found)"
    fi
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
        log "✓ Current wp-config.php backed up"
    fi

    # Restore files
    if [[ -d "$temp_dir/files" ]]; then
        log "Restoring files..."

        # Optimized rsync command for restore operations
        if rsync \
            --archive \
            --compress \
            --progress \
            --human-readable \
            --checksum \
            --delete \
            --delete-excluded \
            --exclude='wp-config.php' \
            "$temp_dir/files/" "$PROD_PATH/"; then

            log "✓ File restore completed successfully"
        else
            error_exit "File restore failed"
        fi

        # Restore the current wp-config.php
        if [[ -f "${BACKUP_DIR}/wp-config.php.pre-restore" ]]; then
            cp "${BACKUP_DIR}/wp-config.php.pre-restore" "$PROD_PATH/wp-config.php"
            log "✓ wp-config.php restored to current version"
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
        log "✓ Database restored successfully"
    fi

    # Set proper permissions (optimized for speed)
    log "Setting file permissions..."

    # Method 1: Use find with + operator (much faster than -exec {} \;)
    # This batches multiple files into single chmod commands
    if command -v xargs &> /dev/null; then
        # Use xargs for maximum efficiency (processes files in batches)
        find "$PROD_PATH" -type d -print0 | xargs -0 -P 4 chmod 755 2>/dev/null || {
            find "$PROD_PATH" -type d -exec chmod 755 {} + 2>/dev/null
        }

        find "$PROD_PATH" -type f -print0 | xargs -0 -P 4 chmod 644 2>/dev/null || {
            find "$PROD_PATH" -type f -exec chmod 644 {} + 2>/dev/null
        }
    else
        # Fallback: Use find with + operator (still much faster than {} \;)
        find "$PROD_PATH" -type d -exec chmod 755 {} +
        find "$PROD_PATH" -type f -exec chmod 644 {} +
    fi

    # Set specific permissions for sensitive files
    chmod 644 "$PROD_PATH/wp-config.php" 2>/dev/null || log "WARNING: Could not set wp-config.php permissions"

    # Set permissions for .htaccess if it exists (Apache only)
    if [[ -f "$PROD_PATH/.htaccess" ]]; then
        chmod 644 "$PROD_PATH/.htaccess" 2>/dev/null || log "WARNING: Could not set .htaccess permissions"
        log "INFO: Found .htaccess file (Apache configuration)"
    else
        log "INFO: No .htaccess file found (likely using Nginx)"
    fi

    # Set special permissions for WordPress uploads directory (needs to be writable)
    if [[ -d "$PROD_PATH/wp-content/uploads" ]]; then
        log "Setting uploads directory permissions..."
        chmod 755 "$PROD_PATH/wp-content/uploads" 2>/dev/null || log "WARNING: Could not set uploads directory permissions"
        # Some hosting environments need 775 for uploads - uncomment if needed:
        # chmod 775 "$PROD_PATH/wp-content/uploads" 2>/dev/null || log "WARNING: Could not set uploads directory permissions"

        # Ensure all subdirectories in uploads are accessible
        find "$PROD_PATH/wp-content/uploads" -type d -exec chmod 755 {} + 2>/dev/null || true
        log "✓ Uploads directory permissions set"
    fi

    # Ensure backup directory has proper permissions
    if [[ -d "$BACKUP_DIR" ]]; then
        chmod 755 "$BACKUP_DIR" 2>/dev/null || log "WARNING: Could not set backup directory permissions"
    fi

    log "✓ File permissions set"

    # Clear production cache (before WordPress cache flush)
    clear_production_cache

    # Flush caches
    log "Flushing caches..."
    cd "$PROD_PATH"

    # Try to flush caches, but don't fail if WP-CLI has connection issues
    if wp core is-installed --allow-root &>/dev/null; then
        wp rewrite flush --allow-root 2>/dev/null && log "✓ Rewrite rules flushed"
        wp cache flush --allow-root 2>/dev/null && log "✓ Object cache flushed"
    else
        log "INFO: WP-CLI connectivity unavailable, skipping cache flush"
    fi

    # Clean up
    rm -rf "$temp_dir"

    log "✓ Restore completed successfully!"
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
