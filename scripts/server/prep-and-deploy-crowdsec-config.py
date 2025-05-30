#!/usr/bin/env python3
"""
Traefik Configuration Diff, Deployment, and CrowdSec Integration Test Tool

This comprehensive script provides:
1. Configuration diffing and deployment with Google Sheets/Docs integration
2. Automated backup management
3. CrowdSec + Traefik bouncer integration testing

The CrowdSec testing functionality tests the integration by:
1. Verifying access to a test service when no ban is active
2. Banning a test IP using CrowdSec cscli
3. Verifying access is blocked for the banned IP
4. Unbanning the IP
5. Verifying access is restored

Author: Generated for Traefik/CrowdSec configuration management and testing
"""

import os
import subprocess
import gspread
from oauth2client.service_account import ServiceAccountCredentials
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
import datetime
import argparse
import sys
import socket
import re
import yaml
import shutil
import difflib
from typing import Dict, Any, List, Tuple
import requests
import time
import urllib3

# Disable SSL warnings for self-signed certificates in testing
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# --- Default Configuration ---
DEFAULT_GOOGLE_CREDENTIALS_FILE = 'path/to/your/google-credentials.json'  # PLEASE REPLACE
DEFAULT_SPREADSHEET_ID = 'YOUR_SPREADSHEET_ID'  # PLEASE REPLACE
DEFAULT_TRAEFIK_DIR = '/var/opt/traefik'
DEFAULT_CURRENT_CONFIG = 'docker-compose.yml'
DEFAULT_PENDING_CONFIG = 'docker-compose-pending.yml'

# ================================
# CROWDSEC TEST CONFIGURATION
# ================================

# Traefik connection settings
TRAEFIK_SCHEME = "http"  # "http" or "https"
TRAEFIK_HOST = "localhost"  # Traefik host/domain
TRAEFIK_PORT = 80  # Traefik port (80 for HTTP, 443 for HTTPS)

# Test service settings
TEST_SERVICE_HOST_HEADER = "test-service.yourdomain.com"  # Host header for routing
TEST_SERVICE_PATH = "/"  # Path to test endpoint

# CrowdSec settings
CROWDSEC_LAPI_CONTAINER_NAME = "crowdsec"  # CrowdSec LAPI container name
TEST_IP_TO_BAN = "1.2.3.4"  # IP address to ban/unban for testing

# Expected HTTP status codes
EXPECTED_STATUS_ALLOWED = 200  # Status when access is allowed
EXPECTED_STATUS_BLOCKED = 403  # Status when access is blocked by bouncer

# Timing settings
BOUNCER_SYNC_DELAY_SECONDS = 15  # Wait time for bouncer to sync with LAPI

# HTTP request settings
REQUEST_TIMEOUT = 10  # Timeout for HTTP requests in seconds
VERIFY_SSL = False  # Set to True for production HTTPS with valid certs

# ================================
# UTILITY FUNCTIONS
# ================================

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
        return "Default_Config_Diff_Sheet"
    return name[:99]

try:
    raw_hostname = socket.gethostname()
    sanitized_hostname = sanitize_sheet_name(raw_hostname)
    DEFAULT_HOSTNAME_PART = sanitized_hostname if sanitized_hostname else "UnknownServer"
except Exception:
    DEFAULT_HOSTNAME_PART = "UnknownServer"

DEFAULT_SHEET_NAME = f'{DEFAULT_HOSTNAME_PART}_Config_Diffs'
if not DEFAULT_SHEET_NAME.strip() or len(DEFAULT_SHEET_NAME) > 99:
    DEFAULT_SHEET_NAME = "Default_Server_Config_Diffs"

def load_yaml_file(file_path: str) -> Dict[Any, Any]:
    """Load and parse a YAML file."""
    try:
        with open(file_path, 'r', encoding='utf-8') as file:
            return yaml.safe_load(file) or {}
    except FileNotFoundError:
        print(f"Error: YAML file '{file_path}' not found.")
        return {}
    except yaml.YAMLError as e:
        print(f"Error parsing YAML file '{file_path}': {e}")
        return {}
    except Exception as e:
        print(f"Unexpected error loading YAML file '{file_path}': {e}")
        return {}

