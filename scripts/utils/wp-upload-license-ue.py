#!/usr/bin/env python3
# filepath: /var/www/wp-hubstack/scripts/utils/wp-activate-ultimate-elementor-licenses.py

import os
import subprocess
import gspread
from oauth2client.service_account import ServiceAccountCredentials
import datetime
import argparse
import sys
import socket
import re
import time
from dotenv import load_dotenv

# --- Default Configuration ---
DEFAULT_GOOGLE_CREDENTIALS_FILE = 'path/to/your/google-credentials.json'
DEFAULT_SPREADSHEET_ID = 'YOUR_SPREADSHEET_ID'
DEFAULT_WP_CLI_COMMAND = "wp"
DEFAULT_WP_PATH_IN_CONTAINER = "/var/www/html"

def sanitize_sheet_name(name):
    """
    Sanitizes a string to be a valid Google Sheet name.
    """
    if not isinstance(name, str):
        name = str(name)
    name = re.sub(r'[\[\]*/\\?:]', '', name)
    name = name.replace(' ', '_').replace('.', '_').replace('-', '_')
    name = name.strip('_')
    if not name:
        return "Default_License_Activation_Sheet"
    return name[:99]

try:
    raw_hostname = socket.gethostname()
    sanitized_hostname = sanitize_sheet_name(raw_hostname)
    DEFAULT_HOSTNAME_PART = sanitized_hostname if sanitized_hostname else "UnknownServer"
except Exception:
    DEFAULT_HOSTNAME_PART = "UnknownServer"

DEFAULT_SHEET_NAME = f'{DEFAULT_HOSTNAME_PART}_Ultimate_Elementor_License'
if not DEFAULT_SHEET_NAME.strip() or len(DEFAULT_SHEET_NAME) > 99:
    DEFAULT_SHEET_NAME = "Default_Ultimate_Elementor_License"

def run_command(command, dry_run=False, capture_output=True):
    """
    Executes a shell command.
    Returns (return_code, stdout, stderr)
    """
    command_str = ' '.join(command)
    if dry_run:
        print(f"[DRY RUN] Would execute: {command_str}")
        return (0, "[DRY RUN] Simulated success", "")

    try:
        process = subprocess.run(command, capture_output=capture_output, text=True, check=False)
        return (process.returncode, process.stdout.strip() if process.stdout else "", process.stderr.strip() if process.stderr else "")
    except FileNotFoundError:
        print(f"Error: Command '{command[0]}' not found. Is it in your PATH?")
        return (127, "", f"Command not found: {command[0]}")
    except Exception as e:
        print(f"An unexpected error occurred while running command '{command_str}': {e}")
        return (1, "", str(e))

def get_docker_containers(container_prefix="wp_", dry_run=False):
    """
    Get list of running Docker containers with specified prefix
    Returns list of container names
    """
    if dry_run:
        print(f"[DRY RUN] Would get Docker containers with prefix '{container_prefix}'")
        return ["wp_example1", "wp_example2", "wp_example3"]
    
    docker_ps_cmd = ['sudo', 'docker', 'ps', '--format', '{{.Names}}']
    ret_code, stdout, stderr = run_command(docker_ps_cmd, dry_run=False, capture_output=True)
    
    if ret_code != 0:
        print(f"Error getting Docker containers: {stderr}")
        return []
    
    containers = []
    for container_name in stdout.split('\n'):
        container_name = container_name.strip()
        if container_name and container_name.startswith(container_prefix):
            containers.append(container_name)
    
    return containers

