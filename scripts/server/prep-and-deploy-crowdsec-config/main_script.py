#!/usr/bin/env python3
"""
Traefik Configuration Diff, Deployment, and CrowdSec Integration Test Tool

This script orchestrates various modules for:
1. Configuration diffing and deployment with Google Sheets/Docs integration
2. Automated backup management with transactional deployment
3. CrowdSec + Traefik bouncer integration testing
4. Error recovery and logging
5. Integrated CrowdSec helper commands
6. Safe label injection from partial configuration files
7. Safe tarball extraction and deployment
"""

import argparse
import sys
import os
import socket # For hostname, though some defaults are now in config.py

# --- Configuration Imports ---
# These are defaults; command-line args can override paths.
from config import (
    DEFAULT_GOOGLE_CREDENTIALS_FILE, DEFAULT_SPREADSHEET_ID, DEFAULT_SHEET_NAME,
    DEFAULT_CURRENT_CONFIG, DEFAULT_PENDING_CONFIG, DEFAULT_PARTIAL_CONFIG,
    DEFAULT_BACKUP_CONFIG, DEFAULT_DEBUG_LOG_FILE, DEFAULT_TARGET_CONFIG,
    DEFAULT_TRAEFIK_DIR, DEFAULT_CROWDSEC_TARBALLS_DIR,  # Added for tarball injection
    CROWDSEC_LAPI_CONTAINER_NAME, CROWDSEC_TRAEFIK_BOUNCER_CONTAINER_NAME, # For CS helper commands
    sanitize_sheet_name # For sanitizing sheet name from args
)

# --- Module Imports ---
# Initialize logger first as other modules might use it at import time
import logger_setup # This will initialize logger and dc_logger
# Now, other modules can safely `from logger_setup import logger, dc_logger`

from utils import load_yaml_file # For loading diff file if needed by deploy_config directly (though create_diff_report_yaml is preferred)
from label_injector import inject_labels_with_restart
from tarball_injector import inject_tarballs_with_restart, list_available_tarballs  # Added tarball injector
from error_handler import log_error_to_google_sheets # For direct error logging if needed
from crowdsec_client import (
    cs_decisions_list, cs_decisions_list_ip, cs_ban_ip, cs_unban_ip,
    cs_bouncers_list, cs_hub_update, test_bouncer_connectivity,
    cs_restart_lapi_container, cs_restart_bouncer_container
)
from deployment_utils import (
    create_diff_report_yaml, backup_config_file, deploy_new_config
)
from google_integration import (
    create_google_doc_with_content, format_config_diff_for_doc,
    update_google_sheet_with_diff_log
)
from crowdsec_tester import run_crowdsec_integration_tests

# ================================
# MAIN FUNCTION
# ================================

