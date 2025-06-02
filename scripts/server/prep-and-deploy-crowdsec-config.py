#!/usr/bin/env python3
"""
Traefik Configuration Diff, Deployment, and CrowdSec Integration Test Tool

This comprehensive script provides:
1. Configuration diffing and deployment with Google Sheets/Docs integration
2. Automated backup management with transactional deployment
3. CrowdSec + Traefik bouncer integration testing
4. Error recovery and logging to debug.log and Google Sheets
5. Integrated CrowdSec helper commands

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
from typing import Dict, Any, List, Tuple, Optional
import requests
import time
import urllib3
import traceback
import logging

# Disable SSL warnings for self-signed certificates in testing
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# --- Default Configuration ---
DEFAULT_GOOGLE_CREDENTIALS_FILE = 'path/to/your/google-credentials.json'  # PLEASE REPLACE
DEFAULT_SPREADSHEET_ID = 'YOUR_SPREADSHEET_ID'  # PLEASE REPLACE
DEFAULT_TRAEFIK_DIR = '/var/opt/traefik'
DEFAULT_CURRENT_CONFIG = 'docker-compose.yml'
DEFAULT_PENDING_CONFIG = 'docker-compose-pending.yml'
DEFAULT_DEBUG_LOG_FILE = 'debug.log'

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
CROWDSEC_TRAEFIK_BOUNCER_CONTAINER_NAME = "crowdsec-bouncer"  # Traefik bouncer container
TRAEFIK_CONTAINER_NAME = "traefik"  # Traefik container
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
# LOGGING SETUP
# ================================

def setup_logging(debug_log_file: str = DEFAULT_DEBUG_LOG_FILE):
    """Set up logging configuration."""
    logging.basicConfig(
        level=logging.DEBUG,
        format='%(asctime)s - %(levelname)s - %(message)s',
        handlers=[
            logging.FileHandler(debug_log_file),
            logging.StreamHandler(sys.stdout)
        ]
    )
    return logging.getLogger(__name__)

logger = setup_logging()

# ================================
# ERROR HANDLING AND RECOVERY
# ================================

class DeploymentError(Exception):
    """Custom exception for deployment-related errors."""
    pass

class TransactionManager:
    """Manages transactional deployments with rollback capability."""
    
    def __init__(self, original_config_path: str, backup_path: str = ""):
        self.original_config_path = original_config_path
        self.backup_path = backup_path
        self.deployment_started = False
        self.rollback_performed = False
    
    def start_deployment(self):
        """Mark the start of deployment transaction."""
        self.deployment_started = True
        logger.info(f"Starting deployment transaction for {self.original_config_path}")
    
    def rollback(self):
        """Rollback to the backup configuration."""
        if not self.backup_path or not os.path.exists(self.backup_path):
            logger.error("Cannot rollback: backup file not available")
            return False
        
        try:
            shutil.copy2(self.backup_path, self.original_config_path)
            self.rollback_performed = True
            logger.info(f"Rollback successful: restored {self.original_config_path} from {self.backup_path}")
            return True
        except Exception as e:
            logger.error(f"Rollback failed: {e}")
            return False
    
    def cleanup(self):
        """Clean up temporary files if rollback was not needed."""
        if not self.rollback_performed and self.backup_path and os.path.exists(self.backup_path):
            # Keep backup for safety, but log its location
            logger.info(f"Deployment successful. Backup retained at: {self.backup_path}")

def log_error_to_google_sheets(spreadsheet_id: str, credentials_file: str, error_message: str, dry_run: bool = False):
    """Log error to Google Sheets Debug Log worksheet."""
    if dry_run:
        logger.info(f"[DRY RUN] Would log error to Google Sheets: {error_message}")
        return
    
    try:
        scope = ['https://spreadsheets.google.com/feeds', 'https://www.googleapis.com/auth/drive']
        creds = ServiceAccountCredentials.from_json_keyfile_name(credentials_file, scope)
        client = gspread.authorize(creds)
        spreadsheet = client.open_by_key(spreadsheet_id)
        
        # Get or create Debug Log worksheet
        debug_sheet_name = "Debug Log"
        try:
            sheet = spreadsheet.worksheet(debug_sheet_name)
        except gspread.exceptions.WorksheetNotFound:
            logger.info(f"Creating '{debug_sheet_name}' worksheet...")
            sheet = spreadsheet.add_worksheet(title=debug_sheet_name, rows="1000", cols=2)
            # Add headers
            sheet.update('A1', [["Date of Incident", "Incident"]], value_input_option='USER_ENTERED')
        
        # Add error entry
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        new_row = [timestamp, error_message]
        sheet.append_row(new_row, value_input_option='USER_ENTERED')
        logger.info(f"Error logged to Google Sheets Debug Log")
        
    except Exception as e:
        logger.error(f"Failed to log error to Google Sheets: {e}")

def handle_deployment_error(error: Exception, transaction_manager: TransactionManager, 
                          spreadsheet_id: str = "", credentials_file: str = "", dry_run: bool = False):
    """Handle deployment errors with rollback and logging."""
    error_message = f"Deployment Error: {str(error)}\nTraceback: {traceback.format_exc()}"
    
    # Log to debug.log
    logger.error(error_message)
    
    # Log to Google Sheets if configured
    if spreadsheet_id and credentials_file and os.path.exists(credentials_file):
        log_error_to_google_sheets(spreadsheet_id, credentials_file, error_message, dry_run)
    
    # Perform rollback
    if transaction_manager.deployment_started:
        logger.info("Attempting rollback due to deployment error...")
        rollback_success = transaction_manager.rollback()
        if rollback_success:
            logger.info("Rollback completed successfully")
        else:
            logger.error("Rollback failed - manual intervention required")

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
        logger.error(f"YAML file '{file_path}' not found.")
        return {}
    except yaml.YAMLError as e:
        logger.error(f"Error parsing YAML file '{file_path}': {e}")
        return {}
    except Exception as e:
        logger.error(f"Unexpected error loading YAML file '{file_path}': {e}")
        return {}

def save_yaml_file(data: Dict[Any, Any], file_path: str) -> bool:
    """Save data to a YAML file."""
    try:
        with open(file_path, 'w', encoding='utf-8') as file:
            yaml.dump(data, file, default_flow_style=False, indent=2)
        return True
    except Exception as e:
        logger.error(f"Error saving YAML file '{file_path}': {e}")
        return False

# ================================
# CROWDSEC HELPER FUNCTIONS
# ================================

def run_docker_command(container_name: str, command: List[str], timeout: int = 30) -> Tuple[bool, str, str]:
    """
    Execute a command in a Docker container.
    
    Returns:
        Tuple of (success, stdout, stderr)
    """
    cmd = ["docker", "exec", container_name] + command
    logger.debug(f"Executing Docker command: {' '.join(cmd)}")
    
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout
        )
        
        success = result.returncode == 0
        stdout = result.stdout.strip()
        stderr = result.stderr.strip()
        
        if stdout:
            logger.debug(f"STDOUT: {stdout}")
        if stderr:
            logger.debug(f"STDERR: {stderr}")
        
        logger.debug(f"Command {'SUCCEEDED' if success else 'FAILED'} (exit code: {result.returncode})")
        
        return success, stdout, stderr
        
    except subprocess.TimeoutExpired:
        logger.error("Docker command timed out")
        return False, "", "Command timed out"
    except Exception as e:
        logger.error(f"Exception executing Docker command: {e}")
        return False, "", str(e)

def run_cscli_command(command_args: List[str]) -> bool:
    """Execute a cscli command via docker exec."""
    cmd = ["cscli"] + command_args
    success, stdout, stderr = run_docker_command(CROWDSEC_LAPI_CONTAINER_NAME, cmd)
    
    if stdout:
        print(f"STDOUT: {stdout}")
    if stderr:
        print(f"STDERR: {stderr}")
    
    return success

# CrowdSec Decision Management
def cs_decisions_list(extra_args: List[str] = None) -> bool:
    """List CrowdSec decisions."""
    args = ["decisions", "list"]
    if extra_args:
        args.extend(extra_args)
    return run_cscli_command(args)

def cs_decisions_list_ip(ip_address: str) -> bool:
    """List decisions for a specific IP."""
    return run_cscli_command(["decisions", "list", "--ip", ip_address])

def cs_ban_ip(ip_address: str, reason: str, duration: str) -> bool:
    """Ban an IP address."""
    return run_cscli_command([
        "decisions", "add",
        "--ip", ip_address,
        "--reason", reason,
        "--duration", duration
    ])

def cs_unban_ip(ip_address: str) -> bool:
    """Unban an IP address."""
    return run_cscli_command(["decisions", "delete", "--ip", ip_address])

def cs_unban_id(decision_id: str) -> bool:
    """Unban by decision ID."""
    return run_cscli_command(["decisions", "delete", "--id", decision_id])

# CrowdSec Collections Management
def cs_collections_list() -> bool:
    """List CrowdSec collections."""
    return run_cscli_command(["collections", "list"])

def cs_collections_install(collection_name: str) -> bool:
    """Install a CrowdSec collection."""
    return run_cscli_command(["collections", "install", collection_name])

# CrowdSec Hub Management
def cs_hub_update() -> bool:
    """Update CrowdSec hub."""
    return run_cscli_command(["hub", "update"])

def cs_hub_upgrade(collection_name: str = "") -> bool:
    """Upgrade CrowdSec collections."""
    args = ["hub", "upgrade"]
    if collection_name:
        args.append(collection_name)
    return run_cscli_command(args)

# CrowdSec Status Checks
def cs_capi_status() -> bool:
    """Check CrowdSec CAPI status."""
    return run_cscli_command(["capi", "status"])

def cs_bouncers_list() -> bool:
    """List registered bouncers."""
    return run_cscli_command(["bouncers", "list"])

def cs_bouncer_add(bouncer_name: str) -> bool:
    """Add a new bouncer and generate API key."""
    return run_cscli_command(["bouncers", "add", bouncer_name])

def cs_bouncer_delete(bouncer_name: str) -> bool:
    """Delete a bouncer."""
    return run_cscli_command(["bouncers", "delete", bouncer_name])

# Docker Container Management
def restart_container(container_name: str) -> bool:
    """Restart a Docker container."""
    try:
        result = subprocess.run(
            ["docker", "restart", container_name],
            capture_output=True,
            text=True,
            timeout=60
        )
        success = result.returncode == 0
        if success:
            logger.info(f"Container '{container_name}' restarted successfully")
        else:
            logger.error(f"Failed to restart container '{container_name}': {result.stderr}")
        return success
    except Exception as e:
        logger.error(f"Exception restarting container '{container_name}': {e}")
        return False

def test_bouncer_connectivity() -> bool:
    """Test connectivity between Traefik and CrowdSec bouncer."""
    logger.info("Testing bouncer connectivity from Traefik container...")
    
    # Try curl first, then wget
    for tool in ["curl", "wget"]:
        if tool == "curl":
            cmd = ["curl", "-I", "--connect-timeout", "5", "http://bouncer-traefik:8080/api/v1/forwardAuth"]
        else:
            cmd = ["wget", "--spider", "-S", "http://bouncer-traefik:8080/api/v1/forwardAuth"]
        
        success, stdout, stderr = run_docker_command(TRAEFIK_CONTAINER_NAME, cmd, timeout=10)
        if success:
            logger.info(f"Bouncer connectivity test passed using {tool}")
            return True
    
    logger.error("Bouncer connectivity test failed - no working HTTP client found in Traefik container")
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
    logger.info(f"Creating diff between '{current_file}' and '{pending_file}'...")
    
    current_config = load_yaml_file(current_file)
    pending_config = load_yaml_file(pending_file)
    
    if not current_config and not pending_config:
        logger.error("Both configuration files are empty or invalid.")
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
        logger.info(f"Diff saved to '{output_file}'")
        return diff_with_metadata
    else:
        logger.error(f"Failed to save diff to '{output_file}'")
        return {}

def backup_config(config_path: str, dry_run: bool = False) -> str:
    """Create a timestamped backup of the configuration file."""
    if not os.path.exists(config_path):
        logger.error(f"Configuration file '{config_path}' does not exist.")
        return ""
    
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_path = f"{config_path}.backup_{timestamp}"
    
    if dry_run:
        logger.info(f"[DRY RUN] Would create backup: {config_path} -> {backup_path}")
        return backup_path
    
    try:
        shutil.copy2(config_path, backup_path)
        logger.info(f"Backup created: {backup_path}")
        return backup_path
    except Exception as e:
        logger.error(f"Error creating backup: {e}")
        return ""

def deploy_config(diff_file: str, old_config: str, new_config: str, skip_backup: bool = False, 
                 dry_run: bool = False, spreadsheet_id: str = "", credentials_file: str = "") -> bool:
    """Deploy configuration with transactional rollback capability."""
    transaction_manager = None
    
    try:
        if not os.path.exists(diff_file):
            raise DeploymentError(f"Diff file '{diff_file}' not found.")
        
        if not os.path.exists(new_config):
            raise DeploymentError(f"New configuration file '{new_config}' not found.")
        
        if dry_run:
            logger.info(f"[DRY RUN] Would deploy config from '{new_config}' to '{old_config}'")
            logger.info(f"[DRY RUN] Using diff file '{diff_file}' for validation")
            if not skip_backup:
                logger.info(f"[DRY RUN] Would create backup of '{old_config}' before deployment")
            else:
                logger.info(f"[DRY RUN] Backup skipped (--skip-backup flag)")
            return True
        
        # Load diff file to understand changes
        diff_data = load_yaml_file(diff_file)
        if not diff_data:
            raise DeploymentError("Could not load diff file or file is empty.")
        
        logger.info("Diff analysis:")
        diff_info = diff_data.get('diff', {})
        logger.info(f"  - Added: {len(diff_info.get('added', {}))}")
        logger.info(f"  - Removed: {len(diff_info.get('removed', {}))}")
        logger.info(f"  - Modified: {len(diff_info.get('modified', {}))}")
        
        # Create backup before deployment (unless skipped)
        backup_path = ""
        if not skip_backup:
            logger.info("Creating backup...")
            backup_path = backup_config(old_config)
            if not backup_path:
                raise DeploymentError("Failed to create backup.")
        else:
            logger.warning("Backup skipped - deploying without backup (--skip-backup flag specified)")
        
        # Initialize transaction manager
        transaction_manager = TransactionManager(old_config, backup_path)
        transaction_manager.start_deployment()
        
        # Deploy new configuration
        logger.info("Deploying configuration...")
        shutil.copy2(new_config, old_config)
        logger.info(f"Configuration deployed successfully from '{new_config}' to '{old_config}'")
        
        if backup_path:
            logger.info(f"Original configuration backed up to: {backup_path}")
        
        # Clean up transaction
        transaction_manager.cleanup()
        return True
        
    except Exception as e:
        if transaction_manager:
            handle_deployment_error(e, transaction_manager, spreadsheet_id, credentials_file, dry_run)
        else:
            logger.error(f"Deployment error (no transaction manager): {e}")
            if spreadsheet_id and credentials_file:
                log_error_to_google_sheets(spreadsheet_id, credentials_file, str(e), dry_run)
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
        logger.info(f"Created Google Doc: {doc_url}")
        return doc_url
        
    except Exception as e:
        logger.error(f"Error creating Google Doc: {e}")
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
        logger.info(f"[DRY RUN] Would update Google Sheet '{sheet_name}' with diff information")
        logger.info(f"[DRY RUN] Document URL: {doc_url}")
        return True
    
    try:
        scope = ['https://spreadsheets.google.com/feeds', 'https://www.googleapis.com/auth/drive']
        creds = ServiceAccountCredentials.from_json_keyfile_name(credentials_file, scope)
        client = gspread.authorize(creds)
        spreadsheet = client.open_by_key(spreadsheet_id)
        
        try:
            sheet = spreadsheet.worksheet(sheet_name)
        except gspread.exceptions.WorksheetNotFound:
            logger.info(f"Worksheet '{sheet_name}' not found. Creating it...")
            sheet = spreadsheet.add_worksheet(title=sheet_name, rows="100", cols=3)
            logger.info(f"Worksheet '{sheet_name}' created.")
        
        # Check if header exists
        header = ["Date of Diff", "Hostname", "Diff"]
        all_values = sheet.get_all_values()
        if not all_values or sheet.row_values(1) != header:
            sheet.update('A1', [header], value_input_option='USER_ENTERED')
        
        # Add new row with diff information
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        new_row = [timestamp, hostname, doc_url]
        sheet.append_row(new_row, value_input_option='USER_ENTERED')
        
        logger.info(f"Google Sheet '{sheet_name}' updated successfully.")
        return True
        
    except Exception as e:
        logger.error(f"Error updating Google Sheet: {e}")
        return False

# ================================
# CROWDSEC TESTING FUNCTIONS
# ================================

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
    logger.info(f"Banning IP: {ip_address}")
    return cs_ban_ip(ip_address, reason, duration)

def unban_ip(ip_address):
    """
    Unban an IP address using CrowdSec cscli.
    
    Args:
        ip_address (str): IP address to unban
        
    Returns:
        bool: True if unban was successful or no decision existed, False on error
    """
    logger.info(f"Unbanning IP: {ip_address}")
    return cs_unban_ip(ip_address)

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
    
    logger.info(f"Making request to: {url}")
    logger.debug(f"Headers: {headers}")
    
    try:
        response = requests.get(
            url,
            headers=headers,
            timeout=REQUEST_TIMEOUT,
            verify=VERIFY_SSL,
            allow_redirects=False
        )
        
        status_code = response.status_code
        logger.info(f"Response status: {status_code}")
        
        # Log response headers for debugging
        logger.debug("Response headers:")
        for key, value in response.headers.items():
            logger.debug(f"  {key}: {value}")
        
        return status_code
        
    except requests.exceptions.RequestException as e:
        logger.error(f"Request failed: {e}")
        return -1

def print_test_result(test_name, expected, actual, test_number):
    """Print formatted test result."""
    passed = expected == actual
    status = "PASSED" if passed else "FAILED"
    result_msg = f"\nTest {test_number}: {test_name}\nExpected status: {expected}\nActual status: {actual}\nResult: {status}"
    
    print(f"\n{'='*50}")
    print(f"Test {test_number}: {test_name}")
    print(f"Expected status: {expected}")
    print(f"Actual status: {actual}")
    print(f"Result: {status}")
    print(f"{'='*50}")
    
    logger.info(result_msg)
    return passed

def run_crowdsec_integration_tests(dry_run: bool = False, spreadsheet_id: str = "", 
                                  credentials_file: str = "") -> bool:
    """Run the complete CrowdSec integration test suite with error handling."""
    if dry_run:
        logger.info("[DRY RUN] Would run CrowdSec integration tests")
        return True
    
    logger.info("Starting CrowdSec integration tests")
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
        logger.info("Performing initial cleanup")
        print("\n--- INITIAL CLEANUP ---")
        unban_result = unban_ip(TEST_IP_TO_BAN)
        cleanup_msg = f"Initial cleanup result: {'SUCCESS' if unban_result else 'FAILED (may be normal if no existing ban)'}"
        print(cleanup_msg)
        logger.info(cleanup_msg)
        
        # Wait for sync after cleanup
        logger.info(f"Waiting {BOUNCER_SYNC_DELAY_SECONDS} seconds for bouncer sync...")
        print(f"\nWaiting {BOUNCER_SYNC_DELAY_SECONDS} seconds for bouncer sync...")
        time.sleep(BOUNCER_SYNC_DELAY_SECONDS)
        
        # Test 1: Access should be allowed (no ban active)
        logger.info("Starting Test 1: Access should be allowed")
        print("\n--- TEST 1: ACCESS SHOULD BE ALLOWED ---")
        status_1 = check_service_access()
        test_1_passed = print_test_result("Access Allowed", EXPECTED_STATUS_ALLOWED, status_1, 1)
        test_results.append(("Test 1: Access Allowed", test_1_passed))
        
        # Action: Ban the test IP
        logger.info("Banning test IP")
        print("\n--- ACTION: BANNING TEST IP ---")
        ban_result = ban_ip(TEST_IP_TO_BAN)
        
        if not ban_result:
            error_msg = "Failed to ban IP. Aborting blocking tests."
            logger.error(error_msg)
            print(f"ERROR: {error_msg}")
            test_results.append(("Test 2: Access Blocked", False))
            test_results.append(("Test 3: Access Restored", False))
            
            if spreadsheet_id and credentials_file:
                log_error_to_google_sheets(spreadsheet_id, credentials_file, error_msg, dry_run)
        else:
            sync_msg = f"IP ban successful. Waiting {BOUNCER_SYNC_DELAY_SECONDS} seconds for bouncer sync..."
            logger.info(sync_msg)
            print(sync_msg)
            time.sleep(BOUNCER_SYNC_DELAY_SECONDS)
            
            # Test 2: Access should be blocked (ban active)
            logger.info("Starting Test 2: Access should be blocked")
            print("\n--- TEST 2: ACCESS SHOULD BE BLOCKED ---")
            status_2 = check_service_access()
            test_2_passed = print_test_result("Access Blocked", EXPECTED_STATUS_BLOCKED, status_2, 2)
            test_results.append(("Test 2: Access Blocked", test_2_passed))
            
            # Action: Unban the test IP (cleanup)
            logger.info("Unbanning test IP")
            print("\n--- ACTION: UNBANNING TEST IP ---")
            unban_result = unban_ip(TEST_IP_TO_BAN)
            unban_msg = f"Unban result: {'SUCCESS' if unban_result else 'FAILED'}"
            logger.info(unban_msg)
            print(unban_msg)
            
            logger.info(f"Waiting {BOUNCER_SYNC_DELAY_SECONDS} seconds for bouncer sync...")
            print(f"Waiting {BOUNCER_SYNC_DELAY_SECONDS} seconds for bouncer sync...")
            time.sleep(BOUNCER_SYNC_DELAY_SECONDS)
            
            # Test 3: Access should be restored (no ban active)
            logger.info("Starting Test 3: Access should be restored")
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
        
        logger.info(f"CrowdSec integration tests completed: {overall_status}")
        return all_passed
        
    except KeyboardInterrupt:
        interrupt_msg = "Test interrupted by user."
        logger.warning(interrupt_msg)
        print(f"\n\n{interrupt_msg}")
        print("Attempting cleanup...")
        unban_ip(TEST_IP_TO_BAN)
        return False
    except Exception as e:
        error_msg = f"Unexpected error during tests: {e}"
        logger.error(error_msg)
        print(f"\n{error_msg}")
        print("Attempting cleanup...")
        unban_ip(TEST_IP_TO_BAN)
        
        if spreadsheet_id and credentials_file:
            log_error_to_google_sheets(spreadsheet_id, credentials_file, error_msg, dry_run)
        
        return False

# ================================
# MAIN FUNCTION
# ================================

def main():
    parser = argparse.ArgumentParser(
        description="Traefik Configuration Diff, Deployment, and CrowdSec Integration Test Tool with Google Sheets/Docs integration and transactional deployment.",
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
    
    # CrowdSec helper commands
    parser.add_argument('--cs-decisions-list', action='store_true',
                       help="List CrowdSec decisions")
    parser.add_argument('--cs-decisions-list-ip', metavar='IP',
                       help="List decisions for specific IP")
    parser.add_argument('--cs-ban-ip', metavar='IP:REASON:DURATION',
                       help="Ban IP (format: 'ip:reason:duration')")
    parser.add_argument('--cs-unban-ip', metavar='IP',
                       help="Unban IP address")
    parser.add_argument('--cs-bouncers-list', action='store_true',
                       help="List registered bouncers")
    parser.add_argument('--cs-hub-update', action='store_true',
                       help="Update CrowdSec hub")
    parser.add_argument('--cs-test-connectivity', action='store_true',
                       help="Test connectivity between Traefik and bouncer")
    parser.add_argument('--cs-restart-lapi', action='store_true',
                       help="Restart CrowdSec LAPI container")
    parser.add_argument('--cs-restart-bouncer', action='store_true',
                       help="Restart CrowdSec Traefik bouncer container")
    
    # Google integration args
    parser.add_argument('--creds-file', default=DEFAULT_GOOGLE_CREDENTIALS_FILE, 
                       help=f"Path to Google service account JSON key. Default: {DEFAULT_GOOGLE_CREDENTIALS_FILE}")
    parser.add_argument('--spreadsheet-id', default=DEFAULT_SPREADSHEET_ID, 
                       help=f"Google Sheet ID. Default: {DEFAULT_SPREADSHEET_ID}")
    parser.add_argument('--sheet-name', default=DEFAULT_SHEET_NAME, 
                       help=f"Worksheet name. Default: '{DEFAULT_SHEET_NAME}'")
    
    # Logging args
    parser.add_argument('--debug-log', default=DEFAULT_DEBUG_LOG_FILE,
                       help=f"Debug log file path. Default: {DEFAULT_DEBUG_LOG_FILE}")
    
    # Action args
    parser.add_argument('--dry-run', action='store_true', help="Simulate execution without making changes.")
    
    args = parser.parse_args()
    
    # Set up logging with custom debug log file
    global logger
    logger = setup_logging(args.debug_log)
    
    # Sanitize sheet name
    args.sheet_name = sanitize_sheet_name(args.sheet_name)
    if not args.sheet_name.strip() or len(args.sheet_name) > 99:
        logger.warning(f"Invalid sheet name. Using default: {DEFAULT_SHEET_NAME}")
        args.sheet_name = DEFAULT_SHEET_NAME
    
    hostname = socket.gethostname()
    
    if args.dry_run:
        logger.info("DRY RUN MODE ENABLED - NO ACTUAL CHANGES WILL BE MADE")
        print("*** DRY RUN MODE ENABLED - NO ACTUAL CHANGES WILL BE MADE ***")
    
    if args.skip_backup:
        logger.warning("BACKUP DISABLED - ORIGINAL CONFIG WILL NOT BE BACKED UP")
        print("*** WARNING: BACKUP DISABLED - ORIGINAL CONFIG WILL NOT BE BACKED UP ***")
    
    # Handle CrowdSec helper commands
    if args.cs_decisions_list:
        cs_decisions_list()
        return
    
    if args.cs_decisions_list_ip:
        cs_decisions_list_ip(args.cs_decisions_list_ip)
        return
    
    if args.cs_ban_ip:
        try:
            ip, reason, duration = args.cs_ban_ip.split(':', 2)
            cs_ban_ip(ip, reason, duration)
        except ValueError:
            logger.error("--cs-ban-ip requires format 'ip:reason:duration'")
            sys.exit(1)
        return
    
    if args.cs_unban_ip:
        cs_unban_ip(args.cs_unban_ip)
        return
    
    if args.cs_bouncers_list:
        cs_bouncers_list()
        return
    
    if args.cs_hub_update:
        cs_hub_update()
        return
    
    if args.cs_test_connectivity:
        test_bouncer_connectivity()
        return
    
    if args.cs_restart_lapi:
        restart_container(CROWDSEC_LAPI_CONTAINER_NAME)
        return
    
    if args.cs_restart_bouncer:
        restart_container(CROWDSEC_TRAEFIK_BOUNCER_CONTAINER_NAME)
        return
    
    # Handle test-only mode
    if args.test_only:
        logger.info("Running CrowdSec integration tests only...")
        print("Running CrowdSec integration tests only...")
        test_success = run_crowdsec_integration_tests(args.dry_run, args.spreadsheet_id, args.creds_file)
        sys.exit(0 if test_success else 1)
    
    # Track if any deployment occurred
    deployment_occurred = False
    
    # Handle diff-confs
    if args.diff_confs:
        if '|' not in args.diff_confs:
            logger.error("--diff-confs requires format 'current_config|pending_config'")
            print("Error: --diff-confs requires format 'current_config|pending_config'")
            sys.exit(1)
        
        current_config, pending_config = args.diff_confs.split('|', 1)
        current_config = current_config.strip()
        pending_config = pending_config.strip()
        
        logger.info(f"Comparing configurations: '{current_config}' vs '{pending_config}'")
        print(f"Comparing configurations: '{current_config}' vs '{pending_config}'")
        
        # Create diff
        diff_data = create_diff_yaml(current_config, pending_config)
        if not diff_data:
            logger.error("Failed to create diff.")
            print("Error: Failed to create diff.")
            sys.exit(1)
        
        # Create Google Doc with diff content
        if not args.dry_run:
            if args.creds_file == DEFAULT_GOOGLE_CREDENTIALS_FILE or args.spreadsheet_id == DEFAULT_SPREADSHEET_ID:
                logger.warning("Using default placeholder values for Google integration.")
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
                    logger.error("Failed to create Google Doc.")
                    print("Failed to create Google Doc.")
            else:
                logger.warning(f"Google credentials file '{args.creds_file}' not found. Skipping Google integration.")
                print(f"Google credentials file '{args.creds_file}' not found. Skipping Google integration.")
        else:
            logger.info("[DRY RUN] Would create Google Doc and update spreadsheet")
            print("[DRY RUN] Would create Google Doc and update spreadsheet")
    
    # Handle backup-conf
    if args.backup_conf:
        backup_config(args.backup_conf, args.dry_run)
    
    # Handle deploy-conf
    if args.deploy_conf:
        if '|' not in args.deploy_conf:
            logger.error("--deploy-conf requires format 'old_config|new_config'")
            print("Error: --deploy-conf requires format 'old_config|new_config'")
            sys.exit(1)
        
        old_config, new_config = args.deploy_conf.split('|', 1)
        old_config = old_config.strip()
        new_config = new_config.strip()
        
        # Check if diff file exists, create if not
        diff_file = "diff-conf.yml"
        if not os.path.exists(diff_file):
            logger.info(f"Diff file '{diff_file}' not found. Creating it...")
            print(f"Diff file '{diff_file}' not found. Creating it...")
            diff_data = create_diff_yaml(old_config, new_config, diff_file)
            if not diff_data:
                logger.error("Failed to create diff file for deployment.")
                print("Error: Failed to create diff file for deployment.")
                sys.exit(1)
        
        # Deploy configuration with transactional rollback
        if deploy_config(diff_file, old_config, new_config, args.skip_backup, args.dry_run, 
                        args.spreadsheet_id, args.creds_file):
            logger.info("Configuration deployment completed successfully.")
            print("Configuration deployment completed successfully.")
            deployment_occurred = True
        else:
            logger.error("Configuration deployment failed.")
            print("Configuration deployment failed.")
            sys.exit(1)
    
    # Run integration tests if deployment occurred and tests are not skipped
    if deployment_occurred and not args.skip_tests:
        logger.info("Deployment completed. Running integration tests...")
        print(f"\nDeployment completed. Running integration tests...")
        
        test_success = run_crowdsec_integration_tests(args.dry_run, args.spreadsheet_id, args.creds_file)
        
        if not test_success:
            logger.warning("Integration tests failed after deployment!")
            print("\nWARNING: Integration tests failed after deployment!")
            print("Please review the test output and verify your configuration.")
            # Don't exit with error code as deployment was successful
        else:
            logger.info("Integration tests passed successfully!")
            print("\nIntegration tests passed successfully!")
    elif args.skip_tests and deployment_occurred:
        logger.info("Deployment completed. Integration tests skipped (--skip-tests flag used).")
        print("\nDeployment completed. Integration tests skipped (--skip-tests flag used).")
    
    # If no main action was specified, show help
    if not any([args.diff_confs, args.backup_conf, args.deploy_conf, args.test_only,
                args.cs_decisions_list, args.cs_decisions_list_ip, args.cs_ban_ip, args.cs_unban_ip,
                args.cs_bouncers_list, args.cs_hub_update, args.cs_test_connectivity,
                args.cs_restart_lapi, args.cs_restart_bouncer]):
        print("No action specified. Use --help for available options.")
        parser.print_help()

def error_exit(message):
    logger.error(message)
    print(f"Error: {message}", file=sys.stderr)
    sys.exit(1)

if __name__ == '__main__':
    main()