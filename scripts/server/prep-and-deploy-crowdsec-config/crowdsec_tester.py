# crowdsec_tester.py

"""
Functions for running CrowdSec integration tests with Traefik.
"""

import time
import requests
import urllib3 # For disabling SSL warnings if needed
from typing import Tuple, Dict, Optional

from logger_setup import logger
from crowdsec_client import cs_ban_ip, cs_unban_ip # Specific functions needed from client
from error_handler import log_error_to_google_sheets # For logging test failures to Sheets

from config import (
    TRAEFIK_SCHEME, TRAEFIK_HOST, TRAEFIK_PORT, TEST_SERVICE_PATH,
    TEST_SERVICE_HOST_HEADER, TEST_IP_TO_BAN,
    EXPECTED_STATUS_ALLOWED, EXPECTED_STATUS_BLOCKED,
    BOUNCER_SYNC_DELAY_SECONDS, REQUEST_TIMEOUT, VERIFY_SSL,
    CROWDSEC_LAPI_CONTAINER_NAME # For context in logs
)

# Disable SSL warnings for self-signed certificates in testing if VERIFY_SSL is False
if not VERIFY_SSL:
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

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

def check_test_service_access(custom_host_header: Optional[str] = None, 
                             custom_path: Optional[str] = None) -> Tuple[int, str]:
    """
    Check access to the test service through Traefik.
    
    Args:
        custom_host_header: Override the default TEST_SERVICE_HOST_HEADER
        custom_path: Override the default TEST_SERVICE_PATH
        
    Returns:
        Tuple of (HTTP status code, response text snippet or error message).
                 Status code is -1 on request failure.
    """
    host_header = custom_host_header or TEST_SERVICE_HOST_HEADER
    service_path = custom_path or TEST_SERVICE_PATH
    
    url = f"{TRAEFIK_SCHEME}://{TRAEFIK_HOST}:{TRAEFIK_PORT}{service_path}"
    headers = {
        "Host": host_header,
        "User-Agent": "CrowdSecIntegrationTester/1.2" # Updated version
    }

    logger.info(f"Making test request to URL: {url} with Host header: {host_header}")
    # logger.debug(f"Request Headers: {headers}") # Can be verbose

    try:
        response = requests.get(
            url,
            headers=headers,
            timeout=REQUEST_TIMEOUT,
            verify=VERIFY_SSL, # Use config for SSL verification
            allow_redirects=False # Important for testing specific endpoint responses
        )
        status_code = response.status_code
        # Get a snippet of the response text for logging, especially for errors
        response_snippet = response.text[:200].replace('\n', ' ') + ('...' if len(response.text) > 200 else '')
        logger.info(f"Test request to {url} completed. Status: {status_code}. Response snippet: '{response_snippet}'")
        # logger.debug(f"Full response headers: {response.headers}")
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

def check_container_service_access(container_name: str, 
                                  container_info: Optional[Dict] = None) -> Tuple[int, str]:
    """
    Check access to a specific container's service through Traefik.
    
    Args:
        container_name: Name of the container to test
        container_info: Optional container information from discovery
        
    Returns:
        Tuple of (HTTP status code, response text snippet or error message)
    """
    # Convert container name to expected host header
    # For wp_ containers, remove wp_ prefix and convert underscores to dots
    if container_name.startswith("wp_"):
        host_header = container_name[3:].replace("_", ".")
    else:
        host_header = container_name.replace("_", ".")
    
    # Use root path for container testing
    service_path = "/"
    
    logger.info(f"Testing container {container_name} with host header: {host_header}")
    return check_test_service_access(custom_host_header=host_header, 
                                   custom_path=service_path)

# ================================
# TEST RESULT FORMATTING
# ================================

