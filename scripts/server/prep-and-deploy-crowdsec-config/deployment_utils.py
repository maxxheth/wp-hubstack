# deployment_utils.py

"""
Functions for diffing YAML configurations and deploying them.
Includes backup and transactional deployment logic.
"""

import os
import shutil
import datetime
import socket # For hostname in diff metadata
from typing import Dict, Any

from logger_setup import logger
from utils import load_yaml_file, save_yaml_file
from error_handler import DeploymentError, TransactionManager, handle_deployment_error # For error handling during deploy

# ================================
# YAML DIFFING FUNCTIONS
# ================================

def _deep_diff_yaml_recursive(current: Any, pending: Any, path: str) -> Dict[str, Any]:
    """
    Recursive helper for deep_diff_yaml.
    Handles any type of data, not just dicts at the top level.
    """
    diff_result = {
        'added': {},
        'removed': {},
        'modified': {},
        # 'unchanged': {} # Typically not included in diff outputs unless verbose
    }

    if type(current) != type(pending) and not (isinstance(current, (dict, list)) and isinstance(pending, (dict, list))):
        # If types are different and they are not both collections (which might be structurally similar)
        # Consider it a modification of the whole element at 'path'
        if path: # Avoid empty path for top-level change
            diff_result['modified'][path] = {'from': current, 'to': pending}
        return diff_result
    
    if isinstance(current, dict) and isinstance(pending, dict):
        all_keys = set(current.keys()) | set(pending.keys())
        for key in all_keys:
            current_path = f"{path}.{key}" if path else str(key)
            res = _deep_diff_yaml_recursive(current.get(key), pending.get(key), current_path)
            for diff_type in ['added', 'removed', 'modified']:
                diff_result[diff_type].update(res[diff_type])
        
    elif isinstance(current, list) and isinstance(pending, list):
        # Simple list diff: if they are not identical, mark as modified.
        # For a more detailed list diff (item by item), a more complex algorithm is needed (e.g., LCS).
        # For config files, often the order matters, or entire lists are replaced.
        if current != pending:
            if path: # Avoid empty path for top-level change
                 diff_result['modified'][path] = {'from': current, 'to': pending}
        # Else, lists are identical, no diff entry.

    elif current != pending: # Primitives or other non-collection types that differ
        if path: # Avoid empty path for top-level change
            diff_result['modified'][path] = {'from': current, 'to': pending}
            
    # Handling elements only in current (removed) or only in pending (added)
    # This is implicitly handled for dicts by iterating all_keys.
    # For top-level non-dict/list comparison, it's covered by current != pending.
    # If current is None (path was in pending but not current)
    if current is None and pending is not None and path:
        diff_result['added'][path] = pending
    # If pending is None (path was in current but not pending)
    elif pending is None and current is not None and path:
        diff_result['removed'][path] = current
        
    return diff_result


def deep_diff_yaml(current_config: Dict[Any, Any], pending_config: Dict[Any, Any]) -> Dict[str, Any]:
    """
    Create a deep diff between two YAML structures (dictionaries).
    Returns a dictionary categorizing differences into 'added', 'removed', 'modified'.
    """
    logger.debug("Starting deep diff between current and pending configurations.")
    
    # Initial call to the recursive helper with an empty path for the root.
    # The recursive function expects path to be set for its items.
    # We need to iterate through the top-level keys here.
    
    diff_summary = {
        'added': {},
        'removed': {},
        'modified': {}
    }
    
    all_top_level_keys = set(current_config.keys()) | set(pending_config.keys())

    for key in all_top_level_keys:
        path = str(key)
        current_val = current_config.get(key)
        pending_val = pending_config.get(key)

        if key not in current_config: # Key added in pending
            diff_summary['added'][path] = pending_val
        elif key not in pending_config: # Key removed from current
            diff_summary['removed'][path] = current_val
        elif current_val != pending_val: # Key exists in both, but values differ
            if isinstance(current_val, dict) and isinstance(pending_val, dict):
                nested_diff = _deep_diff_yaml_recursive(current_val, pending_val, path)
                for diff_type in ['added', 'removed', 'modified']:
                    diff_summary[diff_type].update(nested_diff[diff_type])
            elif isinstance(current_val, list) and isinstance(pending_val, list):
                 # For lists, if they are different, mark the whole list as modified at this path
                 # More granular list diffing (item add/remove/change) is complex and
                 # might not be what's typically desired for config diffs unless specified.
                 diff_summary['modified'][path] = {'from': current_val, 'to': pending_val}
            else: # Primitive types or mismatched complex types
                diff_summary['modified'][path] = {'from': current_val, 'to': pending_val}
        # If key in both and values are equal, it's unchanged, no entry in diff.

    logger.debug(f"Deep diff calculated. Added: {len(diff_summary['added'])}, Removed: {len(diff_summary['removed'])}, Modified: {len(diff_summary['modified'])}")
    return diff_summary


