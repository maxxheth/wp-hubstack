#!/usr/bin/env python3

import os
import subprocess
import gspread
from oauth2client.service_account import ServiceAccountCredentials
import datetime
import argparse
import sys # For sys.exit()
import socket # For getting hostname
import re # For sanitizing sheet name

# --- Default Configuration ---
# These can be overridden by command-line arguments
DEFAULT_PARENT_DIRECTORY = '/var/opt'
DEFAULT_GOOGLE_CREDENTIALS_FILE = 'path/to/your/google-credentials.json'
DEFAULT_SPREADSHEET_ID = 'YOUR_SPREADSHEET_ID'

def sanitize_sheet_name(name):
    """
    Sanitizes a string to be a valid Google Sheet name.
    - Removes invalid characters: []*/\?:
    - Replaces spaces and periods with underscores.
    - Truncates to a maximum of 99 characters.
    """
    if not isinstance(name, str):
        name = str(name)
    # Remove invalid characters often found in hostnames or paths
    name = re.sub(r'[\[\]*/\\?:]', '', name)
    # Replace spaces, periods, and hyphens (often in hostnames) with underscores
    name = name.replace(' ', '_').replace('.', '_').replace('-', '_')
    # Remove any leading/trailing underscores that might result
    name = name.strip('_')
    # Ensure name is not empty after sanitization
    if not name:
        return "DefaultSheet"
    # Truncate to Google Sheets limit (100 chars, be safe with 99)
    return name[:99]

try:
    raw_hostname = socket.gethostname()
    sanitized_hostname = sanitize_sheet_name(raw_hostname)
    # Ensure the hostname part is not empty after sanitization
    DEFAULT_HOSTNAME_PART = sanitized_hostname if sanitized_hostname else "UnknownServer"
except Exception:
    DEFAULT_HOSTNAME_PART = "UnknownServer"

DEFAULT_SHEET_NAME = f'{DEFAULT_HOSTNAME_PART}_WP_URLs'
# Final check for the default sheet name's validity
if not DEFAULT_SHEET_NAME.strip() or len(DEFAULT_SHEET_NAME) > 99:
    DEFAULT_SHEET_NAME = "Default_Server_WP_URLs" # A very safe fallback

# --- End Default Configuration ---

def find_wp_sites(parent_dir):
    """
    Finds potential WordPress site directories based on '.com' in their name.
    Assumes directory name is the Docker container name.
    """
    sites = []
    if not os.path.isdir(parent_dir):
        print(f"Error: Parent directory '{parent_dir}' not found.")
        return sites

    for item in os.listdir(parent_dir):
        item_path = os.path.join(parent_dir, item)
        if os.path.isdir(item_path) and '.com' in item:
            sites.append(item)
    return sites

def get_wp_home_url(container_name, dry_run=False):
    """
    Uses 'docker exec' to run 'wp option get home' in the specified container.
    Returns the URL or None if an error occurs.
    If dry_run is True, it will only print the command.
    """
    command = ['docker', 'exec', container_name, 'wp', 'option', 'get', 'home', '--skip-plugins', '--skip-themes']
    # print(f"Attempting to execute: {' '.join(command)}") # Reduced verbosity, shown in main loop

    if dry_run:
        print(f"[DRY RUN] Would execute: {' '.join(command)}")
        return f"http://{container_name}.example.com (dry run placeholder)"

    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        url = result.stdout.strip()
        if not url.startswith('http://') and not url.startswith('https://'):
            print(f"Warning: Extracted value for {container_name} ('{url}') doesn't look like a URL. Skipping.")
            return None
        return url
    except subprocess.CalledProcessError as e:
        print(f"Error executing 'wp option get home' for container '{container_name}':")
        print(f"Command: {' '.join(e.cmd)}")
        print(f"Return code: {e.returncode}")
        print(f"Stderr: {e.stderr.strip()}")
        print(f"Stdout: {e.stdout.strip()}")
        return None
    except FileNotFoundError:
        print("Error: 'docker' command not found. Is Docker installed and in your PATH?")
        return None
    except Exception as e:
        print(f"An unexpected error occurred while getting URL for {container_name}: {e}")
        return None