def _print_test_step_result(test_name: str, expected_status: int, actual_status: int, step_number: int) -> bool:
    """Prints formatted result for a single test step and logs it."""
    passed = (expected_status == actual_status)
    result_status_text = "PASSED" if passed else "FAILED"

    # Prepare message for both console and log
    console_lines = [
        f"\n--- Test Step {step_number}: {test_name} ---",
        f"  Expected HTTP Status: {expected_status}",
        f"  Actual HTTP Status  : {actual_status}",
        f"  Result              : {result_status_text}",
        f"--- End Test Step {step_number} ---"
    ]
    log_message = (f"Test Step {step_number} ({test_name}): Expected={expected_status}, "
                   f"Actual={actual_status} -> {result_status_text}")

    print("\n".join(console_lines))
    if passed:
        logger.info(log_message)
    else:
        logger.error(log_message) # Log failures as errors

    return passed

# ================================
# CONTAINER-SPECIFIC TEST SUITE
# ================================

def run_crowdsec_container_tests(container_name: str,
                                container_info: Optional[Dict] = None,
                                dry_run: bool = False,
                                spreadsheet_id: str = "",
                                credentials_file: str = "") -> bool:
    """
    Run CrowdSec integration tests for a specific container.
    
    Args:
        container_name: Name of the container to test
        container_info: Optional container information from discovery
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
    
    # Test suite header
    header_lines = [
        "\n" + "="*70,
        f"CROWDSEC INTEGRATION TEST FOR CONTAINER: {container_name}",
        "="*70,
        f"  Container Name      : {container_name}",
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
        status_step1, _ = check_container_service_access(container_name, container_info)
        passed_step1 = _print_test_step_result(f"Access Unrestricted ({container_name})",
                                              EXPECTED_STATUS_ALLOWED, status_step1, 1)
        test_step_results.append((f"Step 1: Access Unrestricted ({container_name})", passed_step1))

        if not passed_step1:
            logger.warning(f"Initial access test failed for {container_name}. This may indicate routing issues.")
            # Don't abort for individual containers, just note the failure

        # Ban test IP
        print(f"\nPHASE: Banning Test IP for {container_name} tests")
        ban_initiated = _ban_test_ip(reason=f"Test ban for {container_name}")
        
        if ban_initiated:
            time.sleep(BOUNCER_SYNC_DELAY_SECONDS)
            
            # Test Step 2: Access blocked (ban active)
            status_step2, response_text_step2 = check_container_service_access(container_name, container_info)
            passed_step2 = _print_test_step_result(f"Access Blocked ({container_name})",
                                                  EXPECTED_STATUS_BLOCKED, status_step2, 2)
            test_step_results.append((f"Step 2: Access Blocked ({container_name})", passed_step2))
            
            if not passed_step2:
                logger.error(f"Block test failed for {container_name}. Response: '{response_text_step2}'")
                if spreadsheet_id and credentials_file:
                    log_error_to_google_sheets(spreadsheet_id, credentials_file,
                                             f"CrowdSec Test FAIL ({container_name}): Step 2 - Expected {EXPECTED_STATUS_BLOCKED}, Got {status_step2}",
                                             dry_run)

        # Unban test IP
        print(f"\nPHASE: Unbanning Test IP for {container_name}")
        _unban_test_ip()
        time.sleep(BOUNCER_SYNC_DELAY_SECONDS)

        # Test Step 3: Access restored (after unban)
        status_step3, _ = check_container_service_access(container_name, container_info)
        passed_step3 = _print_test_step_result(f"Access Restored ({container_name})",
                                              EXPECTED_STATUS_ALLOWED, status_step3, 3)
        test_step_results.append((f"Step 3: Access Restored ({container_name})", passed_step3))

        if not passed_step3:
            logger.error(f"Restore test failed for {container_name}")
            if spreadsheet_id and credentials_file:
                log_error_to_google_sheets(spreadsheet_id, credentials_file,
                                         f"CrowdSec Test FAIL ({container_name}): Step 3 - Expected {EXPECTED_STATUS_ALLOWED}, Got {status_step3}",
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
# MAIN INTEGRATION TEST SUITE (Enhanced)
# ================================

def run_crowdsec_integration_tests(
    dry_run: bool = False,
    # For logging failures to Google Sheets
    spreadsheet_id: str = "",
    credentials_file: str = "",
    # Optional: test specific containers
    containers_to_test: Optional[Dict[str, Dict]] = None
) -> bool:
    """
    Run the complete CrowdSec + Traefik bouncer integration test suite.
    
    Args:
        dry_run: If True, simulate testing
        spreadsheet_id: Google Sheets ID for logging
        credentials_file: Google credentials file
        containers_to_test: Optional dict of {container_name: container_info} to test specific containers
        
    Returns:
        True if all tests passed, False otherwise
    """
    if containers_to_test:
        # Test specific containers
        logger.info(f"Running CrowdSec tests for {len(containers_to_test)} specific containers")
        
        all_results = []
        for container_name, container_info in containers_to_test.items():
            result = run_crowdsec_container_tests(
                container_name=container_name,
                container_info=container_info,
                dry_run=dry_run,
                spreadsheet_id=spreadsheet_id,
                credentials_file=credentials_file
            )
            all_results.append(result)
        
        overall_success = all(all_results)
        logger.info(f"Container-specific CrowdSec tests completed. Overall result: {'PASSED' if overall_success else 'FAILED'}")
        return overall_success
    
    # --- Test Suite Header ---
    header_lines = [
        "\n" + "="*60,
        "STARTING CROWDSEC + TRAEFIK BOUNCER INTEGRATION TEST SUITE",
        "="*60,
        f"  Target URL          : {TRAEFIK_SCHEME}://{TRAEFIK_HOST}:{TRAEFIK_PORT}{TEST_SERVICE_PATH}",
        f"  Host Header         : {TEST_SERVICE_HOST_HEADER}",
        f"  Test IP to Ban/Unban: {TEST_IP_TO_BAN}",
        f"  CrowdSec LAPI Cont. : {CROWDSEC_LAPI_CONTAINER_NAME}",
        f"  Bouncer Sync Delay  : {BOUNCER_SYNC_DELAY_SECONDS} seconds",
        f"  Expected Allow Status: {EXPECTED_STATUS_ALLOWED}",
        f"  Expected Block Status: {EXPECTED_STATUS_BLOCKED}",
        "="*60
    ]
    print("\n".join(header_lines))
    logger.info("Starting CrowdSec integration test suite with current configuration.")

    test_step_results = # filepath: /var/www/wp-hubstack/scripts/server/prep-and-deploy-crowdsec-config/crowdsec_tester.py
# crowdsec_tester.py

"""
Functions for running CrowdSec integration tests with Traefik.
"""

import time
import requests
import urllib3 # For disabling SSL warnings if needed
from typing import Tuple, Dict, Optional

from logger_setup import logger
from crowdsec_client import cs_ban_ip, cs_unban_ip # Specific functions needed from client
from error_handler import log_error_to_google_sheets # For logging test failures to Sheets

from config import (
    TRAEFIK_SCHEME, TRAEFIK_HOST, TRAEFIK_PORT, TEST_SERVICE_PATH,
    TEST_SERVICE_HOST_HEADER, TEST_IP_TO_BAN,
    EXPECTED_STATUS_ALLOWED, EXPECTED_STATUS_BLOCKED,
    BOUNCER_SYNC_DELAY_SECONDS, REQUEST_TIMEOUT, VERIFY_SSL,
    CROWDSEC_LAPI_CONTAINER_NAME # For context in logs
)

# Disable SSL warnings for self-signed certificates in testing if VERIFY_SSL is False
if not VERIFY_SSL:
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

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

def check_test_service_access(custom_host_header: Optional[str] = None, 
                             custom_path: Optional[str] = None) -> Tuple[int, str]:
    """
    Check access to the test service through Traefik.
    
    Args:
        custom_host_header: Override the default TEST_SERVICE_HOST_HEADER
        custom_path: Override the default TEST_SERVICE_PATH
        
    Returns:
        Tuple of (HTTP status code, response text snippet or error message).
                 Status code is -1 on request failure.
    """
    host_header = custom_host_header or TEST_SERVICE_HOST_HEADER
    service_path = custom_path or TEST_SERVICE_PATH
    
    url = f"{TRAEFIK_SCHEME}://{TRAEFIK_HOST}:{TRAEFIK_PORT}{service_path}"
    headers = {
        "Host": host_header,
        "User-Agent": "CrowdSecIntegrationTester/1.2" # Updated version
    }

    logger.info(f"Making test request to URL: {url} with Host header: {host_header}")
    # logger.debug(f"Request Headers: {headers}") # Can be verbose

    try:
        response = requests.get(
            url,
            headers=headers,
            timeout=REQUEST_TIMEOUT,
            verify=VERIFY_SSL, # Use config for SSL verification
            allow_redirects=False # Important for testing specific endpoint responses
        )
        status_code = response.status_code
        # Get a snippet of the response text for logging, especially for errors
        response_snippet = response.text[:200].replace('\n', ' ') + ('...' if len(response.text) > 200 else '')
        logger.info(f"Test request to {url} completed. Status: {status_code}. Response snippet: '{response_snippet}'")
        # logger.debug(f"Full response headers: {response.headers}")
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

def check_container_service_access(container_name: str, 
                                  container_info: Optional[Dict] = None) -> Tuple[int, str]:
    """
    Check access to a specific container's service through Traefik.
    
    Args:
        container_name: Name of the container to test
        container_info: Optional container information from discovery
        
    Returns:
        Tuple of (HTTP status code, response text snippet or error message)
    """
    # Convert container name to expected host header
    # For wp_ containers, remove wp_ prefix and convert underscores to dots
    if container_name.startswith("wp_"):
        host_header = container_name[3:].replace("_", ".")
    else:
        host_header = container_name.replace("_", ".")
    
    # Use root path for container testing
    service_path = "/"
    
    logger.info(f"Testing container {container_name} with host header: {host_header}")
    return check_test_service_access(custom_host_header=host_header, 
                                   custom_path=service_path)

# ================================
# TEST RESULT FORMATTING
# ================================

def _print_test_step_result(test_name: str, expected_status: int, actual_status: int, step_number: int) -> bool:
    """Prints formatted result for a single test step and logs it."""
    passed = (expected_status == actual_status)
    result_status_text = "PASSED" if passed else "FAILED"

    # Prepare message for both console and log
    console_lines = [
        f"\n--- Test Step {step_number}: {test_name} ---",
        f"  Expected HTTP Status: {expected_status}",
        f"  Actual HTTP Status  : {actual_status}",
        f"  Result              : {result_status_text}",
        f"--- End Test Step {step_number} ---"
    ]
    log_message = (f"Test Step {step_number} ({test_name}): Expected={expected_status}, "
                   f"Actual={actual_status} -> {result_status_text}")

    print("\n".join(console_lines))
    if passed:
        logger.info(log_message)
    else:
        logger.error(log_message) # Log failures as errors

    return passed

# ================================
# CONTAINER-SPECIFIC TEST SUITE
# ================================

def run_crowdsec_container_tests(container_name: str,
                                container_info: Optional[Dict] = None,
                                dry_run: bool = False,
                                spreadsheet_id: str = "",
                                credentials_file: str = "") -> bool:
    """
    Run CrowdSec integration tests for a specific container.
    
    Args:
        container_name: Name of the container to test
        container_info: Optional container information from discovery
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
    
    # Test suite header
    header_lines = [
        "\n" + "="*70,
        f"CROWDSEC INTEGRATION TEST FOR CONTAINER: {container_name}",
        "="*70,
        f"  Container Name      : {container_name}",
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
        status_step1, _ = check_container_service_access(container_name, container_info)
        passed_step1 = _print_test_step_result(f"Access Unrestricted ({container_name})",
                                              EXPECTED_STATUS_ALLOWED, status_step1, 1)
        test_step_results.append((f"Step 1: Access Unrestricted ({container_name})", passed_step1))

        if not passed_step1:
            logger.warning(f"Initial access test failed for {container_name}. This may indicate routing issues.")
            # Don't abort for individual containers, just note the failure

        # Ban test IP
        print(f"\nPHASE: Banning Test IP for {container_name} tests")
        ban_initiated = _ban_test_ip(reason=f"Test ban for {container_name}")
        
        if ban_initiated:
            time.sleep(BOUNCER_SYNC_DELAY_SECONDS)
            
            # Test Step 2: Access blocked (ban active)
            status_step2, response_text_step2 = check_container_service_access(container_name, container_info)
            passed_step2 = _print_test_step_result(f"Access Blocked ({container_name})",
                                                  EXPECTED_STATUS_BLOCKED, status_step2, 2)
            test_step_results.append((f"Step 2: Access Blocked ({container_name})", passed_step2))
            
            if not passed_step2:
                logger.error(f"Block test failed for {container_name}. Response: '{response_text_step2}'")
                if spreadsheet_id and credentials_file:
                    log_error_to_google_sheets(spreadsheet_id, credentials_file,
                                             f"CrowdSec Test FAIL ({container_name}): Step 2 - Expected {EXPECTED_STATUS_BLOCKED}, Got {status_step2}",
                                             dry_run)

        # Unban test IP
        print(f"\nPHASE: Unbanning Test IP for {container_name}")
        _unban_test_ip()
        time.sleep(BOUNCER_SYNC_DELAY_SECONDS)

        # Test Step 3: Access restored (after unban)
        status_step3, _ = check_container_service_access(container_name, container_info)
        passed_step3 = _print_test_step_result(f"Access Restored ({container_name})",
                                              EXPECTED_STATUS_ALLOWED, status_step3, 3)
        test_step_results.append((f"Step 3: Access Restored ({container_name})", passed_step3))

        if not passed_step3:
            logger.error(f"Restore test failed for {container_name}")
            if spreadsheet_id and credentials_file:
                log_error_to_google_sheets(spreadsheet_id, credentials_file,
                                         f"CrowdSec Test FAIL ({container_name}): Step 3 - Expected {EXPECTED_STATUS_ALLOWED}, Got {status_step3}",
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
# MAIN INTEGRATION TEST SUITE (Enhanced)
# ================================

def run_crowdsec_integration_tests(
    dry_run: bool = False,
    # For logging failures to Google Sheets
    spreadsheet_id: str = "",
    credentials_file: str = "",
    # Optional: test specific containers
    containers_to_test: Optional[Dict[str, Dict]] = None
) -> bool:
    """
    Run the complete CrowdSec + Traefik bouncer integration test suite.
    
    Args:
        dry_run: If True, simulate testing
        spreadsheet_id: Google Sheets ID for logging
        credentials_file: Google credentials file
        containers_to_test: Optional dict of {container_name: container_info} to test specific containers
        
    Returns:
        True if all tests passed, False otherwise
    """
    if containers_to_test:
        # Test specific containers
        logger.info(f"Running CrowdSec tests for {len(containers_to_test)} specific containers")
        
        all_results = []
        for container_name, container_info in containers_to_test.items():
            result = run_crowdsec_container_tests(
                container_name=container_name,
                container_info=container_info,
                dry_run=dry_run,
                spreadsheet_id=spreadsheet_id,
                credentials_file=credentials_file
            )
            all_results.append(result)
        
        overall_success = all(all_results)
        logger.info(f"Container-specific CrowdSec tests completed. Overall result: {'PASSED' if overall_success else 'FAILED'}")
        return overall_success
    
    # --- Test Suite Header ---
    header_lines = [
        "\n" + "="*60,
        "STARTING CROWDSEC + TRAEFIK BOUNCER INTEGRATION TEST SUITE",
        "="*60,
        f"  Target URL          : {TRAEFIK_SCHEME}://{TRAEFIK_HOST}:{TRAEFIK_PORT}{TEST_SERVICE_PATH}",
        f"  Host Header         : {TEST_SERVICE_HOST_HEADER}",
        f"  Test IP to Ban/Unban: {TEST_IP_TO_BAN}",
        f"  CrowdSec LAPI Cont. : {CROWDSEC_LAPI_CONTAINER_NAME}",
        f"  Bouncer Sync Delay  : {BOUNCER_SYNC_DELAY_SECONDS} seconds",
        f"  Expected Allow Status: {EXPECTED_STATUS_ALLOWED}",
        f"  Expected Block Status: {EXPECTED_STATUS_BLOCKED}",
        "="*60
    ]
    print("\n".join(header_lines))
    logger.info("Starting CrowdSec integration test suite with current configuration.")

    test_step_results = [] # List to store (description, passed_bool)

    try:
        # --- Initial Cleanup Phase ---
        print("\nPHASE: Initial Cleanup (Ensuring test IP is not already banned)")
        logger.info("Performing initial cleanup: ensuring test IP is not banned before tests.")
        unban_success_initial = _unban_test_ip()
        # Unban success is true even if no ban existed.
        logger.info(f"Initial cleanup unban attempt for {TEST_IP_TO_BAN} processed (success={unban_success_initial}).")
        print(f"Cleanup: Unban command for {TEST_IP_TO_BAN} sent.")

        print(f"Waiting {BOUNCER_SYNC_DELAY_SECONDS}s for bouncer to sync after initial cleanup...")
        time.sleep(BOUNCER_SYNC_DELAY_SECONDS)

        # --- Test Step 1: Access Allowed (No Ban) ---
        status_step1, _ = check_test_service_access()
        passed_step1 = _print_test_step_result("Access Unrestricted (No Ban Active)",
                                              EXPECTED_STATUS_ALLOWED, status_step1, 1)
        test_step_results.append(("Step 1: Access Unrestricted", passed_step1))
        if not passed_step1:
            logger.critical("Critical Test Failure: Access was not allowed even before any ban. Check service and Traefik routing.")
            # Optionally, log to Google Sheets here for critical setup failure
            if spreadsheet_id and credentials_file:
                log_error_to_google_sheets(spreadsheet_id, credentials_file,
                                           f"CrowdSec Test CRITICAL FAIL: Step 1 (Access Unrestricted) - Expected {EXPECTED_STATUS_ALLOWED}, Got {status_step1}",
                                           dry_run)
            # Abort further tests if initial state is wrong
            raise AssertionError("Initial access test failed. Aborting test suite.")


        # --- Action: Ban the Test IP ---
        print(f"\nPHASE: Banning Test IP ({TEST_IP_TO_BAN})")
        ban_initiated = _ban_test_ip()
        if not ban_initiated:
            logger.error(f"Failed to initiate ban for {TEST_IP_TO_BAN}. Cannot proceed with blocking tests.")
            test_step_results.append(("Step 2: Access Blocked (Ban Active)", False)) # Mark as failed
            test_step_results.append(("Step 3: Access Restored (After Unban)", False)) # Mark as failed
            raise AssertionError(f"Failed to ban IP {TEST_IP_TO_BAN}. Aborting blocking tests.")

        print(f"Ban for {TEST_IP_TO_BAN} initiated. Waiting {BOUNCER_SYNC_DELAY_SECONDS}s for bouncer sync...")
        time.sleep(BOUNCER_SYNC_DELAY_SECONDS)

        # --- Test Step 2: Access Blocked (Ban Active) ---
        status_step2, response_text_step2 = check_test_service_access()
        passed_step2 = _print_test_step_result("Access Blocked (Ban Active)",
                                              EXPECTED_STATUS_BLOCKED, status_step2, 2)
        test_step_results.append(("Step 2: Access Blocked (Ban Active)", passed_step2))
        if not passed_step2:
             logger.error(f"Test Failure: Access was not blocked as expected. Response: '{response_text_step2}'")
             # Log to Google Sheets if configured
             if spreadsheet_id and credentials_file:
                log_error_to_google_sheets(spreadsheet_id, credentials_file,
                                           f"CrowdSec Test FAIL: Step 2 (Access Blocked) - Expected {EXPECTED_STATUS_BLOCKED}, Got {status_step2}. Response: {response_text_step2}",
                                           dry_run)


        # --- Action: Unban the Test IP (Cleanup for next test) ---
        print(f"\nPHASE: Unbanning Test IP ({TEST_IP_TO_BAN}) for Restoration Test")
        unban_success_restore = _unban_test_ip()
        logger.info(f"Unban attempt for {TEST_IP_TO_BAN} (for restoration test) processed (success={unban_success_restore}).")
        print(f"Unban command for {TEST_IP_TO_BAN} sent.")

        print(f"Waiting {BOUNCER_SYNC_DELAY_SECONDS}s for bouncer sync after unban...")
        time.sleep(BOUNCER_SYNC_DELAY_SECONDS)

        # --- Test Step 3: Access Restored (After Unban) ---
        status_step3, _ = check_test_service_access()
        passed_step3 = _print_test_step_result("Access Restored (After Unban)",
                                              EXPECTED_STATUS_ALLOWED, status_step3, 3)
        test_step_results.append(("Step 3: Access Restored (After Unban)", passed_step3))
        if not passed_step3:
             logger.error("Test Failure: Access was not restored after unban.")
             if spreadsheet_id and credentials_file:
                log_error_to_google_sheets(spreadsheet_id, credentials_file,
                                           f"CrowdSec Test FAIL: Step 3 (Access Restored) - Expected {EXPECTED_STATUS_ALLOWED}, Got {status_step3}",
                                           dry_run)

        overall_passed = all(passed for _, passed in test_step_results)
        return overall_passed # Returns True if all steps passed

    except AssertionError as ae: # Catch assertion errors from critical failures
        logger.critical(f"CrowdSec integration test suite aborted due to critical failure: {ae}")
        # Ensure cleanup is attempted
        print(f"\nCRITICAL FAILURE: {ae}. Attempting final cleanup of test IP...")
        _unban_test_ip() # Final cleanup attempt
        return False # Overall test suite failed
    except KeyboardInterrupt:
        logger.warning("CrowdSec integration test suite interrupted by user (Ctrl+C).")
        print("\n\nTest suite interrupted by user. Attempting cleanup...")
        _unban_test_ip() # Attempt cleanup
        return False # Mark as failed due to interruption
    except Exception as e:
        logger.error(f"An unexpected error occurred during the CrowdSec integration test suite: {e}", exc_info=True)
        print(f"\nUNEXPECTED ERROR: {e}. Attempting cleanup...")
        if spreadsheet_id and credentials_file: # Log unexpected errors too
            log_error_to_google_sheets(spreadsheet_id, credentials_file,
                                       f"CrowdSec Test UNEXPECTED ERROR: {e}", dry_run)
        _unban_test_ip() # Attempt cleanup
        return False # Mark as failed
    finally:
        # --- Test Suite Summary ---
        summary_lines = ["\n" + "="*60, "CROWDSEC INTEGRATION TEST SUITE SUMMARY", "="*60]
        all_steps_passed_summary = True
        if not test_step_results:
            summary_lines.append("  No test steps were completed (e.g., due to early critical failure or interruption).")
            all_steps_passed_summary = False
        else:
            for description, passed_flag in test_step_results:
                summary_lines.append(f"  {description:<45}: {'PASSED' if passed_flag else 'FAILED'}")
                if not passed_flag:
                    all_steps_passed_summary = False
        
        summary_lines.append("="*60)
        overall_status_message = "ALL TEST STEPS PASSED" if all_steps_passed_summary else "ONE OR MORE TEST STEPS FAILED"
        summary_lines.append(f"  Overall Result: {overall_status_message}")
        summary_lines.append("="*60 + "\n")

        print("\n".join(summary_lines))
        logger.info("CrowdSec integration test suite finished.")
        logger.info(f"Overall Test Suite Result: {overall_status_message}")
        # The function will return the actual overall_passed status from the try block,
        # or False if an exception path was taken.
