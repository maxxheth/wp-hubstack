"""
Container Discovery and Dynamic Label Injection

This module discovers running Docker containers, maps their filesystem locations,
and dynamically injects CrowdSec bouncer labels into their docker-compose.yml files.
"""

import os
import re
import subprocess
import yaml
from typing import Dict, List, Tuple, Optional
from dataclasses import dataclass

from logger_setup import logger
from utils import load_yaml_file, save_yaml_file


@dataclass
class ContainerInfo:
    """Information about a discovered Docker container."""
    id: str
    name: str
    root_dir: str  # MergedDir from GraphDriver
    log_path: str
    mounts: List[Dict[str, str]]  # Source -> Destination mappings
    compose_file_path: Optional[str] = None  # Path to docker-compose.yml if found


class ContainerDiscovery:
    """
    Discovers running Docker containers and their filesystem locations.
    """
    
    def __init__(self, filter_pattern: str = r"^wp_"):
        """
        Initialize container discovery.
        
        Args:
            filter_pattern: Regex pattern to filter container names (default: wp_ prefix)
        """
        self.filter_pattern = filter_pattern
        self.containers: Dict[str, ContainerInfo] = {}
    
    def discover_containers(self) -> Dict[str, ContainerInfo]:
        """
        Discover running containers and their locations.
        
        Returns:
            Dictionary mapping container names to ContainerInfo objects
        """
        logger.info("Starting container discovery process...")
        
        # Get container IDs and names from docker ps
        containers = self._get_docker_ps_output()
        if not containers:
            logger.warning("No containers found from docker ps")
            return {}
        
        # Filter containers based on pattern
        filtered_containers = self._filter_containers(containers)
        if not filtered_containers:
            logger.warning(f"No containers match filter pattern: {self.filter_pattern}")
            return {}
        
        # Get detailed information for each container
        for container_id, container_name in filtered_containers.items():
            try:
                container_info = self._inspect_container(container_id, container_name)
                if container_info:
                    # Try to find docker-compose.yml file
                    container_info.compose_file_path = self._find_compose_file(container_info)
                    self.containers[container_name] = container_info
                    logger.info(f"Discovered container: {container_name} at {container_info.root_dir}")
            except Exception as e:
                logger.error(f"Failed to inspect container {container_name} ({container_id}): {e}")
        
        logger.info(f"Container discovery complete. Found {len(self.containers)} matching containers.")
        return self.containers
    
    def _get_docker_ps_output(self) -> Dict[str, str]:
        """
        Get container IDs and names from docker ps.
        
        Returns:
            Dictionary mapping container_id -> container_name
        """
        try:
            result = subprocess.run(
                ["docker", "ps", "--format", "{{.ID}}\t{{.Names}}"],
                capture_output=True,
                text=True,
                timeout=30
            )
            
            if result.returncode != 0:
                logger.error(f"docker ps failed: {result.stderr}")
                return {}
            
            containers = {}
            for line in result.stdout.strip().split('\n'):
                if line.strip():
                    parts = line.strip().split('\t')
                    if len(parts) == 2:
                        container_id, container_name = parts
                        containers[container_id] = container_name
            
            logger.debug(f"Found {len(containers)} running containers")
            return containers
            
        except subprocess.TimeoutExpired:
            logger.error("docker ps command timed out")
            return {}
        except Exception as e:
            logger.error(f"Error running docker ps: {e}")
            return {}
    
    def _filter_containers(self, containers: Dict[str, str]) -> Dict[str, str]:
        """
        Filter containers by name pattern.
        
        Args:
            containers: Dictionary mapping container_id -> container_name
            
        Returns:
            Filtered dictionary of containers
        """
        filtered = {}
        pattern = re.compile(self.filter_pattern)
        
        for container_id, container_name in containers.items():
            if pattern.match(container_name):
                filtered[container_id] = container_name
                logger.debug(f"Container {container_name} matches filter pattern")
            else:
                logger.debug(f"Container {container_name} does not match filter pattern")
        
        return filtered
    
    def _inspect_container(self, container_id: str, container_name: str) -> Optional[ContainerInfo]:
        """
        Inspect container to get filesystem locations.
        
        Args:
            container_id: Docker container ID
            container_name: Docker container name
            
        Returns:
            ContainerInfo object or None if inspection fails
        """
        try:
            # Get container inspection data
            result = subprocess.run(
                ["docker", "inspect", container_id],
                capture_output=True,
                text=True,
                timeout=30
            )
            
            if result.returncode != 0:
                logger.error(f"docker inspect failed for {container_name}: {result.stderr}")
                return None
            
            import json
            inspect_data = json.loads(result.stdout)[0]
            
            # Extract filesystem locations
            root_dir = inspect_data.get("GraphDriver", {}).get("Data", {}).get("MergedDir", "")
            log_path = inspect_data.get("LogPath", "")
            
            # Extract mount information
            mounts = []
            for mount in inspect_data.get("Mounts", []):
                if mount.get("Type") == "bind":
                    mounts.append({
                        "source": mount.get("Source", ""),
                        "destination": mount.get("Destination", ""),
                        "mode": mount.get("Mode", "")
                    })
            
            return ContainerInfo(
                id=container_id,
                name=container_name,
                root_dir=root_dir,
                log_path=log_path,
                mounts=mounts
            )
            
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse docker inspect output for {container_name}: {e}")
            return None
        except subprocess.TimeoutExpired:
            logger.error(f"docker inspect timed out for {container_name}")
            return None
        except Exception as e:
            logger.error(f"Error inspecting container {container_name}: {e}")
            return None
    
    def _find_compose_file(self, container_info: ContainerInfo) -> Optional[str]:
        """
        Find docker-compose.yml file for the container.
        
        Args:
            container_info: Container information
            
        Returns:
            Path to docker-compose.yml file or None if not found
        """
        # Check mount points for docker-compose.yml
        for mount in container_info.mounts:
            source_dir = mount["source"]
            if os.path.isdir(source_dir):
                for compose_filename in ["docker-compose.yml", "docker-compose.yaml"]:
                    compose_path = os.path.join(source_dir, compose_filename)
                    if os.path.isfile(compose_path):
                        logger.debug(f"Found compose file for {container_info.name}: {compose_path}")
                        return compose_path
        
        # If not found in mounts, try to infer from container name (common pattern)
        # Look for directories with similar names to container
        container_base_name = container_info.name.replace("wp_", "").replace("_", ".")
        potential_dirs = [
            f"/var/www/{container_base_name}",
            f"/opt/{container_base_name}",
            f"/var/opt/{container_base_name}"
        ]
        
        for potential_dir in potential_dirs:
            if os.path.isdir(potential_dir):
                for compose_filename in ["docker-compose.yml", "docker-compose.yaml"]:
                    compose_path = os.path.join(potential_dir, compose_filename)
                    if os.path.isfile(compose_path):
                        logger.debug(f"Found compose file by inference for {container_info.name}: {compose_path}")
                        return compose_path
        
        logger.warning(f"Could not find docker-compose.yml for container {container_info.name}")
        return None