def save_yaml_file(data: Dict[Any, Any], file_path: str) -> bool:
    """Save data to a YAML file."""
    try:
        with open(file_path, 'w', encoding='utf-8') as file:
            yaml.dump(data, file, default_flow_style=False, indent=2)
        return True
    except Exception as e:
        print(f"Error saving YAML file '{file_path}': {e}")
        return False

# ================================
# DIFF AND DEPLOYMENT FUNCTIONS
# ================================

def deep_diff_yaml(current: Dict[Any, Any], pending: Dict[Any, Any], path: str = "") -> Dict[str, Any]:
    """Create a deep diff between two YAML structures."""
    diff_result = {
        'added': {},
        'removed': {},
        'modified': {},
        'unchanged': {}
    }
    
    # Get all keys from both dictionaries
    all_keys = set(current.keys()) | set(pending.keys())
    
    for key in all_keys:
        current_path = f"{path}.{key}" if path else str(key)
        
        if key not in current:
            # Key added in pending
            diff_result['added'][current_path] = pending[key]
        elif key not in pending:
            # Key removed in pending
            diff_result['removed'][current_path] = current[key]
        elif current[key] != pending[key]:
            # Key modified
            if isinstance(current[key], dict) and isinstance(pending[key], dict):
                # Recursively diff nested dictionaries
                nested_diff = deep_diff_yaml(current[key], pending[key], current_path)
                for diff_type in ['added', 'removed', 'modified', 'unchanged']:
                    diff_result[diff_type].update(nested_diff[diff_type])
            else:
                diff_result['modified'][current_path] = {
                    'current': current[key],
                    'pending': pending[key]
                }
        else:
            # Key unchanged
            diff_result['unchanged'][current_path] = current[key]
    
    return diff_result

def create_diff_yaml(current_file: str, pending_file: str, output_file: str = "diff-conf.yml") -> Dict[str, Any]:
    """Create a diff YAML file comparing current and pending configurations."""
    print(f"Creating diff between '{current_file}' and '{pending_file}'...")
    
    current_config = load_yaml_file(current_file)
    pending_config = load_yaml_file(pending_file)
    
    if not current_config and not pending_config:
        print("Error: Both configuration files are empty or invalid.")
        return {}
    
    diff_data = deep_diff_yaml(current_config, pending_config)
    
    # Add metadata
    diff_with_metadata = {
        'metadata': {
            'current_file': current_file,
            'pending_file': pending_file,
            'diff_timestamp': datetime.datetime.now().isoformat(),
            'hostname': socket.gethostname()
        },
        'diff': diff_data
    }
    
    if save_yaml_file(diff_with_metadata, output_file):
        print(f"Diff saved to '{output_file}'")
        return diff_with_metadata
    else:
        print(f"Failed to save diff to '{output_file}'")
        return {}

def backup_config(config_path: str, dry_run: bool = False) -> str:
    """Create a timestamped backup of the configuration file."""
    if not os.path.exists(config_path):
        print(f"Error: Configuration file '{config_path}' does not exist.")
        return ""
    
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_path = f"{config_path}.backup_{timestamp}"
    
    if dry_run:
        print(f"[DRY RUN] Would create backup: {config_path} -> {backup_path}")
        return backup_path
    
    try:
        shutil.copy2(config_path, backup_path)
        print(f"Backup created: {backup_path}")
        return backup_path
    except Exception as e:
        print(f"Error creating backup: {e}")
        return ""

