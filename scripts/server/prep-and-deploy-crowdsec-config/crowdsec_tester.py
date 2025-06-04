# crowdsec_tester.py

"""
Functions for running CrowdSec integration tests with Traefik.
"""

import time
import requests
import urllib3 # For disabling SSL warnings if needed
import subprocess
import json
import re
from typing import Tuple, Dict, Optional, List

from logger_setup import logger
from crowdsec_client import cs_ban_ip, cs_unban_ip # Specific functions needed from client
from error_handler import log_error_to_google_sheets # For logging test failures to Sheets

from config import (
    TRAEFIK_SCHEME, TRAEFIK_HOST, TRAEFIK_PORT, TEST_SERVICE_PATH,
    TEST_IP_TO_BAN,
    EXPECTED_STATUS_ALLOWED, EXPECTED_STATUS_BLOCKED,
    BOUNCER_SYNC_DELAY_SECONDS, REQUEST_TIMEOUT, VERIFY_SSL,
    CROWDSEC_LAPI_CONTAINER_NAME # For context in logs
)

# Disable SSL warnings for self-signed certificates in testing if VERIFY_SSL is False
if not VERIFY_SSL:
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ================================
# CONTAINER DISCOVERY
# ================================

def discover_containers(filter_pattern: str = r"^wp_") -> List[str]:
    """
    Discover running containers using docker ps and filter by pattern.
    
    Args:
        filter_pattern: Regex pattern to filter container names
        
    Returns:
        List of container names matching the filter
    """
    try:
        # Run docker ps to get running containers
        result = subprocess.run(
            ["docker", "ps", "--format", "{{.Names}}"],
            capture_output=True,
            text=True,
            check=True
        )
        
        all_containers = result.stdout.strip().split('\n')
        if not all_containers or all_containers == ['']:
            logger.warning("No running containers found")
            return []
        
        # Filter containers by pattern
        pattern = re.compile(filter_pattern)
        filtered_containers = [name for name in all_containers if pattern.match(name)]
        
        logger.info(f"Discovered {len(filtered_containers)} containers matching pattern '{filter_pattern}': {filtered_containers}")
        return filtered_containers
        
    except subprocess.CalledProcessError as e:
        logger.error(f"Failed to discover containers: {e}")
        return []
    except Exception as e:
        logger.error(f"Error during container discovery: {e}")
        return []

# ================================
# DOCKER CONTAINER INSPECTION
# ================================

def get_container_host_headers(container_name: str) -> List[str]:
    """
    Get host headers for a container by inspecting its Traefik labels.
    
    Args:
        container_name: Name of the container to inspect
        
    Returns:
        List of host headers found in Traefik labels
    """
    try:
        # Run docker inspect to get container labels
        result = subprocess.run(
            ["docker", "inspect", container_name],
            capture_output=True,
            text=True,
            check=True
        )
        
        container_info = json.loads(result.stdout)[0]
        labels = container_info.get("Config", {}).get("Labels", {})
        
        host_headers = []
        
        # Look for Traefik host rule labels
        for label_key, label_value in labels.items():
            if "traefik.http.routers" in label_key and "rule" in label_key:
                # Extract Host() rules from Traefik labels
                if "Host(" in label_value:
                    # Parse Host(`example.com`) or Host(`example.com`,`www.example.com`)
                    hosts = re.findall(r'Host\(`([^`]+)`\)', label_value)
                    host_headers.extend(hosts)
        
        # Remove duplicates while preserving order
        unique_hosts = []
        for host in host_headers:
            if host not in unique_hosts:
                unique_hosts.append(host)
        
        logger.info(f"Found {len(unique_hosts)} host headers for container {container_name}: {unique_hosts}")
        return unique_hosts
        
    except subprocess.CalledProcessError as e:
        logger.error(f"Failed to inspect container {container_name}: {e}")
        return []
    except (json.JSONDecodeError, KeyError, IndexError) as e:
        logger.error(f"Failed to parse container inspect output for {container_name}: {e}")
        return []

# ================================
# CROWDSEC BAN/UNBAN WRAPPERS (from original script, now using crowdsec_client)
# ================================

