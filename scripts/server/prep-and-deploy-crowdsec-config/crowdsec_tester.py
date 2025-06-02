# crowdsec_tester.py

"""
Functions for running CrowdSec integration tests with Traefik.
"""

import time
import requests
import urllib3 # For disabling SSL warnings if needed
from typing import Tuple

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

def check_test_service_access() -> Tuple[int, str]:
    """
    Check access to the test service through Traefik.
    Returns:
        Tuple of (HTTP status code, response text snippet or error message).
                 Status code is -1 on request failure.
    """
    url = f"{TRAEFIK_SCHEME}://{TRAEFIK_HOST}:{TRAEFIK_PORT}{TEST_SERVICE_PATH}"
    headers = {
        "Host": TEST_SERVICE_HOST_HEADER,
        "User-Agent": "CrowdSecIntegrationTester/1.1" # Updated version
    }

    logger.info(f"Making test request to URL: {url} with Host header: {TEST_SERVICE_HOST_HEADER}")
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
# MAIN INTEGRATION TEST SUITE
# ================================

def run_crowdsec_integration_tests(
    dry_run: bool = False,
    # For logging failures to Google Sheets
    spreadsheet_id: str = "",
    credentials_file: str = ""
) -> bool:
    """
    Run the complete CrowdSec + Traefik bouncer integration test suite.
    Handles setup, execution of test steps, and cleanup.
    Logs detailed information and a summary.
    """
    if dry_run:
        logger.info("[DRY RUN] Skipping actual CrowdSec integration tests execution.")
        print("\n[DRY RUN] CrowdSec integration tests would be executed here.")
        return True # Simulate success for dry run

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
