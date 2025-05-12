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

def display_summary_and_charts(all_data):
    # 1) Unique plugins across all containers
    unique = set()
    for plugins_list in all_data.values(): # Renamed to avoid conflict
        for p in plugins_list:
            name = p.get("name")
            if name:
                unique.add(name)
    print(f"Found {len(all_data)} containers")
    print(f"Total unique plugins across all containers: {len(unique)}\n")

    # 2) Plugins per container
    containers = list(all_data.keys())
    counts = [len(all_data[c]) for c in containers]
    plt.clear_figure()
    plt.bar(containers, counts, color="blue") # Using a single color for this bar chart
    plt.title("Plugins Installed per Container")
    plt.xlabel("Container")
    plt.ylabel("Plugin Count")
    plt.show()

    # 3) Overall status/update/auto_update stats aggregation
    stats = {
        "status": {"active":0, "inactive":0, "must-use":0, "active-network":0, "dropin":0},
        "update": {"none":0, "available":0, "unavailable":0},
        "auto_update": {"on":0, "off":0},
    }
    for plugins_list in all_data.values(): # Renamed to avoid conflict
        for p in plugins_list:
            st = p.get("status","").strip()
            if st in stats["status"]:
                stats["status"][st] += 1
            
            update_value = p.get("update") # Get raw value
            upd = "" 
            if isinstance(update_value, str):
                upd = update_value.strip()
            elif isinstance(update_value, bool):
                upd = "available" if update_value else "none"
            if upd in stats["update"]:
                stats["update"][upd] += 1
            
            auto_update_value = p.get("auto_update") # Get raw value
            au = "" 
            if isinstance(auto_update_value, str):
                au = auto_update_value.strip()
            elif isinstance(auto_update_value, bool):
                au = "on" if auto_update_value else "off"
            if au in stats["auto_update"]:
                stats["auto_update"][au] += 1

    # 4) Pie‐charts for each metric
    chart_configs = [
        {
            "key": "status",
            "title": "Plugin Status Distribution (Overall)",
            "color_map": { "active": "green", "inactive": "red", "must-use": "light_green", "active-network": "cyan", "dropin": "magenta" }
        },
        {
            "key": "update",
            "title": "Plugin Update Status (Overall)",
            "color_map": { "none": "green", "available": "red", "unavailable": "yellow" }
        },
        {
            "key": "auto_update",
            "title": "Auto-update On vs Off (Overall)",
            "color_map": { "on": "green", "off": "red" }
        }
    ]

    for config in chart_configs:
        plt.clear_figure()
        key = config["key"]
        title = config["title"]
        color_map = config["color_map"]

        filtered_items = {k: v for k, v in stats[key].items() if v > 0}
        if filtered_items:
            labels, values = zip(*filtered_items.items())
            pie_colors = [color_map.get(l, "blue") for l in labels] # Default to blue if label not in map
            
            plt.pie(values, labels=labels, colors=pie_colors)
            plt.title(title)
            plt.show()
        else:
            print(f"No data to display for {title}.")

def main():
    args = parse_args()
    rpt_dir = os.path.abspath(args.reports_dir)
    if not os.path.isdir(rpt_dir):
        print(f"ERROR: reports directory not found: {rpt_dir}", file=sys.stderr)
        sys.exit(1)

    all_data = {}

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
        all_data[name] = plugins

    if not all_data:
        print("No container reports found.", file=sys.stderr)
        sys.exit(0)

    display_summary_and_charts(all_data)

if __name__ == "__main__":
    main()