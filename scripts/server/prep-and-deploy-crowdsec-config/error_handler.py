# error_handler.py

"""
Error handling, custom exceptions, and transactional deployment management.
"""

import os
import shutil
import datetime
import traceback
import gspread # For Google Sheets logging
from oauth2client.service_account import ServiceAccountCredentials # For Google Sheets logging

from logger_setup import logger
# from config import DEFAULT_GOOGLE_CREDENTIALS_FILE, DEFAULT_SPREADSHEET_ID # Avoid direct config import if possible

# ================================
# CUSTOM EXCEPTIONS
# ================================

class DeploymentError(Exception):
    """Custom exception for deployment-related errors."""
    pass

# ================================
# TRANSACTION MANAGER
# ================================

class TransactionManager:
    """Manages transactional deployments with rollback capability."""

    def __init__(self, original_config_path: str, backup_path: str):
        self.original_config_path = original_config_path
        self.backup_path = backup_path # Path to the backup of original_config_path
        self.deployment_started = False
        self.rollback_performed = False # Tracks if rollback was successfully executed
        self.backup_exists_at_start = os.path.exists(self.backup_path) if self.backup_path else False


    def start_deployment(self):
        """Mark the start of deployment transaction."""
        if not self.backup_path or not os.path.exists(self.backup_path):
            # This check is crucial. If backup_config failed, we shouldn't proceed.
            raise DeploymentError(f"Cannot start deployment: Backup file '{self.backup_path}' does not exist or was not specified.")
        self.deployment_started = True
        logger.info(f"Deployment transaction started for '{self.original_config_path}'. Backup is at '{self.backup_path}'.")

    def rollback(self) -> bool:
        """Rollback to the backup configuration."""
        if not self.deployment_started:
            logger.warning("Rollback called but deployment transaction was not formally started.")
            # Decide if this should be an error or just a warning.
            # For safety, only rollback if deployment was initiated and backup is confirmed.

        if not self.backup_path or not os.path.exists(self.backup_path):
            logger.error(f"Cannot rollback: Backup file '{self.backup_path}' not available or path not set.")
            return False

        try:
            logger.info(f"Attempting to rollback '{self.original_config_path}' from backup '{self.backup_path}'...")
            shutil.copy2(self.backup_path, self.original_config_path)
            self.rollback_performed = True
            logger.info(f"Rollback successful: '{self.original_config_path}' restored from '{self.backup_path}'.")
            return True
        except Exception as e:
            logger.error(f"Rollback from '{self.backup_path}' to '{self.original_config_path}' FAILED: {e}")
            return False

    def cleanup(self):
        """
        Clean up after deployment.
        Currently, this means deciding what to do with the backup file.
        For safety, backups are usually retained.
        """
        if self.deployment_started and not self.rollback_performed:
            logger.info(f"Deployment successful for '{self.original_config_path}'.")
            if self.backup_path and os.path.exists(self.backup_path):
                logger.info(f"Backup file '{self.backup_path}' has been retained for safety.")
            # Potential future enhancement: option to remove backup on successful deployment.
        elif self.rollback_performed:
            logger.info(f"Deployment for '{self.original_config_path}' was rolled back.")
        elif not self.deployment_started:
            logger.info("Cleanup called, but no deployment transaction was started.")


# ================================
# GOOGLE SHEETS ERROR LOGGING
# ================================