class DynamicLabelInjector:
    """
    Dynamically injects CrowdSec bouncer labels into docker-compose.yml files.
    """
    
    def __init__(self, backup_suffix: str = ".bak_crowdsec_labels"):
        """
        Initialize label injector.
        
        Args:
            backup_suffix: Suffix for backup files
        """
        self.backup_suffix = backup_suffix
    
    def inject_crowdsec_labels(self, containers: Dict[str, ContainerInfo], 
                              dry_run: bool = False) -> bool:
        """
        Inject CrowdSec bouncer labels into container docker-compose.yml files.
        
        Args:
            containers: Dictionary of container information
            dry_run: If True, only simulate the injection
            
        Returns:
            True if all injections successful, False otherwise
        """
        if not containers:
            logger.warning("No containers provided for label injection")
            return False
        
        success_count = 0
        total_count = len(containers)
        
        logger.info(f"Starting CrowdSec label injection for {total_count} containers...")
        
        for container_name, container_info in containers.items():
            if not container_info.compose_file_path:
                logger.warning(f"No docker-compose.yml found for {container_name}, skipping")
                continue
            
            try:
                if self._inject_container_labels(container_name, container_info, dry_run):
                    success_count += 1
                    logger.info(f"Successfully processed labels for {container_name}")
                else:
                    logger.error(f"Failed to process labels for {container_name}")
            except Exception as e:
                logger.error(f"Error processing labels for {container_name}: {e}")
        
        logger.info(f"Label injection complete: {success_count}/{total_count} containers processed successfully")
        return success_count == total_count
    
    def _inject_container_labels(self, container_name: str, container_info: ContainerInfo, 
                                dry_run: bool) -> bool:
        """
        Inject CrowdSec labels for a single container.
        
        Args:
            container_name: Name of the container
            container_info: Container information
            dry_run: If True, only simulate the injection
            
        Returns:
            True if successful, False otherwise
        """
        compose_file = container_info.compose_file_path
        
        if dry_run:
            logger.info(f"[DRY RUN] Would inject CrowdSec labels into {compose_file} for container {container_name}")
            return True
        
        # Create backup
        backup_path = f"{compose_file}{self.backup_suffix}"
        try:
            import shutil
            shutil.copy2(compose_file, backup_path)
            logger.debug(f"Created backup: {backup_path}")
        except Exception as e:
            logger.error(f"Failed to create backup of {compose_file}: {e}")
            return False
        
        try:
            # Load existing docker-compose.yml
            compose_data = load_yaml_file(compose_file)
            if not compose_data:
                logger.error(f"Failed to load compose file: {compose_file}")
                return False
            
            # Inject CrowdSec labels
            if self._add_crowdsec_labels_to_compose(compose_data, container_name):
                # Save updated compose file
                if save_yaml_file(compose_data, compose_file):
                    logger.info(f"Successfully injected CrowdSec labels for {container_name}")
                    return True
                else:
                    logger.error(f"Failed to save updated compose file: {compose_file}")
                    # Restore backup
                    shutil.copy2(backup_path, compose_file)
                    return False
            else:
                logger.warning(f"No changes needed for {container_name} (labels already present)")
                return True
                
        except Exception as e:
            logger.error(f"Error injecting labels for {container_name}: {e}")
            # Restore backup if it exists
            if os.path.exists(backup_path):
                try:
                    import shutil
                    shutil.copy2(backup_path, compose_file)
                    logger.info(f"Restored backup for {compose_file}")
                except Exception as restore_error:
                    logger.error(f"Failed to restore backup: {restore_error}")
            return False
    
    def _add_crowdsec_labels_to_compose(self, compose_data: dict, container_name: str) -> bool:
        """
        Add CrowdSec labels to the compose data structure.
        
        Args:
            compose_data: Docker compose data structure
            container_name: Name of the container
            
        Returns:
            True if labels were added/updated, False if no changes needed
        """
        services = compose_data.get("services", {})
        
        # Find the service that matches the container name
        target_service = None
        for service_name, service_config in services.items():
            # Check if container_name is explicitly set
            if service_config.get("container_name") == container_name:
                target_service = service_name
                break
            # Or if service name matches container name pattern
            if service_name == container_name or f"wp_{service_name}" == container_name:
                target_service = service_name
                break
        
        if not target_service:
            # Try to infer service name from container name
            if container_name.startswith("wp_"):
                potential_service = container_name[3:]  # Remove "wp_" prefix
                if potential_service in services:
                    target_service = potential_service
        
        if not target_service:
            logger.warning(f"Could not find matching service for container {container_name}")
            return False
        
        service_config = services[target_service]
        
        # Ensure labels section exists
        if "labels" not in service_config:
            service_config["labels"] = {}
        
        labels = service_config["labels"]
        
        # Define the CrowdSec bouncer label
        crowdsec_label_key = f"traefik.http.routers.{container_name}.middlewares"
        crowdsec_label_value = "crowdsec-bouncer@docker"
        
        # Check if label already exists
        if crowdsec_label_key in labels and labels[crowdsec_label_key] == crowdsec_label_value:
            logger.debug(f"CrowdSec label already present for {container_name}")
            return False
        
        # Add/update the label
        labels[crowdsec_label_key] = crowdsec_label_value
        logger.debug(f"Added CrowdSec label: {crowdsec_label_key}={crowdsec_label_value}")
        
        return True


