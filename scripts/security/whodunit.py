#!/usr/bin/env python3

import os
import re
import argparse
import platform
from datetime import datetime, timedelta, timezone

# For parsing human-readable date strings
try:
    import dateparser
except ImportError:
    print("Error: The 'dateparser' library is required for flexible time inputs.")
    print("Please install it: pip install dateparser")
    exit(1)

# For file owner information on POSIX systems (like Ubuntu)
if platform.system() == "Linux" or platform.system() == "Darwin": # Darwin is macOS
    try:
        import pwd
    except ImportError:
        print("Warning: pwd module not found (should be standard on POSIX systems). File owner information might be limited.")
        pwd = None
else:
    # This script is now tailored for Linux, so other OSes are not expected.
    # If somehow run on non-Linux/Darwin, owner lookup will be limited.
    print(f"Warning: Script is optimized for Linux. File owner lookup might not work correctly on {platform.system()}.")
    pwd = None

def get_file_owner(filepath):
    """
    Gets the owner of a file on a POSIX system.
    Returns the username as a string, or None if an error occurs or not determinable.
    """
    try:
        stat_info = os.stat(filepath)
        uid = stat_info.st_uid
        if pwd:
            try:
                return pwd.getpwuid(uid).pw_name
            except KeyError:
                return f"UID {uid} (No username found)"
        else:
            return f"UID {uid} (pwd module not available)"
    except Exception as e:
        # print(f"Error getting owner for {filepath}: {e}")
        return "N/A (Error)"

def parse_log_line(line, log_regex, timestamp_format):
    """
    Parses a log line using a regex to extract a timestamp.
    The regex must have a named capture group called 'timestamp'.
    Returns a datetime object (UTC) or None.
    """
    match = log_regex.search(line)
    if match:
        timestamp_str = match.group("timestamp")
        try:
            dt_obj = datetime.strptime(timestamp_str, timestamp_format)
            if dt_obj.tzinfo is None or dt_obj.tzinfo.utcoffset(dt_obj) is None:
                # Assume local time if naive, then convert to UTC
                # For more control, logs should ideally have timezone info or be in UTC
                dt_obj = dt_obj.replace(tzinfo=datetime.now().astimezone().tzinfo).astimezone(timezone.utc)
            else:
                dt_obj = dt_obj.astimezone(timezone.utc)
            return dt_obj
        except ValueError as e:
            # print(f"Warning: Could not parse timestamp '{timestamp_str}' with format '{timestamp_format}': {e}")
            return None
    return None

def parse_datetime_input(time_str_input, reference_date=None):
    """
    Parses a flexible date/time string (ISO, relative, or human-readable)
    into an offset-aware UTC datetime object.
    `reference_date` is used for relative times like "yesterday", defaults to now_utc.
    """
    if reference_date is None:
        reference_date = datetime.now(timezone.utc)

    # Settings for dateparser:
    # - TO_TIMEZONE: Converts the parsed date to UTC.
    # - RETURN_AS_TIMEZONE_AWARE: Ensures the returned object is timezone-aware.
    # - PREFER_DATES_FROM: 'past' or 'future' can help resolve ambiguity for vague strings.
    #                        Default is 'current_period' which is usually fine.
    # Use `require_parts` if you want to ensure that time is also part of the input,
    # though for start/end of day scenarios, not having time might be intended.
    parsed_dt = dateparser.parse(
        time_str_input,
        settings={
            'TO_TIMEZONE': 'UTC',
            'RETURN_AS_TIMEZONE_AWARE': True,
            # 'PREFER_DATES_FROM': 'past' # Useful if terms like "Friday" are relative to the past
        }
    )

    if not parsed_dt:
        raise ValueError(f"Could not parse the date/time string: '{time_str_input}'")

    return parsed_dt


