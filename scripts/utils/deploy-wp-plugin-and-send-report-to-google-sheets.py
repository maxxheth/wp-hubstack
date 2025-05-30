#!/usr/bin/env python3

import os
import subprocess
import gspread
from oauth2client.service_account import ServiceAccountCredentials
import datetime
import argparse
import sys
import socket
import re
import csv
import time # For timestamps

# --- Default Configuration ---
DEFAULT_PLUGIN_SOURCE_DIR = ""
DEFAULT_PLUGIN_SLUG = ""
DEFAULT_SITES_BASE_DIR = '/var/opt'
DEFAULT_GOOGLE_CREDENTIALS_FILE = 'path/to/your/google-credentials.json' # PLEASE REPLACE
DEFAULT_SPREADSHEET_ID = 'YOUR_SPREADSHEET_ID' # PLEASE REPLACE

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
        return "Default_Plugin_Log_Sheet"
    return name[:99]

try:
    raw_hostname = socket.gethostname()
    sanitized_hostname = sanitize_sheet_name(raw_hostname)
    DEFAULT_HOSTNAME_PART = sanitized_hostname if sanitized_hostname else "UnknownServer"
except Exception:
    DEFAULT_HOSTNAME_PART = "UnknownServer"

DEFAULT_SHEET_NAME = f'{DEFAULT_HOSTNAME_PART}_Plugin_Install_Log'
if not DEFAULT_SHEET_NAME.strip() or len(DEFAULT_SHEET_NAME) > 99:
    DEFAULT_SHEET_NAME = "Default_Server_Plugin_Log"

# --- End Default Configuration ---

def run_command(command, dry_run=False, capture_output=True):
    """
    Executes a shell command.
    Returns (return_code, stdout, stderr)
    """
    command_str = ' '.join(command)
    if dry_run:
        print(f"[DRY RUN] Would execute: {command_str}")
        return (0, "[DRY RUN] Simulated success", "") # Simulate success for dry run

    try:
        process = subprocess.run(command, capture_output=capture_output, text=True, check=False)
        return (process.returncode, process.stdout.strip() if process.stdout else "", process.stderr.strip() if process.stderr else "")
    except FileNotFoundError:
        print(f"Error: Command '{command[0]}' not found. Is it in your PATH?")
        return (127, "", f"Command not found: {command[0]}")
    except Exception as e:
        print(f"An unexpected error occurred while running command '{command_str}': {e}")
        return (1, "", str(e))


