#!/usr/bin/env python3
import argparse
import csv
import json
import os
import sys
import re # For plotext output cleaning

try:
    import plotext as plt
except ImportError:
    print("Error: plotext library is required. Please install it using 'pip install plotext'.", file=sys.stderr)
    sys.exit(1)

# Conditional import for PDF generation
REPORTLAB_AVAILABLE = False
try:
    from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, PageBreak, Table, TableStyle
    from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
    from reportlab.lib.units import inch
    from reportlab.lib import colors
    from reportlab.lib.enums import TA_LEFT, TA_CENTER
    REPORTLAB_AVAILABLE = True
except ImportError:
    pass # reportlab is optional

def parse_args():
    p = argparse.ArgumentParser(
        description="Plot WordPress plugin stats from saved reports and optionally generate PDF.",
        add_help=False # Custom help to include PDF note
    )
    p.add_argument(
        "-h", "--help",
        action="help",
        default=argparse.SUPPRESS, # Prevents default help from showing with custom one
        help="Show this help message and exit."
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
        help="Format of the saved plugin-list files (default: json)"
    )
    p.add_argument(
        "--chart-type", "-C",
        choices=("bar", "pie"), # plotext uses simple_bar for bar charts
        default="bar",
        help="Chart type to render for distributions (bar or pie, default: bar)"
    )
    p.add_argument(
        "--print-pdf", "-p",
        action="store_true",
        help="Render the results as a PDF and write it to the reports directory. Requires 'reportlab'."
    )
    p.add_argument(
        "--render-individual-reports", "-i",
        action="store_true",
        help="Render stats and charts for each container individually."
    )
    p.add_argument(
        "--list-plugins", "-l",
        action="store_true",
        help="Render a text table of plugins, similar to 'wp plugin list'."
    )
    p.add_argument(
        "--filter-plugins-by-status", "-s",
        default=None,
        help="Comma-separated list of plugin statuses to filter by when using --list-plugins (e.g., active,inactive)."
    )
    
    args = p.parse_args()
    if args.print_pdf and not REPORTLAB_AVAILABLE:
        print("Error: --print-pdf flag requires the 'reportlab' library. Please install it ('pip install reportlab') and try again.", file=sys.stderr)
        sys.exit(1)
    return args