def deploy_config(diff_file: str, old_config: str, new_config: str, skip_backup: bool = False, dry_run: bool = False) -> bool:
    """Deploy configuration using diff file to guide the process."""
    if not os.path.exists(diff_file):
        print(f"Error: Diff file '{diff_file}' not found.")
        return False
    
    if not os.path.exists(new_config):
        print(f"Error: New configuration file '{new_config}' not found.")
        return False
    
    if dry_run:
        print(f"[DRY RUN] Would deploy config from '{new_config}' to '{old_config}'")
        print(f"[DRY RUN] Using diff file '{diff_file}' for validation")
        if not skip_backup:
            print(f"[DRY RUN] Would create backup of '{old_config}' before deployment")
        else:
            print(f"[DRY RUN] Backup skipped (--skip-backup flag)")
        return True
    
    try:
        # Load diff file to understand changes
        diff_data = load_yaml_file(diff_file)
        if not diff_data:
            print("Error: Could not load diff file or file is empty.")
            return False
        
        print("Diff analysis:")
        diff_info = diff_data.get('diff', {})
        print(f"  - Added: {len(diff_info.get('added', {}))}")
        print(f"  - Removed: {len(diff_info.get('removed', {}))}")
        print(f"  - Modified: {len(diff_info.get('modified', {}))}")
        
        # Create backup before deployment (unless skipped)
        backup_path = ""
        if not skip_backup:
            print(f"\n--- CREATING BACKUP ---")
            backup_path = backup_config(old_config)
            if not backup_path:
                print("Failed to create backup. Aborting deployment.")
                print("Use --skip-backup flag to deploy without backup (not recommended).")
                return False
        else:
            print(f"\n--- BACKUP SKIPPED ---")
            print("Warning: Deploying without backup (--skip-backup flag specified)")
        
        # Deploy new configuration
        print(f"\n--- DEPLOYING CONFIGURATION ---")
        shutil.copy2(new_config, old_config)
        print(f"Configuration deployed successfully from '{new_config}' to '{old_config}'")
        
        if backup_path:
            print(f"Original configuration backed up to: {backup_path}")
        
        return True
        
    except Exception as e:
        print(f"Error during deployment: {e}")
        return False

# ================================
# GOOGLE INTEGRATION FUNCTIONS
# ================================

def create_google_doc(credentials_file: str, title: str, content: str) -> str:
    """Create a Google Doc and return its URL."""
    try:
        scope = ['https://www.googleapis.com/auth/documents', 'https://www.googleapis.com/auth/drive']
        creds = ServiceAccountCredentials.from_json_keyfile_name(credentials_file, scope)
        
        # Build the Docs API service
        docs_service = build('docs', 'v1', credentials=creds)
        drive_service = build('drive', 'v3', credentials=creds)
        
        # Create a new document
        doc = docs_service.documents().create(body={'title': title}).execute()
        doc_id = doc.get('documentId')
        
        # Insert content into the document
        requests = [
            {
                'insertText': {
                    'location': {'index': 1},
                    'text': content
                }
            }
        ]
        
        docs_service.documents().batchUpdate(
            documentId=doc_id,
            body={'requests': requests}
        ).execute()
        
        # Make the document shareable
        drive_service.permissions().create(
            fileId=doc_id,
            body={'role': 'reader', 'type': 'anyone'}
        ).execute()
        
        doc_url = f"https://docs.google.com/document/d/{doc_id}"
        print(f"Created Google Doc: {doc_url}")
        return doc_url
        
    except Exception as e:
        print(f"Error creating Google Doc: {e}")
        return ""

def format_diff_content(current_file: str, pending_file: str) -> str:
    """Format diff content for Google Docs with color indicators."""
    try:
        with open(current_file, 'r', encoding='utf-8') as f:
            current_lines = f.readlines()
        with open(pending_file, 'r', encoding='utf-8') as f:
            pending_lines = f.readlines()
    except FileNotFoundError as e:
        return f"Error reading files: {e}"
    
    diff = difflib.unified_diff(
        current_lines, 
        pending_lines, 
        fromfile=f"Current: {current_file}",
        tofile=f"Pending: {pending_file}",
        lineterm=''
    )
    
    content = f"Traefik Configuration Diff\n"
    content += f"Generated: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n"
    content += f"Hostname: {socket.gethostname()}\n"
    content += "=" * 80 + "\n\n"
    
    content += "Legend:\n"
    content += "- Lines starting with '-' (RED): Removed from current config\n"
    content += "- Lines starting with '+' (GREEN): Added in pending config\n"
    content += "- Lines starting with ' ' (UNCHANGED): No changes\n\n"
    
    for line in diff:
        if line.startswith('-'):
            content += f"[RED] {line}\n"
        elif line.startswith('+'):
            content += f"[GREEN] {line}\n"
        else:
            content += f"{line}\n"
    
    return content

