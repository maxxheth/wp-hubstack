# utils.py

"""
General utility functions for the Traefik/CrowdSec tool.
"""

import yaml
import os
from typing import Dict, Any
from logger_setup import logger # Assuming logger is initialized

# ================================
# YAML UTILITIES
# ================================

def load_yaml_file(file_path: str) -> Dict[Any, Any]:
    """Load and parse a YAML file."""
    logger.debug(f"Attempting to load YAML file: {file_path}")
    try:
        with open(file_path, 'r', encoding='utf-8') as file:
            data = yaml.safe_load(file)
            if data is None:
                logger.warning(f"YAML file '{file_path}' is empty or contains only null values.")
                return {}
            logger.debug(f"Successfully loaded YAML file: {file_path}")
            return data
    except FileNotFoundError:
        logger.error(f"YAML file '{file_path}' not found.")
        return {} # Return empty dict for consistency, error is logged
    except yaml.YAMLError as e:
        logger.error(f"Error parsing YAML file '{file_path}': {e}")
        return {} # Return empty dict, error is logged
    except Exception as e:
        logger.error(f"Unexpected error loading YAML file '{file_path}': {e}")
        return {} # Return empty dict, error is logged

def save_yaml_file(data: Dict[Any, Any], file_path: str) -> bool:
    """Save data to a YAML file."""
    logger.debug(f"Attempting to save data to YAML file: {file_path}")
    try:
        with open(file_path, 'w', encoding='utf-8') as file:
            yaml.dump(data, file, default_flow_style=False, indent=2, sort_keys=False)
        logger.debug(f"Successfully saved data to YAML file: {file_path}")
        return True
    except Exception as e:
        logger.error(f"Error saving YAML file '{file_path}': {e}")
        return False

# Note: sanitize_sheet_name was moved to config.py as it's closely tied to
# DEFAULT_SHEET_NAME generation which uses socket and re.
# If it's a more general utility, it could stay here, but its primary use
# in the original script was for a default config value.