def check_gsheet_access(spreadsheet_id, sheet_name, credentials_file):
    """
    Tests access to Google Sheets using the provided credentials.
    Returns True if successful, False otherwise.
    """
    print("\n--- Checking Google Sheets Access ---")
    if not os.path.exists(credentials_file):
        print(f"Error: Google credentials file '{credentials_file}' not found.")
        return False
    
    print(f"Attempting to authenticate with Google Sheets using: {credentials_file}")
    try:
        scope = ['https://spreadsheets.google.com/feeds', 'https://www.googleapis.com/auth/drive']
        creds = ServiceAccountCredentials.from_json_keyfile_name(credentials_file, scope)
        client = gspread.authorize(creds)
        print("Authentication successful.")

        print(f"Attempting to open spreadsheet ID: {spreadsheet_id}")
        spreadsheet = client.open_by_key(spreadsheet_id)
        print(f"Successfully opened spreadsheet: '{spreadsheet.title}'")

        print(f"Attempting to access or check for sheet: '{sheet_name}'")
        try:
            sheet = spreadsheet.worksheet(sheet_name)
            print(f"Successfully accessed existing sheet: '{sheet.title}'.")
        except gspread.exceptions.WorksheetNotFound:
            print(f"Sheet '{sheet_name}' not found. This is okay; script would attempt to create it.")
            # To fully test creation permission, one might try a real add_worksheet and then delete.
            # For this check, confirming no API error on worksheet() or WorksheetNotFound is sufficient.
            print("Service account likely has permission to list/check for worksheets.")


        print("Google Sheets access test successful. The JSON key appears to have the necessary permissions to read and potentially write/create sheets.")
        print("--- End of Google Sheets Access Check ---")
        return True

    except FileNotFoundError: 
        print(f"Error: Google credentials file '{credentials_file}' not found during gspread operation.")
        return False
    except gspread.exceptions.APIError as e:
        print(f"Google Sheets API Error during access check: {e}")
        print("This could be due to: incorrect Spreadsheet ID, service account not having 'Editor' (or sufficient) permissions on the Sheet, Google Sheets/Drive API not enabled in your Google Cloud project, or quota limits.")
        return False
    except Exception as e:
        print(f"An unexpected error occurred during Google Sheets access check: {e}")
        return False


def update_google_sheet(spreadsheet_id, sheet_name, credentials_file, data_rows, dry_run=False):
    """
    Appends data to the specified Google Sheet.
    Each item in data_rows should be a list representing a row.
    If dry_run is True, it will only print what it would do.
    """
    if not data_rows:
        print("No data to update in Google Sheet.")
        return True

    # Sanitize sheet_name again just before use, in case it came from user input directly
    # and bypassed the default sanitization (though argparse default should handle it).
    # However, args.sheet_name would be the direct input.
    # The DEFAULT_SHEET_NAME is already sanitized. If user provides --sheet-name, that value is used.
    # It's better to sanitize the user-provided args.sheet_name in main().
    # For now, assume sheet_name passed here is intended.

    if dry_run:
        print(f"[DRY RUN] Would authenticate with Google Sheets using {credentials_file}.")
        print(f"[DRY RUN] Would open spreadsheet ID: {spreadsheet_id} and access/create sheet: '{sheet_name}'.")
        header = ["Site Container Name", "Home URL", "Last Updated"]
        print(f"[DRY RUN] Would ensure header {header} exists.")
        print(f"[DRY RUN] Would append {len(data_rows)} rows to sheet '{sheet_name}':")
        for row_data in data_rows:
            print(f"[DRY RUN]   {row_data}")
        return True

    try:
        scope = ['https://spreadsheets.google.com/feeds', 'https://www.googleapis.com/auth/drive']
        creds = ServiceAccountCredentials.from_json_keyfile_name(credentials_file, scope)
        client = gspread.authorize(creds)
        spreadsheet = client.open_by_key(spreadsheet_id)
        
        try:
            sheet = spreadsheet.worksheet(sheet_name)
        except gspread.exceptions.WorksheetNotFound:
            print(f"Worksheet '{sheet_name}' not found. Creating it...")
            try:
                # Ensure the sheet_name for creation is also valid (it should be if from default or sanitized input)
                sheet = spreadsheet.add_worksheet(title=sheet_name, rows="100", cols="3") 
                print(f"Worksheet '{sheet_name}' created.")
            except Exception as e_create:
                print(f"Error creating worksheet '{sheet_name}': {e_create}. Invalid characters or too long?")
                return False
        
        header = ["Site Container Name", "Home URL", "Last Updated"]
        all_values = sheet.get_all_values() 

        if not all_values or (all_values and sheet.row_values(1) != header):
            is_empty = not all_values
            if is_empty:
                 print("Sheet is empty. Adding header row.")
                 sheet.append_row(header, value_input_option='USER_ENTERED')
            elif sheet.row_values(1) != header:
                 print(f"Warning: Sheet header in '{sheet_name}' is not as expected ({header}). Data will be appended.")

        print(f"Appending {len(data_rows)} rows to sheet '{sheet_name}'...")
        sheet.append_rows(data_rows, value_input_option='USER_ENTERED')
        
        print(f"Google Sheet '{sheet_name}' updated successfully.")
        return True
    except FileNotFoundError:
        print(f"Error: Google credentials file '{credentials_file}' not found.")
        return False
    except gspread.exceptions.APIError as e:
        print(f"Google Sheets API Error (Sheet: '{sheet_name}'): {e}")
        return False
    except Exception as e:
        print(f"An unexpected error occurred while updating Google Sheet '{sheet_name}': {e}")
        return False