def _ban_test_ip(reason="Automated Test Ban", duration="1m") -> bool: # Shorter duration for tests
    """Ban the predefined TEST_IP_TO_BAN."""
    logger.info(f"Attempting to ban test IP: {TEST_IP_TO_BAN} for {duration} with reason: '{reason}'")
    # cs_ban_ip from crowdsec_client handles logging and printing
    success = cs_ban_ip(TEST_IP_TO_BAN, reason, duration, print_output=True)
    if success:
        logger.info(f"Successfully initiated ban for IP: {TEST_IP_TO_BAN}")
    else:
        logger.error(f"Failed to initiate ban for IP: {TEST_IP_TO_BAN}")
    return success

def _unban_test_ip() -> bool:
    """Unban the predefined TEST_IP_TO_BAN."""
    logger.info(f"Attempting to unban test IP: {TEST_IP_TO_BAN}")
    # cs_unban_ip from crowdsec_client handles logging and printing
    success = cs_unban_ip(TEST_IP_TO_BAN, print_output=True)
    if success:
        logger.info(f"Successfully processed unban for IP: {TEST_IP_TO_BAN} (may include 'no active decision').")
    else:
        logger.error(f"Failed to process unban for IP: {TEST_IP_TO_BAN}")
    return success

# ================================
# SERVICE ACCESS CHECK
# ================================

def check_test_service_access(host_header: str, 
                             custom_path: Optional[str] = None,
                             simulate_ip: Optional[str] = None) -> Tuple[int, str]:
    """
    Check access to the test service by making a request to the actual public URL.
    
    Args:
        host_header: Host header for routing (the actual domain to test)
        custom_path: Override the default TEST_SERVICE_PATH
        simulate_ip: IP to simulate via X-Forwarded-For header
        
    Returns:
        Tuple of (HTTP status code, response text snippet or error message).
                 Status code is -1 on request failure.
    """
    service_path = custom_path or TEST_SERVICE_PATH
    
    url = f"https://{host_header}{service_path}"
    headers = {
        "User-Agent": "CrowdSecIntegrationTester/1.4"
    }
    
    # Add X-Forwarded-For header to simulate requests from the banned IP
    if simulate_ip:
        headers["X-Forwarded-For"] = simulate_ip
        headers["X-Real-IP"] = simulate_ip

    logger.info(f"Making test request to public URL: {url}" + 
                (f" (simulating IP: {simulate_ip})" if simulate_ip else ""))

    try:
        response = requests.get(
            url,
            headers=headers,
            timeout=REQUEST_TIMEOUT,
            verify=VERIFY_SSL,
            allow_redirects=True
        )
        status_code = response.status_code
        # Get a snippet of the response text for logging, especially for errors
        response_snippet = response.text[:200].replace('\n', ' ') + ('...' if len(response.text) > 200 else '')
        logger.info(f"Test request to {url} completed. Status: {status_code}. Response snippet: '{response_snippet}'")
        return status_code, response_snippet

    except requests.exceptions.Timeout:
        logger.error(f"Test request to {url} TIMED OUT after {REQUEST_TIMEOUT} seconds.")
        return -1, "Request Timed Out"
    except requests.exceptions.ConnectionError as ce:
        logger.error(f"Test request to {url} FAILED due to Connection Error: {ce}")
        return -1, f"Connection Error: {ce}"
    except requests.exceptions.RequestException as e:
        logger.error(f"Test request to {url} FAILED with an unexpected error: {e}")
        return -1, f"Request Exception: {e}"

# ================================
# CONTAINER-SPECIFIC TESTING
# ================================

def check_container_service_access(container_name: str, simulate_ip: Optional[str] = None) -> List[Tuple[str, int, str]]:
    """
    Check access to a specific container's service through Traefik for all its host headers.
    
    Args:
        container_name: Name of the container to test
        simulate_ip: IP to simulate for CrowdSec testing
        
    Returns:
        List of tuples: (host_header, status_code, response_snippet)
    """
    host_headers = get_container_host_headers(container_name)
    
    if not host_headers:
        logger.warning(f"No host headers found for container {container_name}")
        return []
    
    results = []
    for host_header in host_headers:
        sim_text = f" (simulating IP: {simulate_ip})" if simulate_ip else ""
        logger.info(f"Testing container {container_name} with host header: {host_header}{sim_text}")
        status_code, response_snippet = check_test_service_access(host_header, simulate_ip=simulate_ip)
        results.append((host_header, status_code, response_snippet))
    
    return results

# ================================
# TEST RESULT FORMATTING
# ================================

