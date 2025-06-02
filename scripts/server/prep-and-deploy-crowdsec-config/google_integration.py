# google_integration.py

"""
Functions for integrating with Google services (Docs and Sheets).
"""

import os
import datetime
import socket # For hostname
import difflib # For creating diff text for Google Docs
from typing import List

# Google API client libraries
import gspread
from oauth2client.service_account import ServiceAccountCredentials
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError as GoogleHttpError # Alias to avoid conflict

from logger_setup import logger
# from config import DEFAULT_GOOGLE_CREDENTIALS_FILE, DEFAULT_SPREADSHEET_ID, DEFAULT_SHEET_NAME # Avoid direct config import

# ================================
# GOOGLE DOCS FUNCTIONS
# ================================

def create_google_doc_with_content(
    credentials_file: str,
    doc_title: str,
    doc_content: str,
    share_as_reader: bool = True
) -> str:
    """
    Creates a new Google Doc with the given title and content.
    Returns the URL of the created document, or an empty string on failure.
    """
    if not credentials_file or not os.path.exists(credentials_file):
        logger.error(f"Google credentials file '{credentials_file}' not provided or not found. Cannot create Google Doc.")
        return ""
    if not doc_title:
        logger.error("Document title cannot be empty for creating Google Doc.")
        return ""

    logger.info(f"Attempting to create Google Doc titled: '{doc_title}'")
    try:
        scope = ['https://www.googleapis.com/auth/documents', 'https://www.googleapis.com/auth/drive']
        creds = ServiceAccountCredentials.from_json_keyfile_name(credentials_file, scope)

        docs_service = build('docs', 'v1', credentials=creds)
        drive_service = build('drive', 'v3', credentials=creds) # For permissions

        # 1. Create the document
        document_body = {'title': doc_title}
        doc = docs_service.documents().create(body=document_body).execute()
        doc_id = doc.get('documentId')
        doc_url = f"https://docs.google.com/document/d/{doc_id}/edit" # Standard edit URL
        logger.info(f"Google Doc created with ID: {doc_id}, URL: {doc_url}")

        # 2. Insert content (if any)
        if doc_content:
            requests = [
                {
                    'insertText': {
                        'location': {'index': 1}, # Start at the beginning of the document
                        'text': doc_content
                    }
                }
            ]
            docs_service.documents().batchUpdate(
                documentId=doc_id,
                body={'requests': requests}
            ).execute()
            logger.info(f"Content inserted into Google Doc '{doc_title}'.")
        else:
            logger.info(f"No content provided for Google Doc '{doc_title}'. Document created empty.")

        # 3. Set sharing permissions (optional)
        if share_as_reader:
            permission_body = {'role': 'reader', 'type': 'anyone'}
            drive_service.permissions().create(
                fileId=doc_id,
                body=permission_body,
                fields='id' # Request only id to confirm creation
            ).execute()
            logger.info(f"Google Doc '{doc_title}' made publicly readable (anyone with the link).")

        return doc_url

    except GoogleHttpError as ghe:
        logger.error(f"Google API HTTP Error creating/updating Google Doc '{doc_title}': {ghe}")
        if ghe.resp.status == 403:
             logger.error("Ensure the Google Service Account has permissions for Google Docs API and Google Drive API (for sharing).")
        return ""
    except Exception as e:
        logger.error(f"Unexpected error creating Google Doc '{doc_title}': {e}")
        return ""

def format_config_diff_for_doc(current_config_filepath: str, pending_config_filepath: str) -> str:
    """
    Reads two configuration files and formats their differences using difflib
    for display in a Google Doc or plain text.
    """
    logger.debug(f"Formatting diff between '{current_config_filepath}' and '{pending_config_filepath}' for document.")
    try:
        with open(current_config_filepath, 'r', encoding='utf-8') as f_current:
            current_lines = f_current.readlines()
    except FileNotFoundError:
        logger.error(f"Current config file '{current_config_filepath}' not found for diff formatting.")
        return f"Error: File '{current_config_filepath}' not found.\n"
    except Exception as e:
        logger.error(f"Error reading current config file '{current_config_filepath}': {e}")
        return f"Error reading '{current_config_filepath}': {e}\n"

    try:
        with open(pending_config_filepath, 'r', encoding='utf-8') as f_pending:
            pending_lines = f_pending.readlines()
    except FileNotFoundError:
        logger.error(f"Pending config file '{pending_config_filepath}' not found for diff formatting.")
        return f"Error: File '{pending_config_filepath}' not found.\n"
    except Exception as e:
        logger.error(f"Error reading pending config file '{pending_config_filepath}': {e}")
        return f"Error reading '{pending_config_filepath}': {e}\n"

    # Generate the diff
    diff_generator = difflib.unified_diff(
        current_lines,
        pending_lines,
        fromfile=f"Current: {os.path.basename(current_config_filepath)}",
        tofile=f"Pending: {os.path.basename(pending_config_filepath)}",
        lineterm='' # Avoid extra newlines in diff output
    )

    # Construct the document content
    content_header = (
        f"Configuration Difference Report\n"
        f"================================\n"
        f"Generated: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')}\n"
        f"Hostname: {socket.gethostname()}\n"
        f"Current Configuration File: {os.path.abspath(current_config_filepath)}\n"
        f"Pending Configuration File: {os.path.abspath(pending_config_filepath)}\n"
        f"--------------------------------\n\n"
        f"Diff Legend:\n"
        f"  --- Current: ... (lines from current file)\n"
        f"  +++ Pending: ... (lines from pending file)\n"
        f"  - <line> : Line removed from Current\n"
        f"  + <line> : Line added to Pending\n"
        f"    <line> : Line unchanged (context)\n"
        f"  @@ ... @@ : Section header indicating line numbers and counts\n\n"
        f"--------------------------------\n\n"
    )

    diff_text_lines = list(diff_generator)
    if not diff_text_lines:
        diff_content = "No textual differences found between the files.\n"
    else:
        diff_content = "\n".join(diff_text_lines)

    logger.info(f"Diff content formatted for document. Found {len(diff_text_lines)} lines of diff output.")
    return content_header + diff_content