def update_google_sheet_with_diff(spreadsheet_id: str, sheet_name: str, credentials_file: str, 
                                doc_url: str, hostname: str, dry_run: bool = False) -> bool:
    """Update Google Sheet with diff information."""
    if dry_run:
        print(f"[DRY RUN] Would update Google Sheet '{sheet_name}' with diff information")
        print(f"[DRY RUN] Document URL: {doc_url}")
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
            sheet = spreadsheet.add_worksheet(title=sheet_name, rows="100", cols=3)
            print(f"Worksheet '{sheet_name}' created.")
        
        # Check if header exists
        header = ["Date of Diff", "Hostname", "Diff"]
        all_values = sheet.get_all_values()
        if not all_values or sheet.row_values(1) != header:
            sheet.update('A1', [header], value_input_option='USER_ENTERED')
        
        # Add new row with diff information
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        new_row = [timestamp, hostname, doc_url]
        sheet.append_row(new_row, value_input_option='USER_ENTERED')
        
        print(f"Google Sheet '{sheet_name}' updated successfully.")
        return True
        
    except Exception as e:
        print(f"Error updating Google Sheet: {e}")
        return False

# ================================
# CROWDSEC TESTING FUNCTIONS
# ================================

def run_cscli_command(command_args):
    """
    Execute a cscli command via docker exec.
    
    Args:
        command_args (list): List of arguments for cscli command
        
    Returns:
        bool: True on success (exit code 0), False otherwise
    """
    cmd = ["docker", "exec", CROWDSEC_LAPI_CONTAINER_NAME, "cscli"] + command_args
    
    print(f"Executing: {' '.join(cmd)}")
    
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30
        )
        
        # Print stdout if available
        if result.stdout.strip():
            print(f"STDOUT: {result.stdout.strip()}")
        
        # Print stderr if available
        if result.stderr.strip():
            print(f"STDERR: {result.stderr.strip()}")
        
        success = result.returncode == 0
        print(f"Command {'SUCCEEDED' if success else 'FAILED'} (exit code: {result.returncode})")
        
        return success
        
    except subprocess.TimeoutExpired:
        print("ERROR: Command timed out")
        return False
    except Exception as e:
        print(f"ERROR: Exception executing command: {e}")
        return False

def ban_ip(ip_address, reason="Automated Test Ban", duration="5m"):
    """
    Ban an IP address using CrowdSec cscli.
    
    Args:
        ip_address (str): IP address to ban
        reason (str): Reason for the ban
        duration (str): Duration of the ban (e.g., "5m", "1h")
        
    Returns:
        bool: True if ban was successful, False otherwise
    """
    print(f"\n--- Banning IP: {ip_address} ---")
    command_args = [
        "decisions", "add",
        "--ip", ip_address,
        "--reason", reason,
        "--duration", duration
    ]
    return run_cscli_command(command_args)

def unban_ip(ip_address):
    """
    Unban an IP address using CrowdSec cscli.
    
    Args:
        ip_address (str): IP address to unban
        
    Returns:
        bool: True if unban was successful or no decision existed, False on error
    """
    print(f"\n--- Unbanning IP: {ip_address} ---")
    command_args = [
        "decisions", "delete",
        "--ip", ip_address
    ]
    # Note: This may "fail" if no decision exists, but that's okay for cleanup
    return run_cscli_command(command_args)