def load_plugin_data_from_file(path, fmt):
    """Return list of dicts for each plugin from a file."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = f.read()
    except FileNotFoundError:
        # This warning is now handled in the main loop
        return None
    except Exception as e:
        print(f"WARNING: Error reading plugin list file {path}: {e}", file=sys.stderr)
        return []

    if not raw:
        return []

    if fmt == "json":
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            print(f"WARNING: Could not decode JSON data from {path}.", file=sys.stderr)
            if raw:
                 print(f"Problematic raw data (first 100 chars): {raw[:100]}", file=sys.stderr)
            return []
    # csv
    lines = raw.splitlines()
    try:
        reader = csv.DictReader(lines)
        return list(reader)
    except Exception as e:
        print(f"WARNING: Could not parse CSV data from {path}: {e}", file=sys.stderr)
        return []

def generate_plugin_stats(plugins_list):
    """Generates aggregated statistics for a list of plugins."""
    stats = {
        "status": {"active": 0, "inactive": 0, "must-use": 0, "active-network": 0, "dropin": 0},
        "update": {"none": 0, "available": 0, "unavailable": 0, "version higher than expected": 0},
        "auto_update": {"on": 0, "off": 0},
    }
    for p in plugins_list:
        if not isinstance(p, dict): continue # Skip if data is malformed

        st = p.get("status", "").strip()
        if st in stats["status"]:
            stats["status"][st] += 1
        elif st: # Log unrecognized status if needed
            pass # print(f"INFO: Unrecognized plugin status '{st}' found.", file=sys.stderr)

        update_value = p.get("update")
        upd = ""
        if isinstance(update_value, str):
            upd = update_value.strip()
        elif isinstance(update_value, bool): # Handle boolean 'update' if it occurs
            upd = "available" if update_value else "none"
        
        if upd in stats["update"]:
            stats["update"][upd] += 1
        elif upd: # Log unrecognized update status
            pass # print(f"INFO: Unrecognized update status '{upd}' for plugin '{p.get('name', 'N/A')}'.", file=sys.stderr)
        
        auto_update_value = p.get("auto_update")
        au = ""
        if isinstance(auto_update_value, str):
            au = auto_update_value.strip()
        elif isinstance(auto_update_value, bool):
            au = "on" if auto_update_value else "off"

        if au in stats["auto_update"]:
            stats["auto_update"][au] += 1
        elif au: # Log unrecognized auto_update status
            pass # print(f"INFO: Unrecognized auto_update status '{au}' for plugin '{p.get('name', 'N/A')}'.", file=sys.stderr)
    return stats

def _clean_plotext_output(plot_str):
    # Remove ANSI escape codes
    ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
    return ansi_escape.sub('', plot_str)

def render_stats_charts(stats_data, chart_type, title_prefix="", for_pdf=False, pdf_elements=None, pdf_styles=None):
    """Renders distribution charts for status, update, and auto_update."""
    chart_configs = [
        {
            "key": "status", "title": "Plugin Status Distribution",
            "color_map": {"active": "green", "inactive": "red", "must-use": "light_green", "active-network": "cyan", "dropin": "magenta"}
        },
        {
            "key": "update",
            "title": "Plugin Update Status (Overall)",
            "color_map": {"none": "green", "available": "red", "unavailable": "yellow", "version higher than expected": "orange"}
        },
        {
            "key": "auto_update", "title": "Auto-update On vs Off",
            "color_map": {"on": "green", "off": "red"}
        }
    ]

    for config in chart_configs:
        plt.clear_figure()
        key, base_title, color_map = config["key"], config["title"], config["color_map"]
        full_title = f"{title_prefix}{base_title}"

        filtered_items = {k: v for k, v in stats_data[key].items() if v > 0}
        if not filtered_items:
            no_data_msg = f"No data to display for {full_title}."
            if for_pdf:
                pdf_elements.append(Paragraph(no_data_msg, pdf_styles['Normal']))
                pdf_elements.append(Spacer(1, 0.2 * inch))
            else:
                print(no_data_msg)
            continue

        labels, values = zip(*filtered_items.items())
        
        if chart_type == "pie":
            pie_colors = [color_map.get(l, "blue") for l in labels]
            plt.pie(values, labels=labels, colors=pie_colors)
        else: # Default to bar chart
            bar_colors = [color_map.get(l, "blue") for l in labels]
            plt.simple_bar(labels, values, color=bar_colors) # plotext uses simple_bar

        plt.title(full_title)

        if for_pdf:
            plot_str = _clean_plotext_output(plt.build())
            pdf_elements.append(Paragraph(full_title, pdf_styles['h3']))
            pdf_elements.append(Paragraph(plot_str.replace("\n", "<br/>\n"), pdf_styles['Code']))
            pdf_elements.append(Spacer(1, 0.2 * inch))
        else:
            plt.show()

def render_plugin_table(all_data, filter_statuses_str=None, for_pdf=False, pdf_elements=None, pdf_styles=None):
    """Renders a table of plugins, optionally filtered by status."""
    header = ["Container", "Plugin Name", "Status", "Version", "Update", "Auto-Update"]
    table_data = [header]
    
    filter_statuses_list = []
    if filter_statuses_str:
        filter_statuses_list = [s.strip().lower() for s in filter_statuses_str.split(',')]

    for container_name, plugins in sorted(all_data.items()):
        for p in plugins:
            if not isinstance(p, dict): continue
            status = p.get("status", "N/A").strip()
            if filter_statuses_list and status.lower() not in filter_statuses_list:
                continue
            
            row = [
                str(container_name), # Ensure all data is string for width calculation
                str(p.get("name", "N/A")),
                str(status),
                str(p.get("version", "N/A")),
                str(p.get("update", "N/A")),
                str(p.get("auto_update", "N/A"))
            ]
            table_data.append(row)

    if len(table_data) == 1: # Only header
        no_data_msg = "No plugins to display"
        if filter_statuses_list:
            no_data_msg += f" with status(es): {filter_statuses_str}"
        if for_pdf:
            pdf_elements.append(Paragraph(no_data_msg, pdf_styles['Normal']))
        else:
            print(no_data_msg)
        return

    if for_pdf:
        # Create a ReportLab Table
        # Adjust column widths as needed, this is a basic setup
        col_widths = [1.5*inch, 2*inch, 1*inch, 0.8*inch, 1*inch, 1*inch] 
        try:
            # For ReportLab, use the original data, not necessarily stringified for console
            pdf_table_data = [header]
            for container_name, plugins in sorted(all_data.items()):
                for p in plugins:
                    if not isinstance(p, dict): continue
                    status = p.get("status", "N/A").strip()
                    if filter_statuses_list and status.lower() not in filter_statuses_list:
                        continue
                    pdf_table_data.append([
                        container_name,
                        p.get("name", "N/A"),
                        status,
                        p.get("version", "N/A"),
                        p.get("update", "N/A"),
                        p.get("auto_update", "N/A")
                    ])

            t = Table(pdf_table_data, colWidths=col_widths)
            t.setStyle(TableStyle([
                ('BACKGROUND', (0, 0), (-1, 0), colors.grey),
                ('TEXTCOLOR', (0, 0), (-1, 0), colors.whitesmoke),
                ('ALIGN', (0, 0), (-1, -1), 'LEFT'),
                ('FONTNAME', (0, 0), (-1, 0), 'Helvetica-Bold'),
                ('BOTTOMPADDING', (0, 0), (-1, 0), 12),
                ('BACKGROUND', (0, 1), (-1, -1), colors.beige),
                ('GRID', (0, 0), (-1, -1), 1, colors.black)
            ]))
            pdf_elements.append(t)
            pdf_elements.append(Spacer(1, 0.2 * inch))
        except Exception as e: # Handle cases where table data might be problematic for reportlab
            pdf_elements.append(Paragraph(f"Error generating plugin table for PDF: {e}", pdf_styles['Normal']))
            # Fallback to text representation for PDF
            text_table_str = "\n".join([" | ".join(map(str, row)) for row in table_data]) # Use stringified table_data for fallback
            pdf_elements.append(Paragraph("Plugin List (Text Fallback):", pdf_styles['h3']))
            pdf_elements.append(Paragraph(text_table_str.replace("\n", "<br/>\n"), pdf_styles['Code']))

    else: # Console output
        # Calculate column widths
        num_cols = len(header)
        col_widths = [0] * num_cols
        for row_idx, row_data in enumerate(table_data):
            for col_idx, cell_data in enumerate(row_data):
                col_widths[col_idx] = max(col_widths[col_idx], len(str(cell_data)))

        # Print table with padding
        separator_line = "+-" + "-+-".join(["-" * w for w in col_widths]) + "-+"
        print(separator_line)
        for row_idx, row_data in enumerate(table_data):
            formatted_row = []
            for col_idx, cell_data in enumerate(row_data):
                formatted_row.append(str(cell_data).ljust(col_widths[col_idx]))
            print("| " + " | ".join(formatted_row) + " |")
            if row_idx == 0: # After header
                print(separator_line)
        print(separator_line)

def main():
    args = parse_args()
    rpt_dir = os.path.abspath(args.reports_dir)
    if not os.path.isdir(rpt_dir):
        print(f"ERROR: reports directory not found: {rpt_dir}", file=sys.stderr)
        sys.exit(1)

    all_data = {}
    container_subdirs = sorted([d for d in os.listdir(rpt_dir) if os.path.isdir(os.path.join(rpt_dir, d))])

    for name in container_subdirs:
        sub = os.path.join(rpt_dir, name)
        fn = os.path.join(sub, f"plugin-list.{args.format}")
        if not os.path.isfile(fn):
            print(f"WARNING: missing report for {name}: {fn}", file=sys.stderr)
            all_data[name] = [] # Ensure container key exists
            continue
        
        plugins = load_plugin_data_from_file(fn, args.format)
        if plugins is None: # File not found by load_plugin_data_from_file
             print(f"WARNING: report file not found for container {name}: {fn}", file=sys.stderr)
             all_data[name] = []
        else:
            all_data[name] = plugins


    if not all_data or not any(all_data.values()): # Check if any data was loaded
        print("No container reports found or no plugin data loaded.", file=sys.stderr)
        sys.exit(0)

    pdf_elements = []
    pdf_styles = None
    if args.print_pdf:
        pdf_styles = getSampleStyleSheet()
        # Add a monospaced style for plotext output
        pdf_styles.add(ParagraphStyle(name='Code', fontName='Courier', fontSize=8, leading=8.8, alignment=TA_LEFT))
        pdf_elements.append(Paragraph("WordPress Plugin Report", pdf_styles['h1']))
        pdf_elements.append(Spacer(1, 0.3 * inch))

    # --- Feature Execution ---
    action_taken = False

    # Render global plugin table only if --list-plugins is true AND --render-individual-reports is false
    if args.list_plugins and not args.render_individual_reports:
        action_taken = True
        title = "Overall Plugin Listing"
        if args.print_pdf:
            pdf_elements.append(Paragraph(title, pdf_styles['h2']))
        else:
            print(f"\n--- {title} ---")
        render_plugin_table(all_data, args.filter_plugins_by_status, args.print_pdf, pdf_elements, pdf_styles)
        if not args.print_pdf:
            print(f"--- End of {title} ---\n")

    if args.render_individual_reports:
        action_taken = True
        # Add a general title for individual reports section in PDF, if not listing plugins (which has its own overall title)
        # This H2 is for the "Individual Container Plugin Statistics" section as a whole.
        # If args.list_plugins is also true, each container's table will get an H3 later.
        if args.print_pdf and not (args.list_plugins and not args.render_individual_reports): # Avoid double titling if global list was already printed
            # This condition ensures the "Individual..." H2 is printed if we are doing individual reports,
            # unless a global plugin list was the *only* thing printed before this section.
            # A simpler approach might be to always print it if args.render_individual_reports and args.print_pdf
            if not any(isinstance(el, Paragraph) and el.style.name == 'h2' for el in pdf_elements if hasattr(el, 'style')): # Check if an H2 already exists
                 # Or more simply, if the "Overall Plugin Listing" H2 was not just added.
                 # The original condition: `if not args.list_plugins and args.print_pdf:`
                 # Let's refine this: if we are doing individual reports, we want a section title for it.
                 pass # The per-container H2 "Statistics for {container_name}" will serve as section titles.

        for container_name, c_data in sorted(all_data.items()):
            if not c_data: 
                msg = f"No plugin data for container: {container_name}"
                if args.print_pdf:
                    pdf_elements.append(Paragraph(msg, pdf_styles['Normal']))
                    pdf_elements.append(Spacer(1, 0.2 * inch)) # Add spacer after no data message
                else:
                    print(f"\n--- {msg} ---")
                if args.print_pdf: # Still add page break if it's an empty container in a list of individuals
                    pdf_elements.append(PageBreak())
                continue

            title_prefix = f"{container_name} - "
            if args.print_pdf:
                pdf_elements.append(Paragraph(f"Statistics for {container_name}", pdf_styles['h2']))
            else:
                print(f"\n--- Statistics for {container_name} ---")
            
            container_stats = generate_plugin_stats(c_data)
            render_stats_charts(container_stats, args.chart_type, title_prefix, args.print_pdf, pdf_elements, pdf_styles)

            if args.list_plugins: # Render table for this specific container
                table_title = f"Plugin List for {container_name}"
                if args.print_pdf:
                    pdf_elements.append(Paragraph(table_title, pdf_styles['h3'])) # Use H3 for sub-section
                else:
                    print(f"\n--- {table_title} ---")
                
                render_plugin_table({container_name: c_data}, args.filter_plugins_by_status, args.print_pdf, pdf_elements, pdf_styles)
                
                if not args.print_pdf:
                    print(f"--- End of {table_title} ---\n")
            
            if args.print_pdf:
                pdf_elements.append(PageBreak())
    
    # Default: Overall summary if no other specific report rendering action was taken
    if not action_taken:
        if args.print_pdf:
            pdf_elements.append(Paragraph("Overall Plugin Summary", pdf_styles['h2']))
        else:
            print("\n--- Overall Plugin Summary ---")

        # 1. Unique plugins count
        unique_plugins = set()
        flat_plugin_list_for_stats = []
        for plugins_list_for_container in all_data.values():
            for p_dict in plugins_list_for_container:
                 if isinstance(p_dict, dict) and "name" in p_dict:
                    unique_plugins.add(p_dict["name"])
                    flat_plugin_list_for_stats.append(p_dict) # For overall stats

        unique_msg = f"Total unique plugins across all containers: {len(unique_plugins)}"
        if args.print_pdf:
            pdf_elements.append(Paragraph(unique_msg, pdf_styles['Normal']))
            pdf_elements.append(Spacer(1, 0.2 * inch))
        else:
            print(unique_msg)

        # 2. Plugins per container bar chart
        plt.clear_figure()
        container_names_for_chart = list(all_data.keys())
        plugin_counts_for_chart = [len(all_data[c]) for c in container_names_for_chart]
        
        if container_names_for_chart and plugin_counts_for_chart: # Ensure there's data
            plt.simple_bar(container_names_for_chart, plugin_counts_for_chart, color="blue")
            plt.title("Plugins Installed per Container")
            # plt.xlabel("Container") # plotext simple_bar uses labels directly
            # plt.ylabel("Plugin Count") # Not directly supported by simple_bar title
            if args.print_pdf:
                plot_str = _clean_plotext_output(plt.build())
                pdf_elements.append(Paragraph("Plugins Installed per Container", pdf_styles['h3']))
                pdf_elements.append(Paragraph(plot_str.replace("\n", "<br/>\n"), pdf_styles['Code']))
                pdf_elements.append(Spacer(1, 0.2 * inch))
            else:
                plt.show()
        else:
            no_data_per_container_msg = "No data for 'Plugins Installed per Container' chart."
            if args.print_pdf:
                 pdf_elements.append(Paragraph(no_data_per_container_msg, pdf_styles['Normal']))
            else:
                print(no_data_per_container_msg)


        # 3) Overall status/update/auto_update stats aggregation
        stats = {
            "status": {"active": 0, "inactive": 0, "must-use": 0, "active-network": 0, "dropin": 0},
            "update": {"none": 0, "available": 0, "unavailable": 0, "version higher than expected": 0},
            "auto_update": {"on": 0, "off": 0},
        }
        for plugins_list in all_data.values(): # Renamed to avoid conflict
            for p in plugins_list:
                if isinstance(p, dict):
                    st = p.get("status", "").strip()
                    if st in stats["status"]:
                        stats["status"][st] += 1
                    
                    # Handle 'update' field
                    update_val = p.get("update")
                    upd_str = ""
                    if isinstance(update_val, str):
                        upd_str = update_val.strip()
                    elif isinstance(update_val, bool):
                        upd_str = "available" if update_val else "none"
                    
                    if upd_str in stats["update"]:
                        stats["update"][upd_str] += 1

                    # Handle 'auto_update' field
                    auto_update_val = p.get("auto_update")
                    au_str = ""
                    if isinstance(auto_update_val, str):
                        au_str = auto_update_val.strip()
                    elif isinstance(auto_update_val, bool):
                        au_str = "on" if auto_update_val else "off"

                    if au_str in stats["auto_update"]:
                        stats["auto_update"][au_str] += 1

        render_stats_charts(stats, args.chart_type, "Overall - ", args.print_pdf, pdf_elements, pdf_styles)

    # --- PDF Generation ---
    if args.print_pdf:
        if not pdf_elements: # Check if anything was added to the story
            print("No content was generated for the PDF report.", file=sys.stderr)
        else:
            pdf_filename = os.path.join(rpt_dir, "wp_plugins_report.pdf")
            doc = SimpleDocTemplate(pdf_filename)
            try:
                doc.build(pdf_elements)
                print(f"PDF report generated: {pdf_filename}")
            except Exception as e:
                print(f"Error generating PDF: {e}", file=sys.stderr)
                print("Ensure that the data and plotext output are compatible with ReportLab's Paragraph flowable.", file=sys.stderr)

if __name__ == "__main__":
    main()