class ContainerBasedTester:
    """
    Extends CrowdSec testing to work with discovered containers.
    """
    
    def __init__(self, discovery: ContainerDiscovery):
        """
        Initialize container-based tester.
        
        Args:
            discovery: ContainerDiscovery instance with discovered containers
        """
        self.discovery = discovery
        self.containers = discovery.containers
    
    def test_discovered_containers(self, dry_run: bool = False, 
                                  spreadsheet_id: str = "", 
                                  credentials_file: str = "") -> Dict[str, bool]:
        """
        Test CrowdSec integration for all discovered containers.
        
        Args:
            dry_run: If True, simulate testing
            spreadsheet_id: Google Sheets ID for logging
            credentials_file: Google credentials file
            
        Returns:
            Dictionary mapping container_name -> test_result (bool)
        """
        if not self.containers:
            logger.warning("No containers discovered for testing")
            return {}
        
        results = {}
        logger.info(f"Starting CrowdSec integration tests for {len(self.containers)} containers...")
        
        for container_name, container_info in self.containers.items():
            logger.info(f"Testing container: {container_name}")
            
            if dry_run:
                logger.info(f"[DRY RUN] Would test CrowdSec integration for {container_name}")
                results[container_name] = True
            else:
                # Import here to avoid circular imports
                from crowdsec_tester import run_crowdsec_integration_tests
                
                # For now, use the existing test suite
                # In the future, this could be extended to test specific container endpoints
                test_result = run_crowdsec_integration_tests(
                    dry_run=dry_run,
                    spreadsheet_id=spreadsheet_id,
                    credentials_file=credentials_file
                )
                results[container_name] = test_result
                
                if test_result:
                    logger.info(f"CrowdSec integration test PASSED for {container_name}")
                else:
                    logger.error(f"CrowdSec integration test FAILED for {container_name}")
        
        return results