def create_diff_report_yaml(current_file: str, pending_file: str, output_file: str = "config_diff_report.yml") -> Dict[str, Any]:
    """
    Compares two YAML configuration files and saves a report of the differences to a YAML file.
    The report includes metadata and the structured diff.
    """
    logger.info(f"Creating diff report between '{current_file}' and '{pending_file}'. Output to '{output_file}'.")

    current_config = load_yaml_file(current_file)
    pending_config = load_yaml_file(pending_file)

    if not current_config and not os.path.exists(current_file):
        logger.error(f"Current configuration file '{current_file}' not found or is empty/invalid. Cannot create diff.")
        return {}
    if not pending_config and not os.path.exists(pending_file):
        logger.error(f"Pending configuration file '{pending_file}' not found or is empty/invalid. Cannot create diff.")
        return {}
    # If files exist but are empty/invalid, load_yaml_file returns {}, which is fine for diffing.

    diff_results = deep_diff_yaml(current_config, pending_config)

    report_data = {
        'metadata': {
            'current_config_file': os.path.abspath(current_file),
            'pending_config_file': os.path.abspath(pending_file),
            'report_generated_at': datetime.datetime.now().isoformat(),
            'generated_on_host': socket.gethostname(),
            'summary': {
                'added_items': len(diff_results.get('added', {})),
                'removed_items': len(diff_results.get('removed', {})),
                'modified_items': len(diff_results.get('modified', {}))
            }
        },
        'differences': diff_results
    }

    if save_yaml_file(report_data, output_file):
        logger.info(f"Configuration diff report saved successfully to '{output_file}'.")
        return report_data
    else:
        logger.error(f"Failed to save configuration diff report to '{output_file}'.")
        return {}

# ================================
# CONFIGURATION BACKUP
# ================================

def backup_config_file(config_path: str, dry_run: bool = False) -> str:
    """
    Create a timestamped backup of the specified configuration file.
    Returns the path to the backup file, or an empty string on failure.
    """
    if not os.path.exists(config_path):
        logger.error(f"Cannot backup: Configuration file '{config_path}' does not exist.")
        return ""

    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    # Place backup in the same directory as the config file
    backup_dir = os.path.dirname(config_path)
    backup_filename = f"{os.path.basename(config_path)}.backup_{timestamp}"
    backup_path = os.path.join(backup_dir, backup_filename)


    if dry_run:
        logger.info(f"[DRY RUN] Would create backup of '{config_path}' to '{backup_path}'.")
        return backup_path # Return hypothetical path for dry run consistency

    try:
        shutil.copy2(config_path, backup_path)
        logger.info(f"Successfully created backup of '{config_path}' at '{backup_path}'.")
        return backup_path
    except Exception as e:
        logger.error(f"Error creating backup for '{config_path}': {e}")
        return ""

# ================================
# CONFIGURATION DEPLOYMENT
# ================================