def activate_license_on_container(container_name, license_key, wp_cli_cmd, wp_path, dry_run=False):
    """
    Activate Ultimate Elementor license on a specific container
    Returns (success_boolean, message_string)
    """
    print(f"Processing container: {container_name}")
    
    # Check if container is running
    if not dry_run:
        inspect_cmd = ['sudo', 'docker', 'inspect', '-f', '{{.State.Running}}', container_name]
        ret_code, stdout, stderr = run_command(inspect_cmd, dry_run=False, capture_output=True)
        if ret_code != 0 or stdout.strip() != 'true':
            msg = f"Container '{container_name}' is not running. State: '{stdout}'. Stderr: {stderr}"
            print(f"Warning: {msg}")
            return False, msg
    else:
        print(f"[DRY RUN] Would check if container '{container_name}' is running")
    
    # Activate license using WP CLI
    print(f"Attempting to activate Ultimate Elementor license in '{container_name}'...")
    wp_cli_full_command_parts = [
        wp_cli_cmd, 'ultimate-elementor', 'license', 'activate', license_key,
        f'--path={wp_path}', '--allow-root'
    ]
    docker_exec_cmd = ['sudo', 'docker', 'exec', '-u', 'root', container_name] + wp_cli_full_command_parts
    
    ret_code, stdout, stderr = run_command(docker_exec_cmd, dry_run=dry_run)
    
    if ret_code != 0:
        msg = f"Failed to activate Ultimate Elementor license for '{container_name}'. Exit code: {ret_code}. Output: {stdout} {stderr}"
        print(f"ERROR: {msg}")
        return False, msg
    
    success_msg = f"Ultimate Elementor license activation successful for '{container_name}'. Output: {stdout}"
    print(f"SUCCESS: {success_msg}")
    return True, success_msg

def check_gsheet_access(spreadsheet_id, sheet_name, credentials_file):
    """Tests access to Google Sheets."""
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
        print("Google Sheets access test successful.")
        print("--- End of Google Sheets Access Check ---")
        return True
    except Exception as e:
        print(f"An error occurred during Google Sheets access check: {e}")
        if isinstance(e, gspread.exceptions.APIError):
            print("This could be due to: incorrect Spreadsheet ID, service account permissions, or API not enabled.")
        return False

def update_google_sheet(spreadsheet_id, sheet_name, credentials_file, data_rows, dry_run=False):
    """Appends data to the specified Google Sheet."""
    if not data_rows:
        print("No data to update in Google Sheet.")
        return True

    header = ["Container Name", "License Status", "Message", "Timestamp"]

    if dry_run:
        print(f"[DRY RUN] Would authenticate with Google Sheets using {credentials_file}.")
        print(f"[DRY RUN] Would open spreadsheet ID: {spreadsheet_id} and access/create sheet: '{sheet_name}'.")
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
                sheet = spreadsheet.add_worksheet(title=sheet_name, rows="100", cols=len(header))
                print(f"Worksheet '{sheet_name}' created.")
            except Exception as e_create:
                print(f"Error creating worksheet '{sheet_name}': {e_create}")
                return False
        
        all_values = sheet.get_all_values()
        if not all_values or (all_values and sheet.row_values(1) != header):
            if not all_values:
                print("Sheet is empty. Adding header row.")
                sheet.update('A1', [header], value_input_option='USER_ENTERED')
            elif sheet.row_values(1) != header:
                print(f"Warning: Sheet header in '{sheet_name}' is not as expected. Current: {sheet.row_values(1)}. Expected: {header}. Data will be appended.")

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

def load_env_variables():
    """Load environment variables from .env file"""
    # Load .env file
    load_dotenv()
    
    # Get LICENSE_KEY from environment
    license_key = os.getenv('LICENSE_KEY')
    if not license_key:
        error_exit("LICENSE_KEY is not set in the .env file. Please set it and try again.")
    
    return license_key

