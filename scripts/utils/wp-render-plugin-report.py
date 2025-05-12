#!/usr/bin/env python3
"""
filepath: scripts/utils/plot-plugin-report.py

Scan a directory of WP plugin‐list reports and plot plugin counts per container,
also print total unique plugins across all containers.

Requires: plotext (pip install plotext)
"""
import argparse
import csv
import json
import os
import sys

import plotext as plt

def parse_args():
    p = argparse.ArgumentParser(
        description="Plot WordPress plugin stats from saved reports",
        add_help=False
    )
    p.add_argument(
        "-h", "--help",
        action="help",
        help="Show this help message and exit"
    )
    p.add_argument(
        "--reports-dir", "-r",
        required=True,
        help="Base directory under which each container has a subdir containing plugin-list.{json,csv}"
    )
    p.add_argument(
        "--format", "-f",
        choices=("json", "csv"),
        default="json",
        help="Format of the saved plugin‐list files (default: json)"
    )
    p.add_argument(
        "--chart-type", "-C",
        choices=("bar", "pie"),
        default="bar",
        help="Chart type to render (bar or pie)"
    )
    return p.parse_args()

def load_plugins_from_file(path, fmt):
    plugins = []
    raw = open(path, "r", encoding="utf-8").read()
    if fmt == "json":
        try:
            data = json.loads(raw)
            # wp plugin list json has objects with at least 'name'
            plugins = [item.get("name") for item in data if "name" in item]
        except json.JSONDecodeError:
            pass
    else:  # csv
        reader = csv.reader(raw.splitlines())
        rows = list(reader)
        # skip header row
        for row in rows[1:]:
            if row:
                plugins.append(row[0])  # assume first column is plugin slug
    return plugins

def main():
    args = parse_args()
    rpt_dir = os.path.abspath(args.reports_dir)
    if not os.path.isdir(rpt_dir):
        print(f"ERROR: reports directory not found: {rpt_dir}", file=sys.stderr)
        sys.exit(1)

    containers = []
    counts = []
    unique = set()

    # expect one subdirectory per container
    for name in sorted(os.listdir(rpt_dir)):
        sub = os.path.join(rpt_dir, name)
        if not os.path.isdir(sub):
            continue
        fn = os.path.join(sub, f"plugin-list.{args.format}")
        if not os.path.isfile(fn):
            print(f"WARNING: missing report for {name}: {fn}", file=sys.stderr)
            continue
        plugins = load_plugins_from_file(fn, args.format)
        cnt = len(plugins)
        containers.append(name)
        counts.append(cnt)
        unique.update(plugins)

    if not containers:
        print("No container reports found.", file=sys.stderr)
        sys.exit(0)

    # print summary
    print(f"Found {len(containers)} containers")
    print(f"Total unique plugins across all containers: {len(unique)}\n")

    # plot
    plt.clear_figure()
    if args.chart_type == "bar":
        plt.bar(containers, counts, label="Plugins per container")
        plt.title("Plugins Installed per Container")
        plt.xlabel("Container")
        plt.ylabel("Plugin Count")
    else:
        plt.pie(counts, labels=containers)
        plt.title("Plugin Count Distribution")
    plt.show()

if __name__ == "__main__":
    main()