def _print_test_step_result(test_name: str, expected_status: int, actual_results: List[Tuple[str, int, str]], step_number: int) -> bool:
    """Prints formatted result for a single test step and logs it."""
    all_passed = True
    
    console_lines = [
        f"\n--- Test Step {step_number}: {test_name} ---"
    ]
    
    for host_header, actual_status, response_snippet in actual_results:
        passed = (expected_status == actual_status)
        result_status_text = "PASSED" if passed else "FAILED"
        
        console_lines.extend([
            f"  Host: {host_header}",
            f"    Expected HTTP Status: {expected_status}",
            f"    Actual HTTP Status  : {actual_status}",
            f"    Result              : {result_status_text}"
        ])
        
        if not passed:
            all_passed = False
            console_lines.append(f"    Response: {response_snippet}")
        
        log_message = (f"Test Step {step_number} ({test_name}) Host {host_header}: "
                      f"Expected={expected_status}, Actual={actual_status} -> {result_status_text}")
        
        if passed:
            logger.info(log_message)
        else:
            logger.error(log_message)
    
    console_lines.append(f"--- End Test Step {step_number} ---")
    print("\n".join(console_lines))
    
    return all_passed

# ================================
# CONTAINER-SPECIFIC TEST SUITE
# ================================

def run_crowdsec_container_tests(container_name: str,
                                dry_run: bool = False,
                                spreadsheet_id: str = "",
                                credentials_file: str = "") -> bool:
    """
    Run CrowdSec integration tests for a specific container.
    
    Args:
        container_name: Name of the container to test
        dry_run: If True, simulate testing
        spreadsheet_id: Google Sheets ID for logging
        credentials_file: Google credentials file
        
    Returns:
        True if all tests passed, False otherwise
    """
    if dry_run:
        logger.info(f"[DRY RUN] Would test CrowdSec integration for container: {container_name}")
        print(f"\n[DRY RUN] CrowdSec integration tests would be executed for container: {container_name}")
        return True

    logger.info(f"Starting CrowdSec integration tests for container: {container_name}")
    
    # Get host headers for this container
    host_headers = get_container_host_headers(container_name)
    if not host_headers:
        logger.error(f"No host headers found for container {container_name}. Cannot run tests.")
        print(f"ERROR: No host headers found for container {container_name}")
        return False
    
    # Test suite header
    header_lines = [
        "\n" + "="*70,
        f"CROWDSEC INTEGRATION TEST FOR CONTAINER: {container_name}",
        "="*70,
        f"  Container Name      : {container_name}",
        f"  Host Headers        : {', '.join(host_headers)}",
        f"  Test IP to Ban/Unban: {TEST_IP_TO_BAN}",
        f"  CrowdSec LAPI Cont. : {CROWDSEC_LAPI_CONTAINER_NAME}",
        f"  Bouncer Sync Delay  : {BOUNCER_SYNC_DELAY_SECONDS} seconds",
        "="*70
    ]
    print("\n".join(header_lines))

    test_step_results = []

    try:
        # Initial cleanup
        print(f"\nPHASE: Initial Cleanup for {container_name}")
        _unban_test_ip()
        time.sleep(BOUNCER_SYNC_DELAY_SECONDS)

        # Test Step 1: Access allowed (no ban)
        results_step1 = check_container_service_access(container_name)
        passed_step1 = _print_test_step_result(f"Access Unrestricted ({container_name})",
                                              EXPECTED_STATUS_ALLOWED, results_step1, 1)
        
        if not passed_step1:
            logger.warning(f"Initial access test failed for {container_name}. This may indicate routing issues.")

        # Ban test IP
        print(f"\nPHASE: Banning Test IP for {container_name} tests")
        ban_initiated = _ban_test_ip(reason=f"Test ban for {container_name}")
        
        if ban_initiated:
            time.sleep(BOUNCER_SYNC_DELAY_SECONDS)
            
            # Test Step 2: Access blocked (ban active) - simulate requests from banned IP
            results_step2 = check_container_service_access(container_name, simulate_ip=TEST_IP_TO_BAN)
            passed_step2 = _print_test_step_result(f"Access Blocked ({container_name})",
                                                  EXPECTED_STATUS_BLOCKED, results_step2, 2)
        
            if not passed_step2:
                logger.error(f"Block test failed for {container_name}")
                if spreadsheet_id and credentials_file:
                    failed_hosts = [host for host, status, _ in results_step2 if status != EXPECTED_STATUS_BLOCKED]
                    log_error_to_google_sheets(spreadsheet_id, credentials_file,
                                             f"CrowdSec Test FAIL ({container_name}): Step 2 - Failed hosts: {failed_hosts}",
                                             dry_run)

        # Unban test IP
        print(f"\nPHASE: Unbanning Test IP for {container_name}")
        _unban_test_ip()
        time.sleep(BOUNCER_SYNC_DELAY_SECONDS)

        # Test Step 3: Access restored (after unban) - simulate requests from previously banned IP
        results_step3 = check_container_service_access(container_name, simulate_ip=TEST_IP_TO_BAN)
        passed_step3 = _print_test_step_result(f"Access Restored ({container_name})",
                                              EXPECTED_STATUS_ALLOWED, results_step3, 3)
        test_step_results.append((f"Step 3: Access Restored ({container_name})", passed_step3))

        if not passed_step3:
            logger.error(f"Restore test failed for {container_name}")
            if spreadsheet_id and credentials_file:
                failed_hosts = [host for host, status, _ in results_step3 if status != EXPECTED_STATUS_ALLOWED]
                log_error_to_google_sheets(spreadsheet_id, credentials_file,
                                         f"CrowdSec Test FAIL ({container_name}): Step 3 - Failed hosts: {failed_hosts}",
                                         dry_run)

        overall_passed = all(passed for _, passed in test_step_results)
        return overall_passed

    except Exception as e:
        logger.error(f"Error during CrowdSec tests for {container_name}: {e}")
        _unban_test_ip()  # Cleanup
        return False
    finally:
        # Test summary for this container
        summary_lines = [
            f"\n--- TEST SUMMARY FOR {container_name} ---",
            f"Container: {container_name}"
        ]
        
        all_passed = True
        for description, passed_flag in test_step_results:
            summary_lines.append(f"  {description}: {'PASSED' if passed_flag else 'FAILED'}")
            if not passed_flag:
                all_passed = False
        
        summary_lines.append(f"Overall Result for {container_name}: {'PASSED' if all_passed else 'FAILED'}")
        summary_lines.append("-" * (len(f"TEST SUMMARY FOR {container_name}") + 6))
        
        print("\n".join(summary_lines))
        logger.info(f"CrowdSec integration tests completed for {container_name}: {'PASSED' if all_passed else 'FAILED'}")

