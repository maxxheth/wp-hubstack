"""
Manages safe tarball extraction and deployment to Docker containers with backup and rollback.
"""

import os
import shutil
import tarfile
import traceback
import tempfile
from typing import List, Optional, Tuple
from pathlib import Path

from logger_setup import logger, dc_logger
from config import DEFAULT_TARGET_CONFIG, DEFAULT_TRAEFIK_DIR, DEFAULT_CROWDSEC_TARBALLS_DIR
from docker_utils import restart_docker_compose_stack


class TarballInjectionError(Exception):
    """Custom exception for tarball injection errors."""
    pass


class TarballInjectionManager:
    """Manages safe tarball extraction with backup and rollback capability."""

    def __init__(self, target_config_file: str, tarballs_dir: str, target_container: str):
        self.target_config_file = os.path.abspath(target_config_file)
        self.target_dir = os.path.dirname(self.target_config_file)
        self.tarballs_dir = os.path.abspath(tarballs_dir)
        self.target_container = target_container
        self.backup_dir = None
        self.backup_created = False
        self.extraction_performed = False
        self.extracted_files = []  # Track files that were extracted

    def _get_backup_dir(self) -> str:
        """Generate a unique backup directory name."""
        if not self.backup_dir:
            timestamp = str(int(os.times().elapsed * 1000))  # Use high-resolution timestamp
            self.backup_dir = os.path.join(self.target_dir, f".tarball_backup_{timestamp}")
        return self.backup_dir

    def create_backup(self) -> bool:
        """Create a backup of existing files that might be overwritten."""
        try:
            backup_dir = self._get_backup_dir()
            
            # Get list of files that would be extracted
            files_to_extract = self._get_files_from_tarballs()
            if not files_to_extract:
                logger.info("No files to extract from tarballs, backup not needed.")
                return True

            # Create backup directory
            os.makedirs(backup_dir, exist_ok=True)
            
            backed_up_files = 0
            for file_path in files_to_extract:
                target_file = os.path.join(self.target_dir, file_path)
                if os.path.exists(target_file):
                    backup_file = os.path.join(backup_dir, file_path)
                    backup_file_dir = os.path.dirname(backup_file)
                    os.makedirs(backup_file_dir, exist_ok=True)
                    
                    shutil.copy2(target_file, backup_file)
                    backed_up_files += 1
                    logger.debug(f"Backed up '{target_file}' to '{backup_file}'")

            self.backup_created = True
            logger.info(f"Backup created at '{backup_dir}' with {backed_up_files} files backed up.")
            return True

        except Exception as e:
            raise TarballInjectionError(f"Failed to create backup: {e}")

    def rollback(self) -> bool:
        """Rollback by restoring files from backup."""
        if not self.backup_created or not self.backup_dir or not os.path.exists(self.backup_dir):
            logger.error("Cannot rollback: no backup available.")
            return False

        try:
            restored_files = 0
            # Walk through backup directory and restore files
            for root, dirs, files in os.walk(self.backup_dir):
                for file in files:
                    backup_file = os.path.join(root, file)
                    relative_path = os.path.relpath(backup_file, self.backup_dir)
                    target_file = os.path.join(self.target_dir, relative_path)
                    
                    # Ensure target directory exists
                    target_file_dir = os.path.dirname(target_file)
                    os.makedirs(target_file_dir, exist_ok=True)
                    
                    shutil.copy2(backup_file, target_file)
                    restored_files += 1
                    logger.debug(f"Restored '{backup_file}' to '{target_file}'")

            # Remove extracted files that weren't in backup (newly created files)
            for extracted_file in self.extracted_files:
                extracted_path = os.path.join(self.target_dir, extracted_file)
                backup_path = os.path.join(self.backup_dir, extracted_file)
                if os.path.exists(extracted_path) and not os.path.exists(backup_path):
                    try:
                        os.remove(extracted_path)
                        logger.debug(f"Removed newly extracted file '{extracted_path}'")
                    except Exception as e:
                        logger.warning(f"Failed to remove extracted file '{extracted_path}': {e}")

            logger.info(f"Rollback successful: restored {restored_files} files from backup.")
            return True

        except Exception as e:
            logger.error(f"Rollback failed: {e}")
            return False

    def _get_files_from_tarballs(self) -> List[str]:
        """Get list of files that would be extracted from all tarballs."""
        files_list = []
        
        if not os.path.exists(self.tarballs_dir):
            return files_list

        try:
            for filename in os.listdir(self.tarballs_dir):
                if filename.endswith(('.tar', '.tar.gz', '.tgz', '.tar.bz2', '.tar.xz')):
                    tarball_path = os.path.join(self.tarballs_dir, filename)
                    try:
                        with tarfile.open(tarball_path, 'r:*') as tar:
                            for member in tar.getmembers():
                                if member.isfile():
                                    files_list.append(member.name)
                    except Exception as e:
                        logger.warning(f"Failed to read tarball '{filename}': {e}")
                        
        except Exception as e:
            logger.error(f"Failed to scan tarballs directory: {e}")
            
        return files_list

    def extract_tarballs(self) -> bool:
        """Extract all tarballs from the tarballs directory to the target directory."""
        try:
            if not os.path.exists(self.tarballs_dir):
                raise TarballInjectionError(f"Tarballs directory '{self.tarballs_dir}' does not exist.")

            tarball_files = [f for f in os.listdir(self.tarballs_dir) 
                           if f.endswith(('.tar', '.tar.gz', '.tgz', '.tar.bz2', '.tar.xz'))]
            
            if not tarball_files:
                logger.info(f"No tarball files found in '{self.tarballs_dir}'.")
                return True

            extracted_count = 0
            total_files_extracted = 0

            for tarball_file in tarball_files:
                tarball_path = os.path.join(self.tarballs_dir, tarball_file)
                logger.info(f"Extracting tarball: {tarball_file}")

                try:
                    with tarfile.open(tarball_path, 'r:*') as tar:
                        # Validate tarball contents for security
                        members = tar.getmembers()
                        for member in members:
                            # Security check: prevent path traversal
                            if os.path.isabs(member.name) or ".." in member.name:
                                raise TarballInjectionError(f"Unsafe path in tarball '{tarball_file}': {member.name}")

                        # Extract tarball
                        tar.extractall(path=self.target_dir)
                        
                        # Track extracted files
                        file_count = 0
                        for member in members:
                            if member.isfile():
                                self.extracted_files.append(member.name)
                                file_count += 1
                        
                        total_files_extracted += file_count
                        extracted_count += 1
                        logger.info(f"Successfully extracted '{tarball_file}' ({file_count} files)")

                except Exception as e:
                    raise TarballInjectionError(f"Failed to extract tarball '{tarball_file}': {e}")

            if extracted_count > 0:
                self.extraction_performed = True
                logger.info(f"Successfully extracted {extracted_count} tarballs ({total_files_extracted} total files) to '{self.target_dir}'")
            else:
                logger.info("No tarballs were extracted.")

            return True

        except TarballInjectionError:
            raise  # Re-raise custom errors
        except Exception as e:
            detailed_error = f"Unexpected error during tarball extraction: {e}\n{traceback.format_exc()}"
            logger.error(detailed_error)
            raise TarballInjectionError(detailed_error)

    def cleanup_backup(self) -> bool:
        """Remove the backup directory after successful deployment."""
        if not self.backup_created or not self.backup_dir or not os.path.exists(self.backup_dir):
            return True

        try:
            shutil.rmtree(self.backup_dir)
            logger.info(f"Backup directory '{self.backup_dir}' cleaned up successfully.")
            return True
        except Exception as e:
            logger.warning(f"Failed to cleanup backup directory '{self.backup_dir}': {e}")
            return False