def process_single_site(site_name, plugin_source_dir, plugin_slug, 
                        wp_cli_cmd, wp_path_in_container, wp_plugins_dir_in_container, 
                        dry_run=False):
    """
    Processes a single site: checks container, copies plugin, activates plugin.
    Returns a tuple: (success_boolean, message_string)
    """
    # Derive container name from site_name
    # Remove .com (and potentially other common TLDs if needed, for now just .com)
    base_name = site_name.replace('.com', '') 
    # Add wp_ prefix
    container_name = f"wp_{base_name}"

    print(f"Processing site '{site_name}', targeting container: {container_name}")

    # 1. Check if container exists and is running
    if not dry_run:
        # Check existence
        inspect_cmd = ['sudo', 'docker', 'inspect', container_name]
        ret_code, _, stderr = run_command(inspect_cmd, dry_run=False, capture_output=True) # Always run this check
        if ret_code != 0:
            msg = f"Container '{container_name}' does not exist or error inspecting. Stderr: {stderr}"
            print(f"Info: {msg}")
            return False, msg

        # Check running state
        inspect_running_cmd = ['sudo', 'docker', 'inspect', '-f', '{{.State.Running}}', container_name]
        ret_code, stdout, stderr = run_command(inspect_running_cmd, dry_run=False, capture_output=True) # Always run
        if ret_code != 0 or stdout.strip() != 'true':
            msg = f"Container '{container_name}' is not running. State: '{stdout}'. Stderr: {stderr}"
            print(f"Warning: {msg}")
            return False, msg
    else:
        print(f"[DRY RUN] Would check if container '{container_name}' exists and is running.")

    # 2. Copy plugin
    # Basename of plugin_source_dir is the actual directory name that will be copied
    source_plugin_dir_name = os.path.basename(plugin_source_dir)
    # target_plugin_path_in_container = os.path.join(wp_plugins_dir_in_container, source_plugin_dir_name) # Not used directly in cp cmd

    print(f"Attempting to copy plugin from '{plugin_source_dir}' to container '{container_name}:{wp_plugins_dir_in_container}'")
    docker_cp_cmd = ['sudo', 'docker', 'cp', plugin_source_dir, f'{container_name}:{wp_plugins_dir_in_container}']
    
    ret_code, stdout, stderr = run_command(docker_cp_cmd, dry_run=dry_run)
    if ret_code != 0:
        msg = f"Failed to copy plugin to '{container_name}'. Stdout: {stdout}, Stderr: {stderr}"
        print(f"ERROR: {msg}")
        return False, msg
    
    copied_plugin_dir_in_container = os.path.join(wp_plugins_dir_in_container, source_plugin_dir_name)
    print(f"Plugin files copied (or would be copied) to '{copied_plugin_dir_in_container}' in container '{container_name}'.")

    # 3. Activate plugin
    print(f"Attempting to activate plugin '{plugin_slug}' in '{container_name}' as root...")
    wp_cli_full_command_parts = [wp_cli_cmd, 'plugin', 'activate', plugin_slug, f'--path={wp_path_in_container}', '--allow-root']
    docker_exec_cmd = ['sudo', 'docker', 'exec', '-u', 'root', container_name] + wp_cli_full_command_parts
    
    ret_code, stdout, stderr = run_command(docker_exec_cmd, dry_run=dry_run)
    if ret_code != 0:
        msg = f"Failed to activate plugin '{plugin_slug}' for '{site_name}'. WP-CLI Exit: {ret_code}. Output: {stdout} {stderr}"
        print(f"ERROR: {msg}")
        return False, msg

    success_msg = f"Plugin '{plugin_slug}' activation command successful for '{site_name}'. Output: {stdout}"
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

    header = ["Site Name", "Plugin Slug", "Status", "Timestamp"]

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
                 sheet.update('A1', [header], value_input_option='USER_ENTERED') # More reliable for new sheets
            elif sheet.row_values(1) != header:
                 print(f"Warning: Sheet header in '{sheet_name}' is not as expected. Current: {sheet.row_values(1)}. Expected: {header}. Data will be appended.")
                 # Optionally, you could clear and re-add header, or add to a new sheet. For now, just append.

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
    parser = argparse.ArgumentParser(
        description="Deploy WordPress plugin to Dockerized sites and log to Google Sheets.",
        formatter_class=argparse.RawTextHelpFormatter
    )
    # Plugin related args
    parser.add_argument('-p', '--plugin-source', required=True, help="Path to the UNZIPPED plugin directory on the HOST machine.")
    parser.add_argument('-s', '--plugin-slug', required=True, help="The slug of the plugin (directory name).")
    
    # Site selection args
    site_selection_group = parser.add_mutually_exclusive_group()
    site_selection_group.add_argument('-b', '--base-dir', default=None, help=f"Base directory on HOST containing site directories (scans for '.com'). Default if no CSV: {DEFAULT_SITES_BASE_DIR}")
    site_selection_group.add_argument('-c', '--site-csv', default=None, help="Path to a CSV file listing sites (format: site.com,true|false). Processes if 'false'.")
    site_selection_group.add_argument('-l', '--site-list', default=None, help="Path to a text file with newline-separated list of sites to process.")
    site_selection_group.add_argument('-a', '--add-sites', default=None, help="Single site or comma-delimited list of sites to process (e.g., 'site1.com' or 'site1.com,site2.com,site3.com').")

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
        
    wp_plugins_dir_in_container = os.path.join(args.wp_path, "wp-content", "plugins")

    # --- Validations ---
    if not os.path.isdir(args.plugin_source):
        error_exit(f"Plugin source directory '{args.plugin_source}' not found or is not a directory.")
    
    source_plugin_basename = os.path.basename(args.plugin_source)
    if source_plugin_basename != args.plugin_slug:
        print(f"Warning: Basename of --plugin-source ('{source_plugin_basename}') does not match --plugin-slug ('{args.plugin_slug}').")
        print(f"The copied directory in the container will be named '{source_plugin_basename}'.")
        print(f"If WP-CLI needs to activate by the slug '{args.plugin_slug}', ensure this is correct or rename your source directory.")


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

    # --- Main Logic ---
    print("Starting plugin deployment and logging process...")
    if args.dry_run:
        print("*** DRY RUN MODE ENABLED - NO ACTUAL CHANGES WILL BE MADE TO SYSTEMS OR SHEETS ***")
    
    print(f"Configuration:")
    print(f"  Plugin Source: {args.plugin_source}")
    print(f"  Plugin Slug: {args.plugin_slug}")
    print(f"  WP-CLI Command: {args.wp_cli_command}")
    print(f"  WP Path in Container: {args.wp_path}")
    print(f"  WP Plugins Dir in Container: {wp_plugins_dir_in_container}")
    if args.site_csv:
        print(f"  Site CSV File: {args.site_csv}")
    elif args.site_list:
        print(f"  Site List File: {args.site_list}")
    else:
        args.base_dir = args.base_dir or DEFAULT_SITES_BASE_DIR # Set default if CSV not used and base_dir is None
        print(f"  Sites Base Directory: {args.base_dir}")
    print(f"  Credentials File: {args.creds_file}")
    print(f"  Spreadsheet ID: {args.spreadsheet_id}")
    print(f"  Target Sheet Name: {args.sheet_name}")
    print("-----------------------------------------------------")

    if not args.dry_run and (args.creds_file == DEFAULT_GOOGLE_CREDENTIALS_FILE or args.spreadsheet_id == DEFAULT_SPREADSHEET_ID):
        print("Warning: Using default placeholder values for --creds-file or --spreadsheet-id. Google Sheets update will likely fail.")
    if not args.dry_run and not os.path.exists(args.creds_file):
        error_exit(f"Google credentials file '{args.creds_file}' not found. Cannot update sheet.")


    sites_to_process = []
    if args.site_csv:
        if not os.path.isfile(args.site_csv):
            error_exit(f"Site CSV file '{args.site_csv}' not found.")
        try:
            with open(args.site_csv, mode='r', newline='', encoding='utf-8') as csvfile:
                reader = csv.reader(csvfile)
                for i, row in enumerate(reader):
                    if not row or row[0].strip().startswith('#'): # Skip empty or comment lines
                        continue
                    if len(row) < 2:
                        print(f"Warning: CSV line {i+1} is malformed (not enough columns): {row}. Skipping.")
                        continue
                    
                    site_name_csv = row[0].strip()
                    process_flag_csv = row[1].strip().lower()
                    if process_flag_csv == 'false':
                        sites_to_process.append(site_name_csv)
        except Exception as e:
            error_exit(f"Error reading CSV file '{args.site_csv}': {e}")
        
        if not sites_to_process:
            error_exit("There are no sites to process.")
        
        print(f"Identified {len(sites_to_process)} sites from CSV marked 'false' for processing.")

    elif args.site_list:
        if not os.path.isfile(args.site_list):
            error_exit(f"Site list file '{args.site_list}' not found.")
        try:
            with open(args.site_list, mode='r', encoding='utf-8') as listfile:
                for i, line in enumerate(listfile, 1):
                    site_name = line.strip()
                    if not site_name or site_name.startswith('#'):  # Skip empty lines or comments
                        continue
                    sites_to_process.append(site_name)
        except Exception as e:
            error_exit(f"Error reading site list file '{args.site_list}': {e}")
        
        if not sites_to_process:
            error_exit("No sites found in the site list file.")
        
        print(f"Identified {len(sites_to_process)} sites from list file for processing.")

    elif args.add_sites:
        # Split by comma and strip whitespace from each site
        raw_sites = [site.strip() for site in args.add_sites.split(',')]
        for site in raw_sites:
            if site:  # Skip empty strings that might result from extra commas
                sites_to_process.append(site)
        
        if not sites_to_process:
            error_exit("No valid sites found in --add-sites parameter.")
        
        print(f"Identified {len(sites_to_process)} sites from --add-sites for processing: {sites_to_process}")

    else: # Use base_dir
        if not os.path.isdir(args.base_dir):
            error_exit(f"Sites base directory '{args.base_dir}' not found or not a directory.")
        for item in os.listdir(args.base_dir):
            item_path = os.path.join(args.base_dir, item)
            if os.path.isdir(item_path) and '.com' in item:
                sites_to_process.append(item)
        print(f"Found {len(sites_to_process)} potential sites in '{args.base_dir}' containing '.com'.")

    if not sites_to_process:
        print("No sites identified for processing.") # This will now primarily catch empty base_dir scenarios
        sys.exit(0)

    gsheet_data_rows = []
    for site_name in sites_to_process:
        print("-----------------------------------------------------")
        success, message = process_single_site(
            site_name, args.plugin_source, args.plugin_slug,
            args.wp_cli_command, args.wp_path, wp_plugins_dir_in_container,
            args.dry_run
        )
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        status_msg_for_sheet = ""
        if success:
            status_msg_for_sheet = f"Successfully installed and activated. {message}"
        else:
            status_msg_for_sheet = f"Failed: {message}"
        
        gsheet_data_rows.append([site_name, args.plugin_slug, status_msg_for_sheet, timestamp])

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

    print("\nPlugin deployment and logging process finished.")
    if args.dry_run:
        print("*** DRY RUN COMPLETED ***")

def error_exit(message):
    print(f"Error: {message}", file=sys.stderr)
    sys.exit(1)

if __name__ == '__main__':
    main()