def find_modified_files_and_correlate_logs(
    directory_path,
    start_time_input_str,
    end_time_input_str,
    log_file_path=None,
    log_regex_str=None,
    log_timestamp_format=None,
    correlation_window_seconds=60
):
    """
    Finds files modified within a given time frame, identifies the modifier,
    and correlates with server log timestamps if provided.
    """
    now_utc = datetime.now(timezone.utc)
    try:
        # Use dateparser for flexible start and end time inputs
        start_time_dt = parse_datetime_input(start_time_input_str)
        # For end times like "today" or "yesterday", they often resolve to the beginning of that day (00:00:00).
        # If the intent is to include the *entire* day, the end_time_input_str should be more specific
        # (e.g., "today 23:59:59") or logic added here to adjust it.
        # For simplicity, we take what dateparser gives.
        end_time_dt = parse_datetime_input(end_time_input_str)

        print(f"Scanning directory: {directory_path}")
        print(f"Requested time frame: '{start_time_input_str}' to '{end_time_input_str}'")
        print(f"Interpreted UTC Time frame: {start_time_dt.isoformat()} to {end_time_dt.isoformat()}")
        print(f"Correlation window: +/- {correlation_window_seconds} seconds")
        print("-" * 30)

    except ValueError as e:
        print(f"Error: {e}")
        return

    modified_files_info = []
    for root, _, files in os.walk(directory_path):
        for filename in files:
            filepath = os.path.join(root, filename)
            try:
                mod_timestamp_epoch = os.path.getmtime(filepath)
                mod_time_dt_utc = datetime.fromtimestamp(mod_timestamp_epoch, timezone.utc)

                if start_time_dt <= mod_time_dt_utc <= end_time_dt:
                    owner = get_file_owner(filepath)
                    modified_files_info.append({
                        "path": filepath,
                        "modified_time_utc": mod_time_dt_utc,
                        "owner": owner
                    })
            except FileNotFoundError:
                print(f"Warning: File not found during scan: {filepath}")
            except Exception as e:
                print(f"Warning: Could not process file {filepath}: {e}")

    print(f"\n--- Found {len(modified_files_info)} modified files in the time frame ---")
    for file_info in modified_files_info:
        print(f"  File: {file_info['path']}")
        print(f"    Modified (UTC): {file_info['modified_time_utc'].isoformat()}")
        print(f"    Owner: {file_info['owner']}")

    if not log_file_path:
        print("\n--- Log file analysis skipped (no log file provided) ---")
        return

    if not log_regex_str or not log_timestamp_format:
        print("\n--- Log file analysis skipped (log regex or timestamp format not provided) ---")
        return

    try:
        log_regex = re.compile(log_regex_str)
    except re.error as e:
        print(f"\nError: Invalid log regex provided: {e}")
        return

    log_entries = []
    print(f"\n--- Parsing log file: {log_file_path} ---")
    try:
        with open(log_file_path, 'r', encoding='utf-8', errors='ignore') as lf:
            for i, line in enumerate(lf):
                log_ts_utc = parse_log_line(line.strip(), log_regex, log_timestamp_format)
                if log_ts_utc:
                    log_entries.append({"timestamp_utc": log_ts_utc, "line_number": i + 1, "line_content": line.strip()})
    except FileNotFoundError:
        print(f"Error: Log file not found: {log_file_path}")
        return
    except Exception as e:
        print(f"Error reading or parsing log file: {e}")
        return

    if not log_entries:
        print("No valid timestamped entries found in the log file matching the regex and format.")
    else:
        print(f"Found {len(log_entries)} entries with parsable timestamps in the log file.")

    if not modified_files_info and not log_entries: # If no files and no logs, nothing to correlate
        return
    if not modified_files_info and log_entries:
        print("\nNo files found modified in the timeframe to correlate with log entries.")
        return
    if not log_entries and modified_files_info: # Log entries might not have been found or parsed
        print("\nNo log entries to correlate with found/parsed.")
        return


    print("\n--- Correlating file modifications with log entries ---")
    correlation_delta = timedelta(seconds=correlation_window_seconds)
    found_correlations_overall = False

    for file_info in modified_files_info:
        print(f"\nFile: {file_info['path']} (Modified UTC: {file_info['modified_time_utc'].isoformat()}, Owner: {file_info['owner']})")
        correlated_logs_for_file = []
        for log_entry in log_entries:
            time_diff = abs(file_info['modified_time_utc'] - log_entry['timestamp_utc'])
            if time_diff <= correlation_delta:
                correlated_logs_for_file.append(log_entry)
                found_correlations_overall = True

        if correlated_logs_for_file:
            print(f"  Found {len(correlated_logs_for_file)} correlated log entries within +/- {correlation_window_seconds}s:")
            for log_entry in correlated_logs_for_file:
                diff_sign = "+" if log_entry['timestamp_utc'] >= file_info['modified_time_utc'] else "-"
                time_difference_seconds = (log_entry['timestamp_utc'] - file_info['modified_time_utc']).total_seconds()
                print(f"    Log Time (UTC): {log_entry['timestamp_utc'].isoformat()} (Delta: {diff_sign}{abs(time_difference_seconds):.2f}s)")
                print(f"      L{log_entry['line_number']}: {log_entry['line_content']}")
        else:
            print("  No correlated log entries found within the defined window.")

    if not found_correlations_overall and modified_files_info and log_entries:
        print("\nNo correlations found between any modified files and log entries based on the criteria.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Check files modified within a time frame (Ubuntu/Linux focused), their owners, and correlate with server log timestamps.",
        formatter_class=argparse.RawTextHelpFormatter,
        add_help=False                             # disable the builtin -h/--help
    )
    parser.add_argument(
        "-h", "--help",
        action="help",
        help="Show this help message and exit."
    )
    parser.add_argument(
        "--dir",
        required=True,
        help="Directory to scan for modified files."
    )
    parser.add_argument(
        "--start-time",
        required=True,
        help="Start of the time frame. Can be an ISO timestamp or human-readable string."
    )
    parser.add_argument(
        "--end-time",
        required=True,
        help="End of the time frame. Can be an ISO timestamp or human-readable string."
    )
    parser.add_argument(
        "--log-file",
        help="Optional: Path to the server log file to correlate with."
    )
    parser.add_argument(
        "--log-regex",
        help="Regex (with named group 'timestamp') to extract timestamps from log lines (required if --log-file)."
    )
    parser.add_argument(
        "--log-timestamp-format",
        help="Python strptime format for the extracted timestamp (required if --log-file)."
    )
    parser.add_argument(
        "--delta",
        type=int,
        default=60,
        help="Correlation window in seconds (default: 60)."
    )

    args = parser.parse_args()

    if args.log_file and (not args.log_regex or not args.log_timestamp_format):
        parser.error("--log-regex and --log-timestamp-format are required when --log-file is specified.")

    find_modified_files_and_correlate_logs(
        args.dir,
        args.start_time,
        args.end_time,
        log_file_path=args.log_file,
        log_regex_str=args.log_regex,
        log_timestamp_format=args.log_timestamp_format,
        correlation_window_seconds=args.delta
    )