def inject_tarballs_with_restart(target_config_file: str = None,
                               tarballs_dir: str = None,
                               target_container: str = None,
                               working_dir: str = None,
                               dry_run: bool = False,
                               cleanup_backup: bool = True) -> bool:
    """
    Safely extract tarballs and restart the specified container.
    
    Args:
        target_config_file: Path to docker-compose.yml file
        tarballs_dir: Directory containing tarballs to extract
        target_container: Container name to restart
        working_dir: Working directory for operations
        dry_run: If True, only simulate the operation
        cleanup_backup: If True, remove backup after successful deployment
    """
    # Set defaults
    target_config_file = target_config_file or DEFAULT_TARGET_CONFIG
    tarballs_dir = tarballs_dir or DEFAULT_CROWDSEC_TARBALLS_DIR
    target_container = target_container or DEFAULT_TRAEFIK_DIR

    original_cwd = None
    if working_dir:
        original_cwd = os.getcwd()
        try:
            os.chdir(working_dir)
            logger.info(f"Changed working directory to: {working_dir}")
        except FileNotFoundError:
            logger.error(f"Working directory '{working_dir}' not found.")
            if original_cwd:
                os.chdir(original_cwd)
            return False
        except Exception as e:
            logger.error(f"Error changing to working directory '{working_dir}': {e}")
            if original_cwd:
                os.chdir(original_cwd)
            return False

    # Resolve absolute paths
    abs_target_config_file = os.path.abspath(target_config_file)
    abs_tarballs_dir = os.path.abspath(tarballs_dir)

    injection_manager = None

    try:
        if dry_run:
            logger.info(f"[DRY RUN] Would extract tarballs from '{abs_tarballs_dir}' to parent directory of '{abs_target_config_file}'")
            logger.info(f"[DRY RUN] Would restart container '{target_container}' using compose file '{abs_target_config_file}'")
            return True

        injection_manager = TarballInjectionManager(abs_target_config_file, abs_tarballs_dir, target_container)

        logger.info(f"Creating backup before tarball extraction...")
        injection_manager.create_backup()

        logger.info(f"Extracting tarballs from '{abs_tarballs_dir}'...")
        injection_manager.extract_tarballs()

        if injection_manager.extraction_performed:
            logger.info(f"Tarballs were extracted. Restarting Docker Compose stack...")
            if not restart_docker_compose_stack(cwd=os.getcwd(), compose_file=abs_target_config_file):
                raise TarballInjectionError(f"Failed to restart Docker Compose stack using '{abs_target_config_file}' after tarball extraction.")
            logger.info("Docker Compose stack restarted successfully after tarball extraction.")
            
            # Cleanup backup if requested and successful
            if cleanup_backup:
                injection_manager.cleanup_backup()
        else:
            logger.info("No tarballs were extracted. Docker Compose stack restart is not required.")

        logger.info("Tarball injection process completed successfully.")
        return True

    except TarballInjectionError as e:
        error_message = f"Tarball injection process failed: {str(e)}"
        logger.error(error_message)
        dc_logger.error(error_message)

        if injection_manager and injection_manager.backup_created:
            logger.warning("Attempting rollback due to error...")
            if injection_manager.rollback():
                logger.info("Rollback successful. Files restored from backup.")
                logger.info("Restarting Docker Compose stack with restored configuration...")
                if restart_docker_compose_stack(cwd=os.getcwd(), compose_file=abs_target_config_file):
                    logger.info("Docker Compose stack restarted with original configuration. System restored.")
                else:
                    logger.error("CRITICAL: Rollback succeeded, but FAILED to restart Docker Compose stack. Manual intervention required.")
            else:
                logger.error("CRITICAL: Rollback FAILED. Manual intervention required to restore system.")
        else:
            logger.error("No backup was created or manager not initialized, cannot rollback automatically.")
        return False

    except Exception as e:
        detailed_error = f"Unexpected error during tarball injection: {e}\n{traceback.format_exc()}"
        logger.error(detailed_error)
        dc_logger.error(detailed_error)

        if injection_manager and injection_manager.backup_created:
            logger.warning("Attempting rollback due to unexpected error...")
            if injection_manager.rollback():
                logger.info("Rollback successful.")
                if restart_docker_compose_stack(cwd=os.getcwd(), compose_file=abs_target_config_file):
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


def list_available_tarballs(tarballs_dir: str = None) -> Tuple[List[str], List[str]]:
    """
    List available tarballs and their contents.
    
    Returns:
        Tuple of (tarball_files, all_files_to_extract)
    """
    tarballs_dir = tarballs_dir or DEFAULT_CROWDSEC_TARBALLS_DIR
    abs_tarballs_dir = os.path.abspath(tarballs_dir)
    
    tarball_files = []
    all_files = []
    
    if not os.path.exists(abs_tarballs_dir):
        logger.warning(f"Tarballs directory '{abs_tarballs_dir}' does not exist.")
        return tarball_files, all_files
    
    try:
        for filename in os.listdir(abs_tarballs_dir):
            if filename.endswith(('.tar', '.tar.gz', '.tgz', '.tar.bz2', '.tar.xz')):
                tarball_files.append(filename)
                tarball_path = os.path.join(abs_tarballs_dir, filename)
                
                try:
                    with tarfile.open(tarball_path, 'r:*') as tar:
                        for member in tar.getmembers():
                            if member.isfile():
                                all_files.append(f"{filename}:{member.name}")
                except Exception as e:
                    logger.warning(f"Failed to read tarball '{filename}': {e}")
                    
    except Exception as e:
        logger.error(f"Failed to scan tarballs directory: {e}")
    
    return tarball_files, all_files