def check_service_access():
    """
    Check access to the test service through Traefik.
    
    Returns:
        int: HTTP status code, or -1 on request failure
    """
    url = f"{TRAEFIK_SCHEME}://{TRAEFIK_HOST}:{TRAEFIK_PORT}{TEST_SERVICE_PATH}"
    headers = {
        "Host": TEST_SERVICE_HOST_HEADER,
        "User-Agent": "TraefikCrowdSecTester/1.0"
    }
    
    print(f"Making request to: {url}")
    print(f"Headers: {headers}")
    
    try:
        response = requests.get(
            url,
            headers=headers,
            timeout=REQUEST_TIMEOUT,
            verify=VERIFY_SSL,
            allow_redirects=False
        )
        
        status_code = response.status_code
        print(f"Response status: {status_code}")
        
        # Print response headers for debugging
        print("Response headers:")
        for key, value in response.headers.items():
            print(f"  {key}: {value}")
        
        return status_code
        
    except requests.exceptions.RequestException as e:
        print(f"ERROR: Request failed: {e}")
        return -1

def print_test_result(test_name, expected, actual, test_number):
    """Print formatted test result."""
    passed = expected == actual
    status = "PASSED" if passed else "FAILED"
    print(f"\n{'='*50}")
    print(f"Test {test_number}: {test_name}")
    print(f"Expected status: {expected}")
    print(f"Actual status: {actual}")
    print(f"Result: {status}")
    print(f"{'='*50}")
    return passed

def run_crowdsec_integration_tests(dry_run: bool = False) -> bool:
    """Run the complete CrowdSec integration test suite."""
    if dry_run:
        print(f"[DRY RUN] Would run CrowdSec integration tests")
        return True
    
    print(f"\n{'='*60}")
    print("RUNNING CROWDSEC INTEGRATION TESTS")
    print(f"{'='*60}")
    print("Traefik + CrowdSec Bouncer Integration Test")
    print("=" * 50)
    print(f"Target URL: {TRAEFIK_SCHEME}://{TRAEFIK_HOST}:{TRAEFIK_PORT}{TEST_SERVICE_PATH}")
    print(f"Host Header: {TEST_SERVICE_HOST_HEADER}")
    print(f"Test IP: {TEST_IP_TO_BAN}")
    print(f"CrowdSec Container: {CROWDSEC_LAPI_CONTAINER_NAME}")
    print(f"Sync Delay: {BOUNCER_SYNC_DELAY_SECONDS} seconds")
    print("=" * 50)
    
    test_results = []
    
    try:
        # Initial cleanup - ensure test IP is not banned
        print("\n--- INITIAL CLEANUP ---")
        unban_result = unban_ip(TEST_IP_TO_BAN)
        print(f"Initial cleanup result: {'SUCCESS' if unban_result else 'FAILED (may be normal if no existing ban)'}")
        
        # Wait for sync after cleanup
        print(f"\nWaiting {BOUNCER_SYNC_DELAY_SECONDS} seconds for bouncer sync...")
        time.sleep(BOUNCER_SYNC_DELAY_SECONDS)
        
        # Test 1: Access should be allowed (no ban active)
        print("\n--- TEST 1: ACCESS SHOULD BE ALLOWED ---")
        status_1 = check_service_access()
        test_1_passed = print_test_result("Access Allowed", EXPECTED_STATUS_ALLOWED, status_1, 1)
        test_results.append(("Test 1: Access Allowed", test_1_passed))
        
        # Action: Ban the test IP
        print("\n--- ACTION: BANNING TEST IP ---")
        ban_result = ban_ip(TEST_IP_TO_BAN)
        
        if not ban_result:
            print("ERROR: Failed to ban IP. Aborting blocking tests.")
            test_results.append(("Test 2: Access Blocked", False))
            test_results.append(("Test 3: Access Restored", False))
        else:
            print(f"IP ban successful. Waiting {BOUNCER_SYNC_DELAY_SECONDS} seconds for bouncer sync...")
            time.sleep(BOUNCER_SYNC_DELAY_SECONDS)
            
            # Test 2: Access should be blocked (ban active)
            print("\n--- TEST 2: ACCESS SHOULD BE BLOCKED ---")
            status_2 = check_service_access()
            test_2_passed = print_test_result("Access Blocked", EXPECTED_STATUS_BLOCKED, status_2, 2)
            test_results.append(("Test 2: Access Blocked", test_2_passed))
            
            # Action: Unban the test IP (cleanup)
            print("\n--- ACTION: UNBANNING TEST IP ---")
            unban_result = unban_ip(TEST_IP_TO_BAN)
            print(f"Unban result: {'SUCCESS' if unban_result else 'FAILED'}")
            
            print(f"Waiting {BOUNCER_SYNC_DELAY_SECONDS} seconds for bouncer sync...")
            time.sleep(BOUNCER_SYNC_DELAY_SECONDS)
            
            # Test 3: Access should be restored (no ban active)
            print("\n--- TEST 3: ACCESS SHOULD BE RESTORED ---")
            status_3 = check_service_access()
            test_3_passed = print_test_result("Access Restored", EXPECTED_STATUS_ALLOWED, status_3, 3)
            test_results.append(("Test 3: Access Restored", test_3_passed))
        
        # Final summary
        print("\n" + "=" * 60)
        print("TEST SUMMARY")
        print("=" * 60)
        
        all_passed = True
        for test_name, passed in test_results:
            status = "PASSED" if passed else "FAILED"
            print(f"{test_name}: {status}")
            if not passed:
                all_passed = False
        
        print("=" * 60)
        overall_status = "ALL TESTS PASSED" if all_passed else "SOME TESTS FAILED"
        print(f"Overall Result: {overall_status}")
        print("=" * 60)
        
        return all_passed
        
    except KeyboardInterrupt:
        print("\n\nTest interrupted by user.")
        print("Attempting cleanup...")
        unban_ip(TEST_IP_TO_BAN)
        return False
    except Exception as e:
        print(f"\nUnexpected error during tests: {e}")
        print("Attempting cleanup...")
        unban_ip(TEST_IP_TO_BAN)
        return False

