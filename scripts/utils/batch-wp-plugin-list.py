#!/usr/bin/env python3
"""
Batch runner to collect `wp plugin list` from each container,
save the raw output, and display summary pie‐charts.
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
        help="Show what would be done without executing commands."
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
            return []
    # csv
    lines = raw.splitlines()
    reader = csv.DictReader(lines)
    return list(reader)

def display_pies(all_data):
    # aggregate across all containers
    stats = {
        "status": {"active":0, "inactive":0, "must-use":0, "active-network":0},
        "update": {"none":0, "available":0, "unavailable":0},
        "auto_update": {"on":0, "off":0},
    }

    for plugins in all_data.values():
        for p in plugins:
            st = p.get("status", "").strip()
            if st in stats["status"]:
                stats["status"][st] += 1
            upd = p.get("update", "").strip()
            if upd in stats["update"]:
                stats["update"][upd] += 1
            au = p.get("auto_update", "").strip()
            if au in stats["auto_update"]:
                stats["auto_update"][au] += 1

    # 1) Status distribution
    plt.clear_figure()
    labels, values = zip(*stats["status"].items())
    plt.pie(values, labels=labels)
    plt.title("Plugin Status Distribution")
    plt.show()

    # 2) Update availability
    plt.clear_figure()
    labels, values = zip(*stats["update"].items())
    plt.pie(values, labels=labels)
    plt.title("Plugin Update Status")
    plt.show()

    # 3) Auto-update settings
    plt.clear_figure()
    labels, values = zip(*stats["auto_update"].items())
    plt.pie(values, labels=labels)
    plt.title("Auto-update On vs Off")
    plt.show()

def main():
    args = parse_args()
    if args.dry_run:
        print("*** DRY RUN MODE: no commands will be executed ***\n")

    report_base = os.path.join(os.path.abspath(args.target_dir), "wp-plugin-update-reports")
    containers = load_containers(args.container_list_file)
    if not containers:
        print("No WordPress containers found.", file=sys.stderr)
        sys.exit(0)

    all_data = {}
    for c in containers:
        print(f"Collecting from {c}...")
        out_dir = os.path.join(report_base, c)
        if args.dry_run:
            print(f"  DRY RUN: would create dir '{out_dir}' and run:")
            print(f"    docker exec {c} wp --allow-root plugin list --format={args.format} > {out_dir}/plugin-list.{args.format}\n")
            continue

        raw = collect_and_save(c, args.format, out_dir)
        plugins = load_plugin_data(raw, args.format)
        all_data[c] = plugins
        print(f"  → {len(plugins)} plugins saved to {out_dir}/plugin-list.{args.format}")

    if not args.dry_run:
        print("\nRendering pie charts...\n")
        display_pies(all_data)
        print(f"\nReports written under {report_base}")

if __name__ == "__main__":
    main()