# ================================
# GOOGLE SHEETS FUNCTIONS
# ================================

def update_google_sheet_with_diff_log(
    spreadsheet_id: str,
    sheet_name: str, # Target worksheet name
    credentials_file: str,
    diff_doc_url: str, # URL to the Google Doc containing the detailed diff
    hostname: str,
    dry_run: bool = False
) -> bool:
    """
    Updates a specific worksheet in a Google Spreadsheet with a log entry
    about a configuration diff, including a link to the Google Doc.
    """
    if not all([spreadsheet_id, sheet_name, credentials_file, diff_doc_url, hostname]):
        logger.error("Missing one or more required parameters for updating Google Sheet. Aborting.")
        return False

    if dry_run:
        logger.info(f"[DRY RUN] Would update Google Sheet (ID: {spreadsheet_id}, Worksheet: '{sheet_name}') "
                    f"with diff log. Doc URL: {diff_doc_url}")
        return True

    if not os.path.exists(credentials_file):
        logger.error(f"Google credentials file '{credentials_file}' not found. Cannot update Google Sheet.")
        return False

    logger.info(f"Attempting to update Google Sheet '{sheet_name}' in spreadsheet ID '{spreadsheet_id}'.")
    try:
        scope = ['https://spreadsheets.google.com/feeds', 'https://www.googleapis.com/auth/drive']
        creds = ServiceAccountCredentials.from_json_keyfile_name(credentials_file, scope)
        client = gspread.authorize(creds)
        spreadsheet = client.open_by_key(spreadsheet_id)

        try:
            sheet = spreadsheet.worksheet(sheet_name)
            logger.info(f"Found existing worksheet: '{sheet_name}'.")
        except gspread.exceptions.WorksheetNotFound:
            logger.info(f"Worksheet '{sheet_name}' not found. Creating it...")
            # Define columns for the diff log sheet
            sheet = spreadsheet.add_worksheet(title=sheet_name, rows="1000", cols=4) # Date, Hostname, Status/Action, Diff Doc URL
            header_row = ["Log Timestamp", "Hostname", "Action/Details", "Diff Document Link"]
            sheet.update('A1', [header_row], value_input_option='USER_ENTERED')
            sheet.format("A1:D1", {"textFormat": {"bold": True}})
            logger.info(f"Worksheet '{sheet_name}' created with headers.")

        # Prepare the new row data
        log_timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S UTC")
        action_details = "Configuration diff generated and deployed." # Example, can be more specific
        
        # Check if header exists, even if sheet existed (in case it was cleared)
        # This is a bit inefficient if sheet is large, better to assume header or check once.
        current_header = sheet.row_values(1) if sheet.row_count >=1 else []
        expected_header = ["Log Timestamp", "Hostname", "Action/Details", "Diff Document Link"] # Keep consistent
        if current_header != expected_header :
             logger.warning(f"Worksheet '{sheet_name}' header is missing or incorrect. Re-applying standard header.")
             sheet.update('A1', [expected_header], value_input_option='USER_ENTERED')
             sheet.format(f"A1:{chr(ord('A') + len(expected_header) -1)}1", {"textFormat": {"bold": True}})


        new_row_data = [log_timestamp, hostname, action_details, diff_doc_url]
        sheet.append_row(new_row_data, value_input_option='USER_ENTERED')

        logger.info(f"Successfully updated Google Sheet '{sheet_name}' with new diff log entry.")
        return True

    except GoogleHttpError as ghe:
        logger.error(f"Google API HTTP Error updating Google Sheet '{sheet_name}': {ghe}")
        if ghe.resp.status == 403:
             logger.error("Ensure the Google Service Account has permissions for Google Sheets API.")
        return False
    except Exception as e:
        logger.error(f"Unexpected error updating Google Sheet '{sheet_name}': {e}")
        return False

# Note: log_error_to_google_sheets is in error_handler.py to avoid circular dependencies
# as error_handler is a lower-level module.