def deploy_new_config(
    current_config_path: str, # The file to be replaced (e.g., docker-compose.yml)
    new_config_path: str,     # The file containing the new configuration (e.g., docker-compose-pending.yml)
    skip_backup: bool = False,
    dry_run: bool = False,
    # For error logging to Google Sheets, passed to handle_deployment_error
    spreadsheet_id: str = "",
    credentials_file: str = ""
) -> bool:
    """
    Deploy a new configuration by replacing the current one, with transactional rollback capability.
    1. Validates input paths.
    2. Creates a backup of `current_config_path` (unless skipped).
    3. Initializes a TransactionManager.
    4. Copies `new_config_path` to `current_config_path`.
    5. Handles errors by attempting rollback via TransactionManager.
    """
    logger.info(f"Preparing to deploy new configuration from '{new_config_path}' to '{current_config_path}'.")

    if not os.path.exists(new_config_path):
        logger.error(f"Deployment failed: New configuration file '{new_config_path}' not found.")
        # Log to Google Sheets if error occurs before transaction_manager is setup
        if spreadsheet_id and credentials_file:
            from error_handler import log_error_to_google_sheets # Local import to avoid cycle if this was in error_handler
            log_error_to_google_sheets(spreadsheet_id, credentials_file, f"Deployment failed: New config '{new_config_path}' not found.", dry_run)
        return False

    # current_config_path might not exist if it's a first-time deployment, which is acceptable.
    # Backup logic will handle non-existent current_config_path.

    if dry_run:
        logger.info(f"[DRY RUN] Would deploy config from '{new_config_path}' to '{current_config_path}'.")
        if not skip_backup and os.path.exists(current_config_path):
            logger.info(f"[DRY RUN] A backup of '{current_config_path}' would be created.")
        elif skip_backup:
            logger.info("[DRY RUN] Backup creation would be skipped (--skip-backup).")
        else: # current_config_path doesn't exist
             logger.info(f"[DRY RUN] Current config '{current_config_path}' does not exist, no backup needed.")
        return True # Dry run successful simulation

    # --- Start Actual Deployment ---
    backup_file_path = ""
    if not skip_backup:
        if os.path.exists(current_config_path):
            logger.info(f"Creating backup of current configuration '{current_config_path}'...")
            backup_file_path = backup_config_file(current_config_path, dry_run=False) # Actual backup
            if not backup_file_path:
                # backup_config_file logs its own error.
                # This is a critical failure before deployment can safely proceed.
                # Log to Google Sheets if configured
                if spreadsheet_id and credentials_file:
                     from error_handler import log_error_to_google_sheets
                     log_error_to_google_sheets(spreadsheet_id, credentials_file, f"Deployment failed: Backup of '{current_config_path}' failed.", dry_run)
                return False
        else:
            logger.info(f"Current configuration '{current_config_path}' does not exist. No backup will be created.")
            # backup_file_path remains empty, TransactionManager will know no backup was made for rollback.
    else:
        logger.warning(f"Backup of '{current_config_path}' SKIPPED as per --skip-backup flag.")


    # Initialize TransactionManager. It needs the original path and the path to its backup.
    # If no backup was made (e.g. skip_backup or original file didn't exist), backup_file_path will be empty.
    transaction_manager = TransactionManager(original_config_path=current_config_path, backup_path=backup_file_path)

    try:
        # Start the transaction. This will fail if backup_file_path is needed but missing.
        # If backup_file_path is empty because original didn't exist or was skipped, start_deployment should handle it.
        # Modifying TransactionManager: it should only require backup_path if a rollback is possible/expected.
        # For now, if backup_file_path is empty, TransactionManager.start_deployment might need adjustment or
        # we ensure it's only called if backup_file_path is valid.
        # Let's assume TransactionManager can handle an empty backup_path (meaning no rollback possible).
        if backup_file_path: # Only start transaction if a backup exists for rollback
             transaction_manager.start_deployment()
        else:
             logger.info("Proceeding with deployment without a formal backup for rollback (either skipped or original did not exist).")


        logger.info(f"Deploying by copying '{new_config_path}' to '{current_config_path}'...")
        shutil.copy2(new_config_path, current_config_path)
        logger.info(f"Successfully deployed '{new_config_path}' to '{current_config_path}'.")

        if backup_file_path: # If a backup was made and transaction started
            transaction_manager.cleanup() # Logs retention of backup
        return True

    except Exception as e:
        # Catch any exception during the copy or transaction management.
        # The handle_deployment_error function will use the transaction_manager to attempt rollback.
        logger.error(f"An error occurred during the deployment of '{new_config_path}'.")
        handle_deployment_error(
            e,
            transaction_manager, # Pass the manager instance
            spreadsheet_id=spreadsheet_id,
            credentials_file=credentials_file,
            dry_run=False # This is not a dry run at this point
        )
        return False
