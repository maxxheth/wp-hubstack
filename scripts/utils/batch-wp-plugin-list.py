#!/usr/bin/env python3
"""
Batch runner to collect `wp plugin list` from each container,
save the raw output, and display summary bar‐charts.
Requires: plotext (pip install plotext)
"""

import argparse
import csv
import json
import os
import re
import subprocess
import sys

import plotext as plt

def parse_args():
    p = argparse.ArgumentParser(
        description="Collect WP plugin lists from Docker containers and plot useful stats."
    )
    p.add_argument(
        "--target-dir", "-t",
        default=".",
        help="Host base directory for reports (default: .)"
    )
    p.add_argument(
        "--container-list-file", "-c",
        required=True,
        help="Path to file listing Docker containers (one per line, header on first line)."
    )
    p.add_argument(
        "--format", "-f",
        choices=("json", "csv"),
        default="json",
        help="Output format for wp plugin list (default: json)."
    )
    p.add_argument(
        "--dry-run", "-n",
        action="store_true",
        help="Show what would be done without executing collection commands."
    )
    p.add_argument(
        "--use-existing-lists",
        action="store_true",
        help="Use existing plugin list files from target-dir instead of collecting new ones. Charts will be rendered."
    )
    return p.parse_args()

def load_containers(list_file):
    containers = []
    with open(list_file) as fh:
        lines = fh.readlines()[1:]  # skip header
    for line in lines:
        name = line.strip().split()[-1] if line.strip() else None
        if name and re.match(r"^wp_", name):
            containers.append(name)
    return containers