def log_error_to_google_sheets(spreadsheet_id: str, credentials_file: str, error_message: str, dry_run: bool = False):
    """Log error to Google Sheets Debug Log worksheet."""
    if not spreadsheet_id or not credentials_file:
        logger.warning("Google Sheets ID or credentials file not provided. Skipping error logging to Google Sheets.")
        return

    if dry_run:
        logger.info(f"[DRY RUN] Would log error to Google Sheets (ID: {spreadsheet_id}): {error_message[:200]}...") # Log snippet
        return

    if not os.path.exists(credentials_file):
        logger.error(f"Google credentials file '{credentials_file}' not found. Cannot log error to Google Sheets.")
        return

    try:
        scope = ['https://spreadsheets.google.com/feeds', 'https://www.googleapis.com/auth/drive']
        creds = ServiceAccountCredentials.from_json_keyfile_name(credentials_file, scope)
        client = gspread.authorize(creds)
        spreadsheet = client.open_by_key(spreadsheet_id)

        debug_sheet_name = "Debug Log"
        try:
            sheet = spreadsheet.worksheet(debug_sheet_name)
        except gspread.exceptions.WorksheetNotFound:
            logger.info(f"Creating '{debug_sheet_name}' worksheet in spreadsheet '{spreadsheet_id}'...")
            # Add worksheet with more columns if needed, e.g., for hostname, script version
            sheet = spreadsheet.add_worksheet(title=debug_sheet_name, rows="1000", cols=3) # Timestamp, Hostname, Incident
            sheet.update('A1', [["Date of Incident", "Hostname", "Incident Details"]], value_input_option='USER_ENTERED')
            sheet.format("A1:C1", {"textFormat": {"bold": True}})


        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S UTC")
        # Consider adding hostname or other context if available
        # from config import DEFAULT_HOSTNAME_PART # This creates a circular dependency risk
        import socket
        hostname = socket.gethostname()

        # Truncate error message if too long for a cell
        max_len = 30000 # Google Sheets cell character limit is around 50k, be conservative
        truncated_error_message = error_message if len(error_message) <= max_len else error_message[:max_len] + "... (truncated)"

        new_row = [timestamp, hostname, truncated_error_message]
        sheet.append_row(new_row, value_input_option='USER_ENTERED')
        logger.info(f"Error successfully logged to Google Sheets '{debug_sheet_name}' in spreadsheet ID '{spreadsheet_id}'.")

    except HttpError as he:
        if he.resp.status == 403:
            logger.error(f"Failed to log error to Google Sheets: Permission denied (403). Check service account permissions for spreadsheet ID '{spreadsheet_id}' and Drive API enabled. Details: {he}")
        else:
            logger.error(f"Failed to log error to Google Sheets (HttpError): {he}")
    except Exception as e:
        logger.error(f"An unexpected error occurred while trying to log to Google Sheets: {e}\n{traceback.format_exc()}")

# ================================
# MAIN ERROR HANDLER FUNCTION
# ================================

def handle_deployment_error(
    error: Exception,
    transaction_manager: TransactionManager, # Should always be provided
    spreadsheet_id: str = "",    # Optional: For Google Sheets logging
    credentials_file: str = "", # Optional: For Google Sheets logging
    dry_run: bool = False
):
    """
    Handle deployment errors with rollback and logging.
    This function assumes `error` is an Exception instance.
    """
    # Format a detailed error message
    error_type = type(error).__name__
    error_details = str(error)
    full_traceback = traceback.format_exc()
    
    # Log to local debug.log first
    logger.error(f"--- Deployment Error Occurred ---")
    logger.error(f"Error Type: {error_type}")
    logger.error(f"Details: {error_details}")
    logger.error(f"Full Traceback:\n{full_traceback}")
    logger.error(f"--- End of Deployment Error ---")

    # Attempt to log to Google Sheets if configured
    if spreadsheet_id and credentials_file:
        # Construct a comprehensive message for Google Sheets
        # (may be slightly different from local log for brevity or specific formatting)
        sheets_error_message = (
            f"Deployment Error Encountered:\n"
            f"Type: {error_type}\n"
            f"Message: {error_details}\n"
            f"File: {transaction_manager.original_config_path if transaction_manager else 'N/A'}\n"
            f"Traceback (summary):\n{full_traceback.splitlines()[-3:]}" # Last few lines of traceback
        )
        log_error_to_google_sheets(spreadsheet_id, credentials_file, sheets_error_message, dry_run)
    else:
        logger.info("Google Sheets logging for errors is not configured (ID or creds file missing).")

    # Perform rollback using the transaction manager
    if transaction_manager:
        if transaction_manager.deployment_started: # Only if deployment was formally started
            logger.info("Attempting rollback due to deployment error...")
            if transaction_manager.rollback(): # rollback() logs its own success/failure
                logger.info("Rollback procedure completed. System may be restored to pre-deployment state.")
                # Further actions like restarting services with the rolled-back config might be needed here or by the caller.
            else:
                logger.critical(f"CRITICAL: Rollback FAILED for '{transaction_manager.original_config_path}'. Manual intervention is URGENTLY required.")
        else:
            logger.warning("Deployment error occurred, but transaction manager indicates deployment was not formally started. Skipping rollback.")
    else:
        logger.error("No transaction manager provided to handle_deployment_error. Cannot perform automated rollback.")