def main():
    parser = argparse.ArgumentParser(
        description="Activate Ultimate Elementor licenses on Dockerized WordPress sites and log to Google Sheets.",
        formatter_class=argparse.RawTextHelpFormatter
    )
    
    # Container selection args
    parser.add_argument('--container-prefix', default='wp_', help=f"Prefix for Docker containers to process. Default: wp_")
    
    # WP and Docker args
    parser.add_argument('--wp-cli-command', default=DEFAULT_WP_CLI_COMMAND, help=f"WP-CLI command/path in container. Default: {DEFAULT_WP_CLI_COMMAND}")
    parser.add_argument('--wp-path', default=DEFAULT_WP_PATH_IN_CONTAINER, help=f"WordPress path in container. Default: {DEFAULT_WP_PATH_IN_CONTAINER}")

    # Google Sheets args
    parser.add_argument('--creds-file', default=DEFAULT_GOOGLE_CREDENTIALS_FILE, help=f"Path to Google service account JSON key. Default: {DEFAULT_GOOGLE_CREDENTIALS_FILE}")
    parser.add_argument('--spreadsheet-id', default=DEFAULT_SPREADSHEET_ID, help=f"Google Sheet ID. Default: {DEFAULT_SPREADSHEET_ID}")
    parser.add_argument('--sheet-name', default=DEFAULT_SHEET_NAME, help=f"Worksheet name. Default based on hostname: '{DEFAULT_SHEET_NAME}'")
    
    # Action args
    parser.add_argument('--dry-run', action='store_true', help="Simulate execution without making changes.")
    parser.add_argument('--check-json-key', action='store_true', help="Test Google Sheets access with JSON key and exit.")

    args = parser.parse_args()

    # Post-process args
    args.sheet_name = sanitize_sheet_name(args.sheet_name)
    if not args.sheet_name.strip() or len(args.sheet_name) > 99:
        print(f"Warning: Provided --sheet-name was sanitized to an invalid string. Falling back to default: {DEFAULT_SHEET_NAME}")
        args.sheet_name = DEFAULT_SHEET_NAME

    if args.check_json_key:
        print(f"--- Running JSON Key Check for sheet: '{args.sheet_name}' ---")
        if args.creds_file == DEFAULT_GOOGLE_CREDENTIALS_FILE or args.spreadsheet_id == DEFAULT_SPREADSHEET_ID:
            print("Warning: Using default placeholder values for --creds-file or --spreadsheet-id for the check.")
        if not os.path.exists(args.creds_file):
            error_exit(f"Credentials file '{args.creds_file}' does not exist. Provide valid path via --creds-file.")
        if args.spreadsheet_id == 'YOUR_SPREADSHEET_ID':
            error_exit(f"Spreadsheet ID is '{args.spreadsheet_id}'. Provide valid ID via --spreadsheet-id.")
        
        success = check_gsheet_access(args.spreadsheet_id, args.sheet_name, args.creds_file)
        sys.exit(0 if success else 1)

    # Load LICENSE_KEY from .env
    license_key = load_env_variables()

    # --- Main Logic ---
    print("Starting Ultimate Elementor license activation process...")
    if args.dry_run:
        print("*** DRY RUN MODE ENABLED - NO ACTUAL CHANGES WILL BE MADE TO SYSTEMS OR SHEETS ***")
    
    print(f"Configuration:")
    print(f"  License Key: {license_key[:8]}..." if license_key else "  License Key: Not set")
    print(f"  Container Prefix: {args.container_prefix}")
    print(f"  WP-CLI Command: {args.wp_cli_command}")
    print(f"  WP Path in Container: {args.wp_path}")
    print(f"  Credentials File: {args.creds_file}")
    print(f"  Spreadsheet ID: {args.spreadsheet_id}")
    print(f"  Target Sheet Name: {args.sheet_name}")
    print("-----------------------------------------------------")

    if not args.dry_run and (args.creds_file == DEFAULT_GOOGLE_CREDENTIALS_FILE or args.spreadsheet_id == DEFAULT_SPREADSHEET_ID):
        print("Warning: Using default placeholder values for --creds-file or --spreadsheet-id. Google Sheets update will likely fail.")
    if not args.dry_run and not os.path.exists(args.creds_file):
        error_exit(f"Google credentials file '{args.creds_file}' not found. Cannot update sheet.")

    # Get Docker containers
    containers = get_docker_containers(args.container_prefix, args.dry_run)
    
    if not containers:
        print(f"No Docker containers found with prefix '{args.container_prefix}'")
        sys.exit(0)
    
    print(f"Found {len(containers)} containers to process: {containers}")

    gsheet_data_rows = []
    for container_name in containers:
        print("-----------------------------------------------------")
        success, message = activate_license_on_container(
            container_name, license_key, args.wp_cli_command, args.wp_path, args.dry_run
        )
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        status = "SUCCESS" if success else "FAILED"
        
        gsheet_data_rows.append([container_name, status, message, timestamp])

    if gsheet_data_rows:
        print("\nAttempting to update Google Sheet...")
        update_success = update_google_sheet(
            args.spreadsheet_id, args.sheet_name, args.creds_file, 
            gsheet_data_rows, args.dry_run
        )
        if not update_success and not args.dry_run:
            print("Failed to update Google Sheet.")
    else:
        print("No operations were performed that would result in Google Sheet updates.")

    print("\nUltimate Elementor license activation process finished.")
    if args.dry_run:
        print("*** DRY RUN COMPLETED ***")

def error_exit(message):
    print(f"Error: {message}", file=sys.stderr)
    sys.exit(1)

if __name__ == '__main__':
    main()