# label_injector.py

"""
Manages safe label injection into Docker Compose files with backup and rollback.
"""

import os
import shutil
import traceback
from typing import Dict, Any, List, Tuple

from logger_setup import logger, dc_logger
from utils import load_yaml_file, save_yaml_file
from docker_utils import restart_docker_compose_stack
# Assuming DEFAULT_CURRENT_CONFIG, DEFAULT_PARTIAL_CONFIG, DEFAULT_BACKUP_CONFIG are imported or passed if needed
# from config import DEFAULT_CURRENT_CONFIG, DEFAULT_PARTIAL_CONFIG, DEFAULT_BACKUP_CONFIG

# ================================
# LABEL INJECTION FUNCTIONS
# ================================

class LabelInjectionError(Exception):
    """Custom exception for label injection errors."""
    pass

class LabelInjectionManager:
    """Manages safe label injection with backup and rollback capability."""

    def __init__(self, target_file: str, partial_file: str, backup_file: str):
        self.target_file = target_file
        self.partial_file = partial_file
        self.backup_file = backup_file
        self.backup_created = False
        self.injection_performed = False # Tracks if labels were actually changed

    def create_backup(self) -> bool:
        """Create a backup of the target file."""
        if not os.path.exists(self.target_file):
            raise LabelInjectionError(f"Target file '{self.target_file}' does not exist for backup.")

        try:
            shutil.copy2(self.target_file, self.backup_file)
            self.backup_created = True
            logger.info(f"Backup of '{self.target_file}' created at '{self.backup_file}'")
            return True
        except Exception as e:
            raise LabelInjectionError(f"Failed to create backup from '{self.target_file}' to '{self.backup_file}': {e}")

    def rollback(self) -> bool:
        """Rollback to the backup file."""
        if not self.backup_created or not os.path.exists(self.backup_file):
            logger.error(f"Cannot rollback: backup '{self.backup_file}' not available or not created.")
            return False

        try:
            shutil.copy2(self.backup_file, self.target_file)
            logger.info(f"Rollback successful: restored '{self.target_file}' from '{self.backup_file}'")
            return True
        except Exception as e:
            logger.error(f"Rollback from '{self.backup_file}' to '{self.target_file}' failed: {e}")
            return False

    def inject_labels(self, service_name: str = "traefik") -> bool:
        """Inject labels from partial file into target file."""
        try:
            # Load partial configuration
            if not os.path.exists(self.partial_file):
                raise LabelInjectionError(f"Partial file '{self.partial_file}' does not exist.")

            partial_config = load_yaml_file(self.partial_file)
            if not partial_config: # Handles empty or invalid YAML
                raise LabelInjectionError(f"Partial file '{self.partial_file}' is empty or invalid.")

            # Extract labels from partial config
            partial_labels = self._extract_labels_from_partial(partial_config, service_name)
            if not partial_labels:
                # This could be a valid scenario if the partial file is meant to remove all labels,
                # but current logic implies there should be labels.
                logger.warning(f"No labels found for service '{service_name}' in partial config '{self.partial_file}'.")
                # Depending on desired behavior, might not be an error.
                # For now, let's assume it's not an error to find no labels to inject.
                # If injection means "set these labels", then empty means "set no labels".

            # Load target configuration
            if not os.path.exists(self.target_file):
                 raise LabelInjectionError(f"Target file '{self.target_file}' does not exist for injection.")
            target_config = load_yaml_file(self.target_file)
            if not target_config and os.path.exists(self.target_file): # File exists but is invalid/empty
                 raise LabelInjectionError(f"Target file '{self.target_file}' is empty or invalid.")


            # Inject labels into target config
            updated_config, labels_changed_count = self._inject_labels_into_target(target_config, partial_labels, service_name)

            if labels_changed_count > 0:
                # Save updated configuration only if changes were made
                if not save_yaml_file(updated_config, self.target_file):
                    raise LabelInjectionError(f"Failed to save updated configuration to '{self.target_file}'.")
                self.injection_performed = True
                logger.info(f"{labels_changed_count} labels successfully injected/updated for service '{service_name}' in '{self.target_file}'.")
            else:
                logger.info(f"No changes to labels for service '{service_name}' in '{self.target_file}'. File not modified.")

            return True

        except LabelInjectionError as lie: # Catch specific errors first
            logger.error(f"Label injection error: {lie}")
            raise # Re-raise to be caught by the calling function
        except Exception as e:
            # Catch any other unexpected errors during the process
            detailed_error = f"Unexpected error during label injection: {e}\n{traceback.format_exc()}"
            logger.error(detailed_error)
            raise LabelInjectionError(detailed_error) # Wrap in custom error

    def _extract_labels_from_partial(self, partial_config: Dict[Any, Any], service_name: str) -> List[str]:
        """Extract labels from partial configuration."""
        try:
            services = partial_config.get('services', {})
            service_data = services.get(service_name)

            if not service_data:
                # If the service itself is not in the partial, there are no labels for it.
                logger.warning(f"Service '{service_name}' not found in partial config '{self.partial_file}'. No labels to extract for this service.")
                return [] # Return empty list, not an error

            labels = service_data.get('labels', []) # Default to empty list if 'labels' key is missing

            if isinstance(labels, list):
                return labels
            elif isinstance(labels, dict):
                return [f"{key}={value}" for key, value in labels.items()]
            else:
                raise LabelInjectionError(f"Invalid label format for service '{service_name}' in partial config: expected list or dict, got {type(labels)}.")

        except Exception as e: # Catch any unexpected error during extraction
            raise LabelInjectionError(f"Failed to extract labels for service '{service_name}' from partial config: {e}")

    def _inject_labels_into_target(self, target_config: Dict[Any, Any],
                                 new_labels_to_inject: List[str], service_name: str) -> Tuple[Dict[Any, Any], int]:
        """
        Inject labels into target configuration.
        Overwrites existing labels with the same key, adds new ones.
        Returns the modified target_config and the count of labels actually changed/added.
        """
        changes_made_count = 0
        try:
            if 'services' not in target_config or service_name not in target_config['services']:
                # If the service doesn't exist in the target, we cannot inject labels into it.
                # This could be an error, or a signal to create the service.
                # For now, assume service must exist.
                raise LabelInjectionError(f"Service '{service_name}' not found in target configuration '{self.target_file}'. Cannot inject labels.")

            service_config = target_config['services'][service_name]

            # Ensure labels section exists, default to list as per Docker Compose common practice
            if 'labels' not in service_config:
                service_config['labels'] = []

            existing_labels_list = service_config.get('labels', [])
            # Normalize existing labels to a dictionary for easier comparison and update
            # Handles both list format ['key=value', 'keyonly'] and dict format {'key': 'value'}
            existing_labels_dict = {}
            if isinstance(existing_labels_list, list):
                for label_item in existing_labels_list:
                    if isinstance(label_item, str):
                        if '=' in label_item:
                            key, value = label_item.split('=', 1)
                            existing_labels_dict[key] = value
                        else:
                            existing_labels_dict[label_item] = "" # Label without a value
                    elif isinstance(label_item, dict): # e.g. [{'foo':'bar'}]
                        existing_labels_dict.update(label_item)
            elif isinstance(existing_labels_list, dict):
                existing_labels_dict = existing_labels_list.copy()
            else:
                raise LabelInjectionError(f"Unsupported label format in target service '{service_name}': {type(existing_labels_list)}")


            # Prepare new labels as a dictionary
            new_labels_dict = {}
            for label_str in new_labels_to_inject:
                if '=' in label_str:
                    key, value = label_str.split('=', 1)
                    new_labels_dict[key] = value
                else:
                    new_labels_dict[label_str] = ""


            # Update existing_labels_dict with new_labels_dict
            # Count changes: new keys, or existing keys with different values
            for key, value in new_labels_dict.items():
                if key not in existing_labels_dict or existing_labels_dict[key] != value:
                    existing_labels_dict[key] = value
                    changes_made_count += 1
                    logger.info(f"Label for service '{service_name}': set '{key}={value if value else '<no_value>'}'.")


            # Convert the final dictionary back to a list of strings for YAML output
            # This ensures a consistent format in the docker-compose.yml
            final_labels_list = []
            for key, value in existing_labels_dict.items():
                if value: # If value is not empty string
                    final_labels_list.append(f"{key}={value}")
                else:
                    final_labels_list.append(key) # Label without value

            service_config['labels'] = final_labels_list
            if changes_made_count > 0:
                 logger.info(f"Total {changes_made_count} labels changed/added for service '{service_name}'.")
            else:
                 logger.info(f"No actual changes to labels for service '{service_name}'.")


            return target_config, changes_made_count

        except Exception as e: # Catch any unexpected error during injection logic
            raise LabelInjectionError(f"Failed to inject labels into service '{service_name}': {e}")


