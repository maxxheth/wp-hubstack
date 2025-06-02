# config.py

"""
Default configurations and constants for the Traefik/CrowdSec tool.
"""

import socket
import re

# --- Default Application Configuration ---
DEFAULT_GOOGLE_CREDENTIALS_FILE = 'path/to/your/google-credentials.json'  # PLEASE REPLACE
DEFAULT_SPREADSHEET_ID = 'YOUR_SPREADSHEET_ID'  # PLEASE REPLACE
DEFAULT_TRAEFIK_DIR = '/var/opt/traefik'
DEFAULT_CURRENT_CONFIG = 'docker-compose.yml'
DEFAULT_PENDING_CONFIG = 'docker-compose-pending.yml'
DEFAULT_PARTIAL_CONFIG = 'docker-compose-partial.yml'
DEFAULT_BACKUP_CONFIG = 'docker-compose.bak.yml'
DEFAULT_DEBUG_LOG_FILE = 'debug.log'
DEFAULT_DC_DEBUG_LOG_FILE = 'dc-debug.log'
DEFAULT_TARGET_CONFIG = 'docker-compose.yml'
DEFAULT_WP_DOCKER_CONT_DIR = '/var/opt'

# Tarball configuration
DEFAULT_CROWDSEC_TARBALLS_DIR = 'crowdsec_tarballs'

# ================================
# CROWDSEC TEST CONFIGURATION
# ================================

# Traefik connection settings
TRAEFIK_SCHEME = "http"  # "http" or "https"
TRAEFIK_HOST = "localhost"  # Traefik host/domain
TRAEFIK_PORT = 80  # Traefik port (80 for HTTP, 443 for HTTPS)

# Test service settings - now only path, host headers come from container inspection
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

# --- Utility Functions for Config ---
def sanitize_sheet_name(name: str) -> str:
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

# --- Dynamic Default Values ---
try:
    raw_hostname = socket.gethostname()
    sanitized_hostname = sanitize_sheet_name(raw_hostname)
    DEFAULT_HOSTNAME_PART = sanitized_hostname if sanitized_hostname else "UnknownServer"
except Exception:
    DEFAULT_HOSTNAME_PART = "UnknownServer"

DEFAULT_SHEET_NAME = f'{DEFAULT_HOSTNAME_PART}_Config_Diffs'
if not DEFAULT_SHEET_NAME.strip() or len(DEFAULT_SHEET_NAME) > 99:
    DEFAULT_SHEET_NAME = "Default_Server_Config_Diffs"