def main():
    """
    Main function to orchestrate the process.
    """
    parser = argparse.ArgumentParser(
        description="Extract WordPress home URLs from Docker containers and update a Google Sheet.",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument(
        '--parent-dir',
        default=DEFAULT_PARENT_DIRECTORY,
        help=f"The root directory where WP site directories are located.\nDefault: {DEFAULT_PARENT_DIRECTORY}"
    )
    parser.add_argument(
        '--creds-file',
        default=DEFAULT_GOOGLE_CREDENTIALS_FILE,
        help=f"Path to your Google service account JSON key file.\nDefault: {DEFAULT_GOOGLE_CREDENTIALS_FILE}"
    )
    parser.add_argument(
        '--spreadsheet-id',
        default=DEFAULT_SPREADSHEET_ID,
        help=f"The ID of your Google Sheet.\nDefault: {DEFAULT_SPREADSHEET_ID}"
    )
    parser.add_argument(
        '--sheet-name',
        default=DEFAULT_SHEET_NAME,
        help=f"The name of the worksheet to update. \nDefault is based on server hostname: '{DEFAULT_SHEET_NAME}'"
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help="Perform a dry run. Print actions that would be taken without modifying Google Sheets or executing 'wp' commands fully."
    )
    parser.add_argument(
        '--check-json-key',
        action='store_true',
        help="Test if the JSON key provides necessary access to Google Sheets (using the target sheet name) and then exit."
    )

    args = parser.parse_args()

    # Sanitize user-provided sheet name if it's different from the default
    # The default is already sanitized.
    if args.sheet_name != DEFAULT_SHEET_NAME:
        args.sheet_name = sanitize_sheet_name(args.sheet_name)
        if not args.sheet_name.strip() or len(args.sheet_name) > 99: # safety for user input
            print(f"Warning: Provided --sheet-name was sanitized to an invalid or empty string. Falling back to default: {DEFAULT_SHEET_NAME}")
            args.sheet_name = DEFAULT_SHEET_NAME


    if args.check_json_key:
        print(f"--- Running JSON Key Check for sheet: '{args.sheet_name}' ---")
        if args.creds_file == DEFAULT_GOOGLE_CREDENTIALS_FILE or args.spreadsheet_id == DEFAULT_SPREADSHEET_ID:
            print("Warning: Using default placeholder values for --creds-file or --spreadsheet-id for the check.")
            print(f"  Credentials file: {args.creds_file}")
            print(f"  Spreadsheet ID: {args.spreadsheet_id}")
            if not os.path.exists(args.creds_file):
                 print(f"Critical Error: Credentials file '{args.creds_file}' does not exist. Please provide a valid path using --creds-file.")
                 sys.exit(1)
            if args.spreadsheet_id == 'YOUR_SPREADSHEET_ID':
                 print(f"Critical Error: Spreadsheet ID is '{args.spreadsheet_id}'. Please provide a valid ID using --spreadsheet-id.")
                 sys.exit(1)

        success = check_gsheet_access(args.spreadsheet_id, args.sheet_name, args.creds_file)
        if success:
            print("JSON key access test passed.")
            sys.exit(0)
        else:
            print("JSON key access test failed.")
            sys.exit(1)

    print("Starting WordPress URL extraction script...")
    if args.dry_run:
        print("--- DRY RUN MODE ENABLED ---")
    
    print(f"Configuration in use:")
    print(f"  Parent Directory: {args.parent_dir}")
    print(f"  Credentials File: {args.creds_file}")
    print(f"  Spreadsheet ID: {args.spreadsheet_id}")
    print(f"  Target Sheet Name: {args.sheet_name}") # Clarified this is the target

    if not args.dry_run and not os.path.exists(args.creds_file):
        print(f"Critical Error: Google credentials file not found at '{args.creds_file}'.")
        sys.exit(1)
    elif args.dry_run and not os.path.exists(args.creds_file):
         print(f"Warning: Google credentials file not found at '{args.creds_file}'. In a real run, this would be an error.")


    wp_directories = find_wp_sites(args.parent_dir)

    if not wp_directories:
        print(f"No WordPress site directories found in '{args.parent_dir}' matching the criteria.")
        sys.exit(0)

    print(f"Found {len(wp_directories)} potential WordPress sites: {', '.join(wp_directories)}")

    urls_to_sheet = []
    current_timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    for site_dir_name in wp_directories:
        container_name = site_dir_name 
        print(f"\nProcessing site: {container_name}")
        if not args.dry_run: 
             print(f"Attempting to execute: docker exec {container_name} wp option get home --skip-plugins --skip-themes")
        url = get_wp_home_url(container_name, dry_run=args.dry_run)
        if url:
            print(f"Successfully retrieved/simulated URL for {container_name}: {url}")
            urls_to_sheet.append([container_name, url, current_timestamp])
        else:
            print(f"Failed to retrieve/simulate URL for {container_name}.")
            urls_to_sheet.append([container_name, "Error: Could not retrieve URL", current_timestamp])


    if urls_to_sheet:
        print(f"\nAttempting to update Google Sheet '{args.sheet_name}'...")
        success = update_google_sheet(args.spreadsheet_id, args.sheet_name, args.creds_file, urls_to_sheet, dry_run=args.dry_run)
        if not success and not args.dry_run:
            print(f"Failed to update Google Sheet '{args.sheet_name}'.")
    else:
        print("No URLs were successfully extracted/simulated to send to Google Sheets.")

    print("\nScript finished.")
    if args.dry_run:
        print("--- DRY RUN COMPLETED ---")

if __name__ == '__main__':
    main()