# ================================
# MAIN FUNCTION
# ================================

def main():
    parser = argparse.ArgumentParser(
        description="Traefik Configuration Diff, Deployment, and CrowdSec Integration Test Tool with Google Sheets/Docs integration.",
        formatter_class=argparse.RawTextHelpFormatter
    )
    
    # Configuration diff and deployment args
    parser.add_argument('--diff-confs', help="Compare configurations (format: 'current_config|pending_config')")
    parser.add_argument('--backup-conf', help="Create timestamped backup of configuration file")
    parser.add_argument('--deploy-conf', help="Deploy configuration (format: 'old_config|new_config')")
    
    # Backup and testing args
    parser.add_argument('--skip-backup', action='store_true',
                       help="Skip creating backup during deployment (not recommended)")
    parser.add_argument('--skip-tests', action='store_true',
                       help="Skip running integration tests after deployment")
    parser.add_argument('--test-only', action='store_true',
                       help="Run only CrowdSec integration tests (no deployment)")
    
    # Google integration args
    parser.add_argument('--creds-file', default=DEFAULT_GOOGLE_CREDENTIALS_FILE, 
                       help=f"Path to Google service account JSON key. Default: {DEFAULT_GOOGLE_CREDENTIALS_FILE}")
    parser.add_argument('--spreadsheet-id', default=DEFAULT_SPREADSHEET_ID, 
                       help=f"Google Sheet ID. Default: {DEFAULT_SPREADSHEET_ID}")
    parser.add_argument('--sheet-name', default=DEFAULT_SHEET_NAME, 
                       help=f"Worksheet name. Default: '{DEFAULT_SHEET_NAME}'")
    
    # Action args
    parser.add_argument('--dry-run', action='store_true', help="Simulate execution without making changes.")
    
    args = parser.parse_args()
    
    # Sanitize sheet name
    args.sheet_name = sanitize_sheet_name(args.sheet_name)
    if not args.sheet_name.strip() or len(args.sheet_name) > 99:
        print(f"Warning: Invalid sheet name. Using default: {DEFAULT_SHEET_NAME}")
        args.sheet_name = DEFAULT_SHEET_NAME
    
    hostname = socket.gethostname()
    
    if args.dry_run:
        print("*** DRY RUN MODE ENABLED - NO ACTUAL CHANGES WILL BE MADE ***")
    
    if args.skip_backup:
        print("*** WARNING: BACKUP DISABLED - ORIGINAL CONFIG WILL NOT BE BACKED UP ***")
    
    # Handle test-only mode
    if args.test_only:
        print("Running CrowdSec integration tests only...")
        test_success = run_crowdsec_integration_tests(args.dry_run)
        sys.exit(0 if test_success else 1)
    
    # Track if any deployment occurred
    deployment_occurred = False
    
    # Handle diff-confs
    if args.diff_confs:
        if '|' not in args.diff_confs:
            print("Error: --diff-confs requires format 'current_config|pending_config'")
            sys.exit(1)
        
        current_config, pending_config = args.diff_confs.split('|', 1)
        current_config = current_config.strip()
        pending_config = pending_config.strip()
        
        print(f"Comparing configurations: '{current_config}' vs '{pending_config}'")
        
        # Create diff
        diff_data = create_diff_yaml(current_config, pending_config)
        if not diff_data:
            print("Error: Failed to create diff.")
            sys.exit(1)
        
        # Create Google Doc with diff content
        if not args.dry_run:
            if args.creds_file == DEFAULT_GOOGLE_CREDENTIALS_FILE or args.spreadsheet_id == DEFAULT_SPREADSHEET_ID:
                print("Warning: Using default placeholder values for Google integration.")
            
            if os.path.exists(args.creds_file):
                doc_title = f"{hostname} Traefik Config Diff"
                diff_content = format_diff_content(current_config, pending_config)
                doc_url = create_google_doc(args.creds_file, doc_title, diff_content)
                
                if doc_url:
                    # Update Google Sheet
                    update_google_sheet_with_diff(
                        args.spreadsheet_id, args.sheet_name, args.creds_file,
                        doc_url, hostname, args.dry_run
                    )
                else:
                    print("Failed to create Google Doc.")
            else:
                print(f"Google credentials file '{args.creds_file}' not found. Skipping Google integration.")
        else:
            print("[DRY RUN] Would create Google Doc and update spreadsheet")
    
    # Handle backup-conf
    if args.backup_conf:
        backup_config(args.backup_conf, args.dry_run)
    
    # Handle deploy-conf
    if args.deploy_conf:
        if '|' not in args.deploy_conf:
            print("Error: --deploy-conf requires format 'old_config|new_config'")
            sys.exit(1)
        
        old_config, new_config = args.deploy_conf.split('|', 1)
        old_config = old_config.strip()
        new_config = new_config.strip()
        
        # Check if diff file exists, create if not
        diff_file = "diff-conf.yml"
        if not os.path.exists(diff_file):
            print(f"Diff file '{diff_file}' not found. Creating it...")
            diff_data = create_diff_yaml(old_config, new_config, diff_file)
            if not diff_data:
                print("Error: Failed to create diff file for deployment.")
                sys.exit(1)
        
        # Deploy configuration with backup handling
        if deploy_config(diff_file, old_config, new_config, args.skip_backup, args.dry_run):
            print("Configuration deployment completed successfully.")
            deployment_occurred = True
        else:
            print("Configuration deployment failed.")
            sys.exit(1)
    
    # Run integration tests if deployment occurred and tests are not skipped
    if deployment_occurred and not args.skip_tests:
        print(f"\nDeployment completed. Running integration tests...")
        
        test_success = run_crowdsec_integration_tests(args.dry_run)
        
        if not test_success:
            print("\nWARNING: Integration tests failed after deployment!")
            print("Please review the test output and verify your configuration.")
            # Don't exit with error code as deployment was successful
        else:
            print("\nIntegration tests passed successfully!")
    elif args.skip_tests and deployment_occurred:
        print("\nDeployment completed. Integration tests skipped (--skip-tests flag used).")
    
    # If no main action was specified, show help
    if not any([args.diff_confs, args.backup_conf, args.deploy_conf, args.test_only]):
        print("No action specified. Use --diff-confs, --backup-conf, --deploy-conf, or --test-only.")
        parser.print_help()

def error_exit(message):
    print(f"Error: {message}", file=sys.stderr)
    sys.exit(1)

if __name__ == '__main__':
    main()