def discover_and_inject_crowdsec_labels(filter_pattern: str = r"^wp_", 
                                       dry_run: bool = False) -> bool:
    """
    Main function to discover containers and inject CrowdSec labels.
    
    Args:
        filter_pattern: Regex pattern to filter container names
        dry_run: If True, simulate the process
        
    Returns:
        True if successful, False otherwise
    """
    try:
        # Discover containers
        discovery = ContainerDiscovery(filter_pattern)
        containers = discovery.discover_containers()
        
        if not containers:
            logger.warning("No matching containers found for CrowdSec label injection")
            return False
        
        # Inject labels
        injector = DynamicLabelInjector()
        success = injector.inject_crowdsec_labels(containers, dry_run)
        
        if success:
            logger.info("CrowdSec label injection completed successfully")
        else:
            logger.error("CrowdSec label injection completed with errors")
        
        return success
        
    except Exception as e:
        logger.error(f"Error in discover_and_inject_crowdsec_labels: {e}")
        return False


if __name__ == "__main__":
    # Test the container discovery functionality
    import argparse
    
    parser = argparse.ArgumentParser(description="Discover containers and inject CrowdSec labels")
    parser.add_argument("--filter", default=r"^wp_", help="Container name filter pattern")
    parser.add_argument("--dry-run", action="store_true", help="Simulate the process")
    
    args = parser.parse_args()
    
    success = discover_and_inject_crowdsec_labels(args.filter, args.dry_run)
    exit(0 if success else 1)