def main():
    parser = argparse.ArgumentParser(
        description="Traefik Configuration Diff, Deployment, and CrowdSec Integration Test Tool.",
        formatter_class=argparse.RawTextHelpFormatter
    )

    # --- Group: Label Injection ---
    label_group = parser.add_argument_group('Label Injection Options')
    label_group.add_argument('--inject-labels', action='store_true',
                             help="Inject labels from partial config into target config and restart stack.")
    label_group.add_argument('--target-file', default=DEFAULT_CURRENT_CONFIG,
                             help=f"Target Docker Compose file for label injection. Default: {DEFAULT_CURRENT_CONFIG}")
    label_group.add_argument('--partial-file', default=DEFAULT_PARTIAL_CONFIG,
                             help=f"Source file with labels to inject. Default: {DEFAULT_PARTIAL_CONFIG}")
    label_group.add_argument('--backup-label-file', # Renamed for clarity vs general backup
                             help=f"Backup file path for the target file during label injection. Default: {DEFAULT_TARGET_CONFIG}.bak_label_injection.yml (dynamic based on target-file)")
    label_group.add_argument('--service-name', default="traefik",
                             help="Target service name within the Docker Compose file for label injection. Default: traefik")
    label_group.add_argument('--working-dir',
                             help="Working directory for label injection and Docker Compose operations. If set, paths for target, partial, and backup files are relative to this dir unless absolute.")

    # --- Group: Tarball Injection ---
    tarball_group = parser.add_argument_group('Tarball Injection Options')
    tarball_group.add_argument('--inject-tarballs', action='store_true',
                              help="Extract tarballs from tarballs directory to target directory and restart stack.")
    tarball_group.add_argument('--tarballs-dir', default=DEFAULT_CROWDSEC_TARBALLS_DIR,
                              help=f"Directory containing tarballs to extract. Default: {DEFAULT_CROWDSEC_TARBALLS_DIR}")
    tarball_group.add_argument('--target-container', default=DEFAULT_TRAEFIK_DIR,
                              help=f"Target container for tarball deployment. Default: {DEFAULT_TRAEFIK_DIR}")
    tarball_group.add_argument('--target-config-file', default=DEFAULT_TARGET_CONFIG,
                              help=f"Docker Compose file for tarball injection operations. Default: {DEFAULT_TARGET_CONFIG}")
    tarball_group.add_argument('--list-tarballs', action='store_true',
                              help="List available tarballs and their contents without extracting.")
    tarball_group.add_argument('--cleanup-backup', action='store_true', default=True,
                              help="Remove backup directory after successful tarball deployment. Default: True")
    tarball_group.add_argument('--keep-backup', action='store_true',
                              help="Keep backup directory after successful tarball deployment (overrides --cleanup-backup).")

    # --- Group: Configuration Management (Diff & Deploy) ---
    config_mgmt_group = parser.add_argument_group('Configuration Diff and Deploy Options')
    config_mgmt_group.add_argument('--diff-confs', nargs=2, metavar=('CURRENT_CONF', 'PENDING_CONF'),
                                   help="Compare two configuration files and generate a diff report (e.g., current.yml pending.yml).")
    config_mgmt_group.add_argument('--deploy-conf', nargs=2, metavar=('TARGET_CONF', 'NEW_CONF'),
                                   help="Deploy NEW_CONF to replace TARGET_CONF with backup and rollback (e.g., live.yml staging.yml).")
    config_mgmt_group.add_argument('--backup-conf', metavar='FILE_TO_BACKUP',
                                   help="Create a single timestamped backup of the specified configuration file.")

    # --- Group: Deployment and Testing Control ---
    control_group = parser.add_argument_group('Deployment and Testing Control')
    control_group.add_argument('--skip-backup', action='store_true',
                               help="Skip creating a backup during --deploy-conf (NOT RECOMMENDED).")
    control_group.add_argument('--skip-tests', action='store_true',
                               help="Skip running CrowdSec integration tests after a successful deployment or label injection.")
    control_group.add_argument('--test-only', action='store_true',
                               help="Run only the CrowdSec integration tests (no deployment or diff actions).")

    # --- Group: CrowdSec Helper Commands ---
    cs_helper_group = parser.add_argument_group('CrowdSec Helper Commands (via cscli)')
    cs_helper_group.add_argument('--cs-decisions-list', action='store_true', help="List CrowdSec decisions.")
    cs_helper_group.add_argument('--cs-decisions-list-ip', metavar='IP', help="List decisions for a specific IP.")
    cs_helper_group.add_argument('--cs-ban-ip', nargs=3, metavar=('IP', 'REASON', 'DURATION'),
                                 help="Ban an IP (e.g., 1.2.3.4 'Test ban' 5m).")
    cs_helper_group.add_argument('--cs-unban-ip', metavar='IP', help="Unban an IP address.")
    cs_helper_group.add_argument('--cs-bouncers-list', action='store_true', help="List registered bouncers.")
    cs_helper_group.add_argument('--cs-hub-update', action='store_true', help="Update CrowdSec hub.")
    cs_helper_group.add_argument('--cs-test-connectivity', action='store_true',
                                 help="Test connectivity from Traefik container to the bouncer.")
    cs_helper_group.add_argument('--cs-restart-lapi', action='store_true', help="Restart CrowdSec LAPI container.")
    cs_helper_group.add_argument('--cs-restart-bouncer', action='store_true', help="Restart CrowdSec Traefik bouncer container.")

    # --- Group: Google Integration ---
    google_group = parser.add_argument_group('Google Integration Options')
    google_group.add_argument('--creds-file', default=DEFAULT_GOOGLE_CREDENTIALS_FILE,
                              help=f"Path to Google service account JSON key. Default: {DEFAULT_GOOGLE_CREDENTIALS_FILE}")
    google_group.add_argument('--spreadsheet-id', default=DEFAULT_SPREADSHEET_ID,
                              help=f"Google Sheet ID for logging. Default: {DEFAULT_SPREADSHEET_ID}")
    google_group.add_argument('--sheet-name', default=DEFAULT_SHEET_NAME,
                              help=f"Worksheet name for diff logs. Default: '{DEFAULT_SHEET_NAME}' (can be dynamic based on hostname)")

    # --- Group: General Options ---
    general_group = parser.add_argument_group('General Options')
    general_group.add_argument('--debug-log', default=DEFAULT_DEBUG_LOG_FILE,
                               help=f"Debug log file path. Default: {DEFAULT_DEBUG_LOG_FILE}")
    general_group.add_argument('--dry-run', action='store_true',
                               help="Simulate execution: show what would be done without making actual changes.")

    args = parser.parse_args()

    # --- Handle --keep-backup flag ---
    if args.keep_backup:
        args.cleanup_backup = False

    # --- Setup dynamic logger path if changed by arg ---
    # The logger_setup module already initialized loggers with default paths.
    # If args.debug_log is different, we might need to reconfigure.
    # For simplicity, we assume the initial setup is sufficient, or this needs more complex logger re-init.
    # logger_setup.setup_logging(args.debug_log) # If re-init is desired
    # logger_setup.setup_dc_logging() # dc_debug_log is not an arg here

    # Sanitize sheet name from args if provided, otherwise default is already sanitized
    args.sheet_name = sanitize_sheet_name(args.sheet_name)
    if not args.sheet_name.strip() or len(args.sheet_name) > 99:
        logger_setup.logger.warning(f"Provided sheet name was invalid after sanitization. Using default: {DEFAULT_SHEET_NAME}")
        args.sheet_name = DEFAULT_SHEET_NAME
    
    current_hostname = socket.gethostname() # Used for Google Docs/Sheets context

    if args.dry_run:
        logger_setup.logger.info("DRY RUN MODE ENABLED - NO ACTUAL CHANGES WILL BE MADE TO SYSTEM OR CONFIGS.")
        print("\n*** DRY RUN MODE ENABLED - NO ACTUAL CHANGES WILL BE MADE ***\n")

    # --- Handle Actions ---
    action_taken = False # Flag to track if any primary action was performed

    # 1. List Tarballs (informational action)
    if args.list_tarballs:
        action_taken = True
        logger_setup.logger.info("Listing available tarballs...")
        print("Available tarballs:")
        
        tarball_files, all_files = list_available_tarballs(args.tarballs_dir)
        
        if not tarball_files:
            print(f"No tarballs found in '{args.tarballs_dir}'")
        else:
            print(f"\nFound {len(tarball_files)} tarball(s) in '{args.tarballs_dir}':")
            for tarball in tarball_files:
                print(f"  - {tarball}")
            
            print(f"\nFiles that would be extracted ({len(all_files)} total):")
            for file_entry in all_files:
                print(f"  - {file_entry}")
        
        # If only listing tarballs, exit after showing the list
        if not (args.inject_tarballs or args.inject_labels or args.diff_confs or 
                args.deploy_conf or args.backup_conf or args.test_only or 
                any(arg.startswith('--cs-') for arg in sys.argv)):
            sys.exit(0)

    # 2. Tarball Injection
    if args.inject_tarballs:
        action_taken = True
        logger_setup.logger.info("Initiating tarball injection process...")
        print("Starting tarball injection process...")

        success = inject_tarballs_with_restart(
            target_config_file=args.target_config_file,
            tarballs_dir=args.tarballs_dir,
            target_container=args.target_container,
            working_dir=args.working_dir,
            dry_run=args.dry_run,
            cleanup_backup=args.cleanup_backup
        )
        
        if success:
            logger_setup.logger.info("Tarball injection process completed successfully.")
            print("Tarball injection process completed successfully.")
            if not args.skip_tests and not args.dry_run:
                logger_setup.logger.info("Running CrowdSec integration tests after tarball injection...")
                print("\nRunning CrowdSec integration tests...")
                run_crowdsec_integration_tests(args.dry_run, args.spreadsheet_id, args.creds_file)
        else:
            logger_setup.logger.error("Tarball injection process failed.")
            print("Tarball injection process failed.")

    # 3. Label Injection
    if args.inject_labels:
        action_taken = True
        logger_setup.logger.info("Initiating label injection process...")
        print("Starting label injection process...")

        # Determine backup file name for label injection
        backup_label_file = args.backup_label_file
        if not backup_label_file: # If not provided, create a default based on target file
            target_filename = os.path.basename(args.target_file)
            backup_label_file = f"{target_filename}.bak_label_injection.yml"
            if args.working_dir: # Prepend working_dir if specified
                 backup_label_file = os.path.join(args.working_dir, backup_label_file)
            else: # Relative to where script is run, or make absolute from target_file dir
                 backup_label_file = os.path.join(os.path.dirname(os.path.abspath(args.target_file)), backup_label_file)

        success = inject_labels_with_restart(
            target_file=args.target_file,
            partial_file=args.partial_file,
            backup_file=backup_label_file, # Use the determined backup file
            service_name=args.service_name,
            working_dir=args.working_dir,
            dry_run=args.dry_run
        )
        if success:
            logger_setup.logger.info("Label injection process completed successfully.")
            print("Label injection process completed successfully.")
            if not args.skip_tests and not args.dry_run:
                logger_setup.logger.info("Running CrowdSec integration tests after label injection...")
                print("\nRunning CrowdSec integration tests...")
                run_crowdsec_integration_tests(args.dry_run, args.spreadsheet_id, args.creds_file)
        else:
            logger_setup.logger.error("Label injection process failed.")
            print("Label injection process failed.")
            # Consider if this should exit(1) or allow other commands
        # No sys.exit here, allow script to continue if other args are present, or fall through to help.

    # 4. CrowdSec Helper Commands (execute and typically exit)
    cs_helper_action = False
    if args.cs_decisions_list: cs_helper_action = True; cs_decisions_list()
    elif args.cs_decisions_list_ip: cs_helper_action = True; cs_decisions_list_ip(args.cs_decisions_list_ip)
    elif args.cs_ban_ip: cs_helper_action = True; cs_ban_ip(args.cs_ban_ip[0], args.cs_ban_ip[1], args.cs_ban_ip[2])
    elif args.cs_unban_ip: cs_helper_action = True; cs_unban_ip(args.cs_unban_ip)
    elif args.cs_bouncers_list: cs_helper_action = True; cs_bouncers_list()
    elif args.cs_hub_update: cs_helper_action = True; cs_hub_update()
    elif args.cs_test_connectivity: cs_helper_action = True; test_bouncer_connectivity()
    elif args.cs_restart_lapi: cs_helper_action = True; cs_restart_lapi_container()
    elif args.cs_restart_bouncer: cs_helper_action = True; cs_restart_bouncer_container()
    
    if cs_helper_action:
        action_taken = True
        # Helper commands usually stand alone. Exit after execution unless combined with other major ops.
        # For now, let's assume they are primary actions. If combined, this logic might change.
        # If a cs_helper was run, and no other major action like deploy/diff/inject, then exit.
        if not (args.inject_labels or args.inject_tarballs or args.diff_confs or args.deploy_conf or args.backup_conf or args.test_only or args.list_tarballs):
            sys.exit(0)

    # 5. Test-Only Mode
    if args.test_only:
        action_taken = True
        logger_setup.logger.info("Running CrowdSec integration tests only...")
        print("Running CrowdSec integration tests only...")
        test_success = run_crowdsec_integration_tests(args.dry_run, args.spreadsheet_id, args.creds_file)
        # sys.exit(0 if test_success else 1) # Exit after test_only

    # 6. Configuration Diff
    if args.diff_confs:
        action_taken = True
        current_conf, pending_conf = args.diff_confs
        logger_setup.logger.info(f"Comparing configurations: '{current_conf}' vs '{pending_conf}'.")
        print(f"Comparing configurations: '{current_conf}' vs '{pending_conf}'.")

        diff_report_file = "config_diff_report.yml" # Default output for the YAML report
        diff_report_data = create_diff_report_yaml(current_conf, pending_conf, diff_report_file)

        if diff_report_data and not args.dry_run:
            if os.path.exists(args.creds_file) and args.spreadsheet_id:
                doc_title = f"{current_hostname} Config Diff: {os.path.basename(current_conf)} vs {os.path.basename(pending_conf)}"
                formatted_diff_content = format_config_diff_for_doc(current_conf, pending_conf)
                doc_url = create_google_doc_with_content(args.creds_file, doc_title, formatted_diff_content)

                if doc_url:
                    update_google_sheet_with_diff_log(
                        args.spreadsheet_id, args.sheet_name, args.creds_file,
                        doc_url, current_hostname, args.dry_run
                    )
                else:
                    logger_setup.logger.error("Failed to create Google Doc for diff. Sheet not updated with Doc link.")
            else:
                logger_setup.logger.warning("Google credentials/spreadsheet ID not configured. Skipping Google Docs/Sheets integration for diff report.")
        elif args.dry_run:
             logger_setup.logger.info(f"[DRY RUN] Would create diff report YAML, Google Doc, and update Google Sheet.")

    # 7. Backup Configuration File
    if args.backup_conf:
        action_taken = True
        logger_setup.logger.info(f"Request to backup configuration file: {args.backup_conf}")
        backup_path = backup_config_file(args.backup_conf, args.dry_run)
        if backup_path:
            print(f"Backup operation complete. Path: {backup_path}")
        else:
            print(f"Backup operation failed for {args.backup_conf}.")

    # 8. Deploy Configuration
    deployment_succeeded = False # Track if deployment itself was successful
    if args.deploy_conf:
        action_taken = True
        target_conf, new_conf = args.deploy_conf
        logger_setup.logger.info(f"Attempting to deploy '{new_conf}' to '{target_conf}'.")
        print(f"Deploying '{new_conf}' to replace '{target_conf}'.")

        # Diff is implicitly handled by deploy_new_config if needed for logging,
        # but a diff report is not generated here unless --diff-confs was also called.

        deployment_succeeded = deploy_new_config(
            current_config_path=target_conf,
            new_config_path=new_conf,
            skip_backup=args.skip_backup,
            dry_run=args.dry_run,
            spreadsheet_id=args.spreadsheet_id,
            credentials_file=args.creds_file
        )

        if deployment_succeeded:
            logger_setup.logger.info("Configuration deployment reported success.")
            print("Configuration deployment completed successfully.")
            if not args.skip_tests and not args.dry_run:
                logger_setup.logger.info("Running CrowdSec integration tests after deployment...")
                print("\nRunning CrowdSec integration tests...")
                # Tests run regardless of their own outcome for now, deployment is key result here.
                run_crowdsec_integration_tests(args.dry_run, args.spreadsheet_id, args.creds_file)
        else:
            logger_setup.logger.error("Configuration deployment failed.")
            print("Configuration deployment failed.")
            # sys.exit(1) # Exit if deployment fails critically

    # --- Final Check: If no action was specified ---
    if not action_taken:
        if len(sys.argv) == 1: # Just script name, no args
            parser.print_help(sys.stderr)
            sys.exit(1)
        else: # Args were given, but none matched primary actions
            print("No primary action specified or matched (e.g., --deploy-conf, --inject-labels, --inject-tarballs, --test-only, etc.).")
            print("Use --help for available options.")
            # Check if any CS helper was intended but missed due to logic
            # This part might be redundant if cs_helper_action logic is robust
            non_primary_args_present = any(arg.startswith('--cs-') for arg in sys.argv)
            if not non_primary_args_present:
                 parser.print_help(sys.stderr) # Show help if truly no recognized action
                 sys.exit(1)


def error_exit(message: str, exit_code: int = 1):
    """Logs an error and exits the script."""
    logger_setup.logger.error(message)
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(exit_code)

if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        # Catch-all for unexpected errors in main execution flow
        # Individual modules should handle their specific errors and log them.
        # This is for truly unhandled exceptions at the top level.
        logger_setup.logger.critical(f"Unhandled exception in main execution: {e}", exc_info=True)
        print(f"CRITICAL UNHANDLED ERROR: {e}. Check debug logs for details.", file=sys.stderr)
        # Optionally log to Google Sheets if configured and appropriate
        # log_error_to_google_sheets(args_for_sheets..., f"Unhandled main error: {e}")
        sys.exit(2) # Different exit code for unhandled