# ================================
# MAIN INTEGRATION TEST SUITE (Enhanced with auto-discovery)
# ================================

def run_crowdsec_integration_tests(
    dry_run: bool = False,
    # For logging failures to Google Sheets
    spreadsheet_id: str = "",
    credentials_file: str = "",
    # Container discovery filter
    container_filter: str = r"^wp_"
) -> bool:
    """
    Run the complete CrowdSec + Traefik bouncer integration test suite.
    Auto-discovers containers using docker ps and the provided filter pattern.
    
    Args:
        dry_run: If True, simulate testing
        spreadsheet_id: Google Sheets ID for logging
        credentials_file: Google credentials file
        container_filter: Regex pattern to filter container names for testing
        
    Returns:
        True if all tests passed, False otherwise
    """
    # Auto-discover containers
    container_names = discover_containers(container_filter)
    
    if not container_names:
        logger.warning(f"No containers found matching filter pattern '{container_filter}'")
        print(f"No containers found matching filter pattern '{container_filter}'")
        return True  # Return True since no containers to test is not a failure
    
    # Test discovered containers
    logger.info(f"Running CrowdSec tests for {len(container_names)} discovered containers: {container_names}")
    print(f"\nDiscovered {len(container_names)} containers for testing: {container_names}")
    
    all_results = []
    for container_name in container_names:
        result = run_crowdsec_container_tests(
            container_name=container_name,
            dry_run=dry_run,
            spreadsheet_id=spreadsheet_id,
            credentials_file=credentials_file
        )
        all_results.append(result)
    
    # Overall results summary
    passed_count = sum(1 for result in all_results if result)
    total_count = len(all_results)
    overall_success = all(all_results)
    
    summary_lines = [
        "\n" + "="*70,
        "OVERALL CROWDSEC INTEGRATION TEST SUMMARY",
        "="*70,
        f"  Containers Tested   : {total_count}",
        f"  Containers Passed   : {passed_count}",
        f"  Containers Failed   : {total_count - passed_count}",
        f"  Overall Result      : {'PASSED' if overall_success else 'FAILED'}",
        "="*70
    ]
    
    print("\n".join(summary_lines))
    logger.info(f"Container-specific CrowdSec tests completed. Overall result: {passed_count}/{total_count} passed ({'PASSED' if overall_success else 'FAILED'})")
    
    return overall_success
