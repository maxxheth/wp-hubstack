# logger_setup.py

"""
Logging setup for the Traefik/CrowdSec tool.
"""

import logging
import sys
from config import DEFAULT_DEBUG_LOG_FILE, DEFAULT_DC_DEBUG_LOG_FILE

# ================================
# LOGGING SETUP
# ================================

def setup_logging(debug_log_file: str = DEFAULT_DEBUG_LOG_FILE) -> logging.Logger:
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

def setup_dc_logging(dc_debug_log_file: str = DEFAULT_DC_DEBUG_LOG_FILE) -> logging.Logger:
    """Set up Docker Compose specific logging."""
    dc_logger = logging.getLogger('docker_compose')
    # Check if handlers are already added to prevent duplication if called multiple times
    if not dc_logger.handlers:
        dc_handler = logging.FileHandler(dc_debug_log_file)
        dc_handler.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))
        dc_logger.addHandler(dc_handler)
        dc_logger.setLevel(logging.DEBUG)
    return dc_logger

# Initialize loggers immediately so they can be imported
logger = setup_logging()
dc_logger = setup_dc_logging()