def inject_labels_with_restart(target_file: str,
                              partial_file: str,
                              backup_file: str,
                              service_name: str = "traefik",
                              working_dir: str = None,
                              dry_run: bool = False) -> bool:
    """
    Safely inject labels from partial config into target config with Docker Compose restart.
    """
    original_cwd = None
    if working_dir:
        original_cwd = os.getcwd()
        try:
            os.chdir(working_dir)
            logger.info(f"Changed working directory to: {working_dir}")
            # Adjust file paths to be relative to the new working_dir or ensure they are absolute
            # If target_file, partial_file, backup_file are relative, they are now relative to working_dir
        except FileNotFoundError:
            logger.error(f"Working directory '{working_dir}' not found.")
            if original_cwd: os.chdir(original_cwd) # Change back
            return False
        except Exception as e:
            logger.error(f"Error changing to working directory '{working_dir}': {e}")
            if original_cwd: os.chdir(original_cwd) # Change back
            return False


    # Ensure paths are absolute if a working_dir is used, or resolve them correctly
    abs_target_file = os.path.abspath(target_file)
    abs_partial_file = os.path.abspath(partial_file)
    abs_backup_file = os.path.abspath(backup_file)

    injection_manager = None # Initialize to None

    try:
        if dry_run:
            logger.info(f"[DRY RUN] Would inject labels from '{abs_partial_file}' into service '{service_name}' in '{abs_target_file}'.")
            logger.info(f"[DRY RUN] Original file would be backed up to '{abs_backup_file}'.")
            logger.info(f"[DRY RUN] Docker Compose stack in '{os.getcwd()}' would be restarted.")
            return True

        injection_manager = LabelInjectionManager(abs_target_file, abs_partial_file, abs_backup_file)

        logger.info(f"Creating backup of '{abs_target_file}' before label injection...")
        injection_manager.create_backup() # This will raise LabelInjectionError on failure

        logger.info(f"Injecting labels from '{abs_partial_file}' into service '{service_name}' of '{abs_target_file}'...")
        injection_manager.inject_labels(service_name) # This will raise LabelInjectionError on failure

        if injection_manager.injection_performed:
            logger.info("Labels were modified. Restarting Docker Compose stack...")
            # Pass current working directory (which might be working_dir) and the target_file for compose
            if not restart_docker_compose_stack(cwd=os.getcwd(), compose_file=abs_target_file):
                # Error during restart is critical.
                raise LabelInjectionError(f"Failed to restart Docker Compose stack using '{abs_target_file}' after label injection. System may be in an inconsistent state.")
            logger.info("Docker Compose stack restarted successfully after label injection.")
        else:
            logger.info("No labels were modified. Docker Compose stack restart is not required.")

        logger.info("Label injection process completed successfully.")
        return True

    except LabelInjectionError as e:
        error_message = f"Label injection process failed: {str(e)}"
        logger.error(error_message)
        dc_logger.error(error_message) # Also log to dc_logger for Docker context

        if injection_manager and injection_manager.backup_created: # Check if backup was made
            logger.warning("Attempting rollback due to error...")
            if injection_manager.rollback():
                logger.info(f"Rollback successful. '{abs_target_file}' restored from backup.")
                logger.info("Restarting Docker Compose stack with restored configuration...")
                # Pass current working directory and the target_file for compose
                if restart_docker_compose_stack(cwd=os.getcwd(), compose_file=abs_target_file):
                    logger.info("Docker Compose stack restarted with original configuration. System restored.")
                else:
                    logger.error(f"CRITICAL: Rollback of '{abs_target_file}' succeeded, but FAILED to restart Docker Compose stack. Manual intervention required.")
            else:
                logger.error(f"CRITICAL: Rollback from '{abs_backup_file}' FAILED. Manual intervention required to restore '{abs_target_file}'.")
        else:
            logger.error("No backup was created or manager not initialized, cannot rollback automatically.")
        return False
    except Exception as e: # Catch any other unexpected errors
        detailed_error = f"Unexpected error during label injection and restart: {e}\n{traceback.format_exc()}"
        logger.error(detailed_error)
        dc_logger.error(detailed_error)
        # Attempt rollback if possible
        if injection_manager and injection_manager.backup_created:
            logger.warning("Attempting rollback due to unexpected error...")
            # (Same rollback logic as above)
            if injection_manager.rollback():
                logger.info("Rollback successful.")
                if restart_docker_compose_stack(cwd=os.getcwd(), compose_file=abs_target_file):
                    logger.info("System restored after unexpected error.")
                else:
                    logger.error("CRITICAL: Rollback succeeded but FAILED to restart stack after unexpected error.")
            else:
                logger.error("CRITICAL: Rollback FAILED after unexpected error.")
        return False
    finally:
        if original_cwd:
            os.chdir(original_cwd)
            logger.info(f"Restored original working directory: {original_cwd}")