def collect_and_save(container, fmt, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    outfile = os.path.join(out_dir, f"plugin-list.{fmt}")
    cmd = ["docker", "exec", container,
           "wp", "--allow-root", "plugin", "list", f"--format={fmt}"]
    try:
        res = subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        with open(outfile, "wb") as f:
            f.write(res.stdout)
        return res.stdout.decode()
    except subprocess.CalledProcessError as e:
        print(f"WARNING: Failed to collect from {container}: {e.stderr.decode()}", file=sys.stderr)
        return None

def load_plugin_data(raw, fmt):
    """Return list of dicts for each plugin."""
    if raw is None:
        return []
    if fmt == "json":
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            print(f"WARNING: Could not decode JSON data.", file=sys.stderr)
            if raw:
                 print(f"Problematic raw data (first 100 chars): {raw[:100]}", file=sys.stderr)
            return []
    # csv
    lines = raw.splitlines()
    reader = csv.DictReader(lines)
    return list(reader)

def display_pies(all_data): # This function renders bar charts
    # aggregate across all containers
    stats = {
        "status": {"active":0, "inactive":0, "must-use":0, "active-network":0, "dropin":0},
        "update": {"none":0, "available":0, "unavailable":0},
        "auto_update": {"on":0, "off":0},
    }

    for plugins in all_data.values():
        for p in plugins:
            if not isinstance(p, dict):
                print(f"WARNING: Expected a dictionary for plugin data, got {type(p)}: {p}", file=sys.stderr)
                continue

            st = p.get("status", "").strip()
            if st in stats["status"]:
                stats["status"][st] += 1
            elif st:
                print(f"INFO: Unrecognized plugin status '{st}' found.", file=sys.stderr)

            update_value = p.get("update")
            upd = ""
            if isinstance(update_value, str):
                upd = update_value.strip()
            elif isinstance(update_value, bool):
                upd = "available" if update_value else "none"
            
            if upd in stats["update"]:
                stats["update"][upd] += 1
            elif upd:
                 print(f"INFO: Unrecognized update status '{upd}' found for plugin '{p.get('name', 'N/A')}'.", file=sys.stderr)

            auto_update_value = p.get("auto_update")
            au = ""
            if isinstance(auto_update_value, str):
                au = auto_update_value.strip()
            elif isinstance(auto_update_value, bool):
                au = "on" if auto_update_value else "off"

            if au in stats["auto_update"]:
                stats["auto_update"][au] += 1
            elif au:
                print(f"INFO: Unrecognized auto_update status '{au}' found for plugin '{p.get('name', 'N/A')}'.", file=sys.stderr)

    # 1) Status distribution
    plt.clear_figure()
    status_items = {k: v for k, v in stats["status"].items() if v > 0}
    if status_items:
        labels, values = zip(*status_items.items())
        color_map_status = {
            "active": "green",
            "inactive": "red",
            "must-use": "light_green",
            "active-network": "cyan",
            "dropin": "magenta"
        }
        bar_colors = [color_map_status.get(label, "blue") for label in labels]
        plt.simple_bar(labels, values, title="Plugin Status Distribution", color=bar_colors)
        plt.show()
    else:
        print("No data to display for Plugin Status Distribution.")

    # 2) Update availability
    plt.clear_figure()
    update_items = {k: v for k, v in stats["update"].items() if v > 0}
    if update_items:
        labels, values = zip(*update_items.items())
        color_map_update = {
            "none": "green",      # Up to date
            "available": "red",   # Update available
            "unavailable": "yellow" # Update status unknown
        }
        bar_colors = [color_map_update.get(label, "blue") for label in labels]
        plt.simple_bar(labels, values, title="Plugin Update Status", color=bar_colors)
        plt.show()
    else:
        print("No data to display for Plugin Update Status.")

    # 3) Auto-update settings
    plt.clear_figure()
    auto_update_items = {k: v for k, v in stats["auto_update"].items() if v > 0}
    if auto_update_items:
        labels, values = zip(*auto_update_items.items())
        color_map_auto_update = {
            "on": "green",
            "off": "red"
        }
        bar_colors = [color_map_auto_update.get(label, "blue") for label in labels]
        plt.simple_bar(labels, values, title="Auto-update On vs Off", color=bar_colors)
        plt.show()
    else:
        print("No data to display for Auto-update On vs Off.")

def main():
    args = parse_args()

    if args.dry_run:
        if not args.use_existing_lists:
            print("*** DRY RUN MODE: No collection commands will be executed. ***\n")
        else:
            print("*** DRY RUN MODE: Will attempt to use existing lists for chart rendering. No new collection. ***\n")

    report_base = os.path.join(os.path.abspath(args.target_dir), "wp-plugin-update-reports")
    
    try:
        containers = load_containers(args.container_list_file)
    except FileNotFoundError:
        print(f"ERROR: Container list file not found: {args.container_list_file}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"ERROR: Failed to load containers from {args.container_list_file}: {e}", file=sys.stderr)
        sys.exit(1)

    if not containers:
        print("No WordPress containers found or parsed from the list.", file=sys.stderr)
        sys.exit(0)

    all_data = {}
    for c in containers:
        out_dir = os.path.join(report_base, c)
        plugin_list_file_path = os.path.join(out_dir, f"plugin-list.{args.format}")

        if args.use_existing_lists:
            print(f"Attempting to load existing plugin list for {c}...")
            if os.path.exists(plugin_list_file_path):
                try:
                    with open(plugin_list_file_path, "r", encoding="utf-8") as f_in:
                        raw_content = f_in.read()
                    plugins = load_plugin_data(raw_content, args.format)
                    all_data[c] = plugins 
                    print(f"  → Loaded {len(plugins)} plugins from {plugin_list_file_path}")
                except Exception as e:
                    print(f"WARNING: Failed to read or parse {plugin_list_file_path}: {e}", file=sys.stderr)
                    all_data[c] = [] 
            else:
                print(f"  WARNING: Plugin list file not found: {plugin_list_file_path}. Skipping data for container {c}.", file=sys.stderr)
                all_data[c] = [] # Ensure container key exists if file not found, to avoid issues later
        else: 
            print(f"Collecting from {c}...")
            if args.dry_run:
                print(f"  DRY RUN: would create dir '{out_dir}' and run:")
                print(f"    docker exec {c} wp --allow-root plugin list --format={args.format} > {plugin_list_file_path}\n")
                # In dry run, we don't collect, so all_data[c] won't be populated here.
                # If display_pies is called, it will operate on empty or partially filled all_data.
                # We can add a placeholder if charts are expected in dry-run + use-existing-lists.
                # For now, if not using existing lists in dry run, all_data will be empty for this container.
                all_data[c] = [] # Add empty list for consistency in dry-run without collection
                continue 

            raw_collected = collect_and_save(c, args.format, out_dir)
            plugins = load_plugin_data(raw_collected, args.format)
            all_data[c] = plugins
            if raw_collected is not None: # Only print if collection was successful
                print(f"  → {len(plugins)} plugins saved to {plugin_list_file_path}")

    # Check if any plugin data was actually loaded or collected
    # any(all_data.values()) checks if any of the lists of plugins are non-empty
    # or if all_data itself is empty
    if not all_data or not any(all_data.values()):
        print("\nNo plugin data found or loaded across all containers. Cannot render charts.", file=sys.stderr)
        if not args.use_existing_lists and not args.dry_run:
             print(f"Check if reports were generated under {report_base} or if collection failed.")
        elif args.use_existing_lists:
             print(f"Ensure plugin list files exist in the expected locations under {report_base} and contain valid data.")
        sys.exit(0)

    should_render_charts = (not args.dry_run) or (args.dry_run and args.use_existing_lists)

    if should_render_charts:
        print("\nRendering charts...\n")
        display_pies(all_data) # This function now renders bar charts
        if not args.dry_run: # Covers both collection and use-existing-lists without dry_run
            print(f"\nReports and/or charts based on data from {report_base}")
        elif args.dry_run and args.use_existing_lists: # Explicitly for dry_run with existing lists
            print(f"\nCharts based on existing reports from {report_base} (Dry Run Mode)")

    elif args.dry_run and not args.use_existing_lists:
        print("\nDRY RUN: Chart rendering skipped (no collection performed and not using existing lists).")


if __name__ == "__main__":
    main()
