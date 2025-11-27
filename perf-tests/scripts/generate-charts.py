#!/usr/bin/env python3
"""
generate-charts.py - Generate performance test charts

Usage: ./generate-charts.py <results_dir> [timestamp]

Arguments:
  results_dir  Directory containing raw test results
  timestamp    Optional timestamp for output filenames (format: YYYYMMDD-HHMMSS)

Generates:
- Static PNG charts using matplotlib (for reports/documentation)
- Interactive HTML dashboard using plotly (for browser viewing)
- Time-series charts showing per-minute metric data
"""

import json
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

import matplotlib.pyplot as plt
import matplotlib.dates as mdates
import pandas as pd
import plotly.graph_objects as go
from plotly.subplots import make_subplots

# Color palette - vibrant, distinct colors
COLORS = {
    'primary': '#00D9FF',      # Cyan
    'secondary': '#FF6B6B',    # Coral
    'tertiary': '#4ECDC4',     # Teal
    'quaternary': '#FFE66D',   # Yellow
    'accent': '#C44DFF',       # Purple
    'success': '#7AE582',      # Green
    'warning': '#FFA07A',      # Light salmon
    'background': '#1a1a2e',   # Dark blue
    'surface': '#16213e',      # Slightly lighter blue
    'text': '#eaeaea',         # Light gray
}

# Matplotlib dark theme configuration
plt.rcParams.update({
    'figure.facecolor': COLORS['background'],
    'axes.facecolor': COLORS['surface'],
    'axes.edgecolor': COLORS['text'],
    'axes.labelcolor': COLORS['text'],
    'text.color': COLORS['text'],
    'xtick.color': COLORS['text'],
    'ytick.color': COLORS['text'],
    'grid.color': '#333355',
    'grid.alpha': 0.5,
    'legend.facecolor': COLORS['surface'],
    'legend.edgecolor': COLORS['text'],
    'font.family': 'sans-serif',
    'font.size': 11,
})


def load_report_metadata(results_dir: Path) -> dict[str, Any]:
    """Load the most recent report file to get metadata."""
    report_files = sorted(results_dir.glob('report-*.json'), reverse=True)
    if report_files:
        try:
            with open(report_files[0]) as f:
                report = json.load(f)
                return report.get('report_metadata', {})
        except (json.JSONDecodeError, IOError) as e:
            print(f"Warning: Could not parse report file: {e}")
    return {}


def get_report_name(metadata: dict[str, Any]) -> str:
    """Extract a clean report name from metadata."""
    cluster_info = metadata.get('cluster', {})
    cluster_name = cluster_info.get('name', '')
    
    # Extract the first part before '/' if present (e.g., "tempo-perf-test")
    if cluster_name:
        name_parts = cluster_name.split('/')
        return name_parts[0] if name_parts else cluster_name
    
    # Fallback to generated timestamp
    generated_at = metadata.get('generated_at', '')
    if generated_at:
        return f"Report {generated_at[:10]}"
    
    return "Tempo Performance Test"


def load_test_results(results_dir: Path) -> list[dict[str, Any]]:
    """Load all test results from raw JSON files."""
    raw_dir = results_dir / 'raw'
    if not raw_dir.exists():
        print(f"Error: Raw results directory not found: {raw_dir}")
        sys.exit(1)

    results = []
    for json_file in sorted(raw_dir.glob('*.json')):
        try:
            with open(json_file) as f:
                data = json.load(f)
                results.append(data)
        except json.JSONDecodeError as e:
            print(f"Warning: Could not parse {json_file}: {e}")
            continue

    if not results:
        print(f"Error: No valid JSON files found in {raw_dir}")
        sys.exit(1)

    return results


def results_to_dataframe(results: list[dict[str, Any]]) -> pd.DataFrame:
    """Convert test results to a pandas DataFrame."""
    rows = []
    for r in results:
        # Get bytes_per_second from metrics (actual measured value)
        bytes_per_sec = r.get('metrics', {}).get('throughput', {}).get('bytes_per_second', 0)
        mb_per_sec_actual = bytes_per_sec / (1024 * 1024) if bytes_per_sec else 0
        
        row = {
            'load_name': r.get('load_name', 'unknown'),
            'mb_per_sec': r.get('config', {}).get('mb_per_sec', 0),  # Target rate from config
            'mb_per_sec_actual': mb_per_sec_actual,  # Actual measured rate
            'bytes_per_sec': bytes_per_sec,
            'p50_ms': r.get('metrics', {}).get('query_latencies', {}).get('p50_seconds', 0) * 1000,
            'p90_ms': r.get('metrics', {}).get('query_latencies', {}).get('p90_seconds', 0) * 1000,
            'p99_ms': r.get('metrics', {}).get('query_latencies', {}).get('p99_seconds', 0) * 1000,
            'cpu_cores': r.get('metrics', {}).get('resources', {}).get('avg_cpu_cores', 0),
            'memory_gb': r.get('metrics', {}).get('resources', {}).get('max_memory_gb', 0),
            'spans_per_sec': r.get('metrics', {}).get('throughput', {}).get('spans_per_second', 0),
            'error_rate': r.get('metrics', {}).get('errors', {}).get('error_rate_percent', 0),
            'dropped_spans': r.get('metrics', {}).get('errors', {}).get('dropped_spans_per_second', 0),
        }
        rows.append(row)

    df = pd.DataFrame(rows)
    # Sort by MB/s for consistent ordering
    df = df.sort_values('mb_per_sec').reset_index(drop=True)
    return df


def extract_timeseries_data(results: list[dict[str, Any]]) -> pd.DataFrame:
    """Extract time-series data from test results into a DataFrame."""
    rows = []
    
    for r in results:
        load_name = r.get('load_name', 'unknown')
        timeseries = r.get('timeseries', {})
        
        # Skip if no timeseries data
        if not timeseries or not timeseries.get('cpu_cores'):
            continue
        
        # Get all timeseries arrays
        cpu_data = {item['timestamp']: item['value'] for item in timeseries.get('cpu_cores', [])}
        memory_data = {item['timestamp']: item['value'] for item in timeseries.get('memory_gb', [])}
        spans_data = {item['timestamp']: item['value'] for item in timeseries.get('spans_per_second', [])}
        bytes_data = {item['timestamp']: item['value'] for item in timeseries.get('bytes_per_second', [])}
        p50_data = {item['timestamp']: item['value'] for item in timeseries.get('p50_latency_seconds', [])}
        p90_data = {item['timestamp']: item['value'] for item in timeseries.get('p90_latency_seconds', [])}
        p99_data = {item['timestamp']: item['value'] for item in timeseries.get('p99_latency_seconds', [])}
        failures_data = {item['timestamp']: item['value'] for item in timeseries.get('query_failures_per_second', [])}
        dropped_data = {item['timestamp']: item['value'] for item in timeseries.get('dropped_spans_per_second', [])}
        
        # Use CPU timestamps as reference
        for ts in sorted(cpu_data.keys()):
            rows.append({
                'load_name': load_name,
                'timestamp': ts,
                'datetime': datetime.fromtimestamp(ts),
                'cpu_cores': cpu_data.get(ts, 0),
                'memory_gb': memory_data.get(ts, 0),
                'spans_per_sec': spans_data.get(ts, 0),
                'bytes_per_sec': bytes_data.get(ts, 0),
                'p50_ms': p50_data.get(ts, 0) * 1000,
                'p90_ms': p90_data.get(ts, 0) * 1000,
                'p99_ms': p99_data.get(ts, 0) * 1000,
                'query_failures': failures_data.get(ts, 0),
                'dropped_spans': dropped_data.get(ts, 0),
            })
    
    if not rows:
        return pd.DataFrame()
    
    df = pd.DataFrame(rows)
    df = df.sort_values(['load_name', 'timestamp']).reset_index(drop=True)
    
    # Add relative minute column per load
    for load in df['load_name'].unique():
        mask = df['load_name'] == load
        min_ts = df.loc[mask, 'timestamp'].min()
        df.loc[mask, 'minute'] = ((df.loc[mask, 'timestamp'] - min_ts) / 60).astype(int) + 1
    
    return df


# =============================================================================
# Static Chart Generation (matplotlib)
# =============================================================================

def create_latency_chart(df: pd.DataFrame, output_dir: Path, report_name: str, timestamp: str) -> None:
    """Create latency comparison bar chart."""
    fig, ax = plt.subplots(figsize=(12, 7))

    x = range(len(df))
    width = 0.25

    bars1 = ax.bar([i - width for i in x], df['p50_ms'], width,
                   label='P50', color=COLORS['primary'], edgecolor='white', linewidth=0.5)
    bars2 = ax.bar(x, df['p90_ms'], width,
                   label='P90', color=COLORS['secondary'], edgecolor='white', linewidth=0.5)
    bars3 = ax.bar([i + width for i in x], df['p99_ms'], width,
                   label='P99', color=COLORS['tertiary'], edgecolor='white', linewidth=0.5)

    ax.set_xlabel('Load Configuration', fontsize=12, fontweight='bold')
    ax.set_ylabel('Latency (ms)', fontsize=12, fontweight='bold')
    ax.set_title(f'{report_name}\nQuery Latency by Load Level', fontsize=14, fontweight='bold', pad=20)
    ax.set_xticks(x)
    ax.set_xticklabels([f"{row['load_name']}\n({row['mb_per_sec']} MB/s)" for _, row in df.iterrows()])
    ax.legend(loc='upper left', framealpha=0.9)
    ax.grid(axis='y', linestyle='--', alpha=0.7)

    # Add value labels on bars
    for bars in [bars1, bars2, bars3]:
        for bar in bars:
            height = bar.get_height()
            if height > 0:
                ax.annotate(f'{height:.1f}',
                            xy=(bar.get_x() + bar.get_width() / 2, height),
                            xytext=(0, 3), textcoords="offset points",
                            ha='center', va='bottom', fontsize=8, color=COLORS['text'])

    plt.tight_layout()
    output_path = output_dir / f'report-{timestamp}-latency_comparison.png'
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"  ✅ Created: {output_path}")


def create_resources_chart(df: pd.DataFrame, output_dir: Path, report_name: str, timestamp: str) -> None:
    """Create resource usage dual-axis chart."""
    fig, ax1 = plt.subplots(figsize=(12, 7))

    x = range(len(df))
    width = 0.35

    # CPU bars on primary axis
    bars1 = ax1.bar([i - width/2 for i in x], df['cpu_cores'], width,
                    label='CPU (cores)', color=COLORS['primary'], edgecolor='white', linewidth=0.5)
    ax1.set_xlabel('Load Configuration', fontsize=12, fontweight='bold')
    ax1.set_ylabel('CPU (cores)', fontsize=12, fontweight='bold', color=COLORS['primary'])
    ax1.tick_params(axis='y', labelcolor=COLORS['primary'])

    # Memory bars on secondary axis
    ax2 = ax1.twinx()
    bars2 = ax2.bar([i + width/2 for i in x], df['memory_gb'], width,
                    label='Memory (GB)', color=COLORS['secondary'], edgecolor='white', linewidth=0.5)
    ax2.set_ylabel('Memory (GB)', fontsize=12, fontweight='bold', color=COLORS['secondary'])
    ax2.tick_params(axis='y', labelcolor=COLORS['secondary'])

    ax1.set_title(f'{report_name}\nResource Usage by Load Level', fontsize=14, fontweight='bold', pad=20)
    ax1.set_xticks(x)
    ax1.set_xticklabels([f"{row['load_name']}\n({row['mb_per_sec']} MB/s)" for _, row in df.iterrows()])

    # Combined legend
    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc='upper left', framealpha=0.9)

    ax1.grid(axis='y', linestyle='--', alpha=0.5)

    plt.tight_layout()
    output_path = output_dir / f'report-{timestamp}-resource_usage.png'
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"  ✅ Created: {output_path}")


def create_throughput_chart(df: pd.DataFrame, output_dir: Path, report_name: str, timestamp: str) -> None:
    """Create throughput analysis chart showing spans/sec by load level."""
    fig, ax = plt.subplots(figsize=(12, 7))

    x = range(len(df))
    width = 0.6

    bars = ax.bar(x, df['spans_per_sec'], width,
                  label='Actual Spans/sec', color=COLORS['success'],
                  edgecolor='white', linewidth=0.5)

    ax.set_xlabel('Load Configuration', fontsize=12, fontweight='bold')
    ax.set_ylabel('Spans per Second', fontsize=12, fontweight='bold')
    ax.set_title(f'{report_name}\nThroughput (Spans/sec) by Load Level', fontsize=14, fontweight='bold', pad=20)
    ax.set_xticks(x)
    ax.set_xticklabels([f"{row['load_name']}\n({row['mb_per_sec']} MB/s)" for _, row in df.iterrows()])
    ax.legend(loc='upper left', framealpha=0.9)
    ax.grid(axis='y', linestyle='--', alpha=0.7)

    # Add value labels on bars
    for bar in bars:
        height = bar.get_height()
        if height > 0:
            ax.annotate(f'{height:.0f}',
                        xy=(bar.get_x() + bar.get_width() / 2, height),
                        xytext=(0, 5), textcoords="offset points",
                        ha='center', va='bottom', fontsize=10,
                        color=COLORS['text'], fontweight='bold')

    plt.tight_layout()
    output_path = output_dir / f'report-{timestamp}-throughput_analysis.png'
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"  ✅ Created: {output_path}")


def create_error_chart(df: pd.DataFrame, output_dir: Path, report_name: str, timestamp: str) -> None:
    """Create error rates chart."""
    fig, ax1 = plt.subplots(figsize=(12, 7))

    x = range(len(df))
    width = 0.35

    # Error rate bars
    bars1 = ax1.bar([i - width/2 for i in x], df['error_rate'], width,
                    label='Error Rate (%)', color=COLORS['secondary'],
                    edgecolor='white', linewidth=0.5)
    ax1.set_xlabel('Load Configuration', fontsize=12, fontweight='bold')
    ax1.set_ylabel('Error Rate (%)', fontsize=12, fontweight='bold', color=COLORS['secondary'])
    ax1.tick_params(axis='y', labelcolor=COLORS['secondary'])

    # Dropped spans on secondary axis
    ax2 = ax1.twinx()
    bars2 = ax2.bar([i + width/2 for i in x], df['dropped_spans'], width,
                    label='Dropped Spans/sec', color=COLORS['accent'],
                    edgecolor='white', linewidth=0.5)
    ax2.set_ylabel('Dropped Spans/sec', fontsize=12, fontweight='bold', color=COLORS['accent'])
    ax2.tick_params(axis='y', labelcolor=COLORS['accent'])

    ax1.set_title(f'{report_name}\nError Metrics by Load Level', fontsize=14, fontweight='bold', pad=20)
    ax1.set_xticks(x)
    ax1.set_xticklabels([f"{row['load_name']}\n({row['mb_per_sec']} MB/s)" for _, row in df.iterrows()])

    # Combined legend
    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc='upper left', framealpha=0.9)

    ax1.grid(axis='y', linestyle='--', alpha=0.5)

    plt.tight_layout()
    output_path = output_dir / f'report-{timestamp}-error_metrics.png'
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"  ✅ Created: {output_path}")


def create_bytes_ingested_chart(df: pd.DataFrame, output_dir: Path, report_name: str, timestamp: str) -> None:
    """Create bytes ingested comparison bar chart showing target vs actual MB/s."""
    fig, ax = plt.subplots(figsize=(12, 7))

    x = range(len(df))
    width = 0.35

    bars1 = ax.bar([i - width/2 for i in x], df['mb_per_sec'], width,
                   label='Target MB/s', color=COLORS['quaternary'],
                   edgecolor='white', linewidth=0.5, alpha=0.7)
    bars2 = ax.bar([i + width/2 for i in x], df['mb_per_sec_actual'], width,
                   label='Actual MB/s', color=COLORS['primary'],
                   edgecolor='white', linewidth=0.5)

    ax.set_xlabel('Load Configuration', fontsize=12, fontweight='bold')
    ax.set_ylabel('Ingestion Rate (MB/s)', fontsize=12, fontweight='bold')
    ax.set_title(f'{report_name}\nBytes Ingested: Target vs Actual', fontsize=14, fontweight='bold', pad=20)
    ax.set_xticks(x)
    ax.set_xticklabels([f"{row['load_name']}\n({row['mb_per_sec']} MB/s)" for _, row in df.iterrows()])
    ax.legend(loc='upper left', framealpha=0.9)
    ax.grid(axis='y', linestyle='--', alpha=0.7)

    # Add efficiency percentage and value labels
    for i, (_, row) in enumerate(df.iterrows()):
        # Add value label on target bar
        ax.annotate(f'{row["mb_per_sec"]:.1f}',
                    xy=(i - width/2, row['mb_per_sec']),
                    xytext=(0, 3), textcoords="offset points",
                    ha='center', va='bottom', fontsize=9, color=COLORS['text'])
        
        # Add value label on actual bar
        ax.annotate(f'{row["mb_per_sec_actual"]:.2f}',
                    xy=(i + width/2, row['mb_per_sec_actual']),
                    xytext=(0, 3), textcoords="offset points",
                    ha='center', va='bottom', fontsize=9, color=COLORS['text'])
        
        # Add efficiency percentage above
        if row['mb_per_sec'] > 0:
            efficiency = (row['mb_per_sec_actual'] / row['mb_per_sec']) * 100
            max_val = max(row['mb_per_sec'], row['mb_per_sec_actual'])
            ax.annotate(f'{efficiency:.0f}%',
                        xy=(i, max_val),
                        xytext=(0, 15), textcoords="offset points",
                        ha='center', va='bottom', fontsize=10,
                        color=COLORS['success'] if efficiency >= 90 else COLORS['warning'],
                        fontweight='bold')

    plt.tight_layout()
    output_path = output_dir / f'report-{timestamp}-bytes_ingested.png'
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"  ✅ Created: {output_path}")


def generate_static_charts(df: pd.DataFrame, output_dir: Path, report_name: str, timestamp: str) -> None:
    """Generate all static PNG charts."""
    print("\n📊 Generating static charts (PNG)...")
    charts_dir = output_dir / 'charts'
    charts_dir.mkdir(parents=True, exist_ok=True)

    create_latency_chart(df, charts_dir, report_name, timestamp)
    create_resources_chart(df, charts_dir, report_name, timestamp)
    create_throughput_chart(df, charts_dir, report_name, timestamp)
    create_error_chart(df, charts_dir, report_name, timestamp)
    create_bytes_ingested_chart(df, charts_dir, report_name, timestamp)


# =============================================================================
# Time-Series Chart Generation (matplotlib)
# =============================================================================

LOAD_COLORS = [COLORS['primary'], COLORS['secondary'], COLORS['tertiary'], 
               COLORS['quaternary'], COLORS['accent'], COLORS['success']]


def create_timeseries_latency_chart(ts_df: pd.DataFrame, output_dir: Path, report_name: str, timestamp: str) -> None:
    """Create time-series latency chart showing P50/P90/P99 over time."""
    if ts_df.empty:
        return
    
    fig, axes = plt.subplots(3, 1, figsize=(14, 10), sharex=True)
    
    loads = ts_df['load_name'].unique()
    
    for idx, (ax, metric, title) in enumerate(zip(
        axes, 
        ['p50_ms', 'p90_ms', 'p99_ms'],
        ['P50 Latency', 'P90 Latency', 'P99 Latency']
    )):
        for i, load in enumerate(loads):
            load_data = ts_df[ts_df['load_name'] == load]
            ax.plot(load_data['minute'], load_data[metric], 
                   label=load, color=LOAD_COLORS[i % len(LOAD_COLORS)],
                   linewidth=2, marker='o', markersize=3)
        
        ax.set_ylabel(f'{title} (ms)', fontsize=11, fontweight='bold')
        ax.set_title(f'{title} Over Time', fontsize=12, fontweight='bold')
        ax.legend(loc='upper right', framealpha=0.9)
        ax.grid(True, linestyle='--', alpha=0.7)
    
    axes[0].set_title(f'{report_name}\nP50 Latency Over Time', fontsize=12, fontweight='bold')
    axes[-1].set_xlabel('Time (minutes)', fontsize=11, fontweight='bold')
    
    plt.tight_layout()
    output_path = output_dir / f'report-{timestamp}-timeseries_latency.png'
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"  ✅ Created: {output_path}")


def create_timeseries_resources_chart(ts_df: pd.DataFrame, output_dir: Path, report_name: str, timestamp: str) -> None:
    """Create time-series resource usage chart showing CPU and memory over time."""
    if ts_df.empty:
        return
    
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(14, 8), sharex=True)
    
    loads = ts_df['load_name'].unique()
    
    # CPU chart
    for i, load in enumerate(loads):
        load_data = ts_df[ts_df['load_name'] == load]
        ax1.plot(load_data['minute'], load_data['cpu_cores'], 
                label=load, color=LOAD_COLORS[i % len(LOAD_COLORS)],
                linewidth=2, marker='o', markersize=3)
    
    ax1.set_ylabel('CPU (cores)', fontsize=11, fontweight='bold')
    ax1.set_title(f'{report_name}\nCPU Usage Over Time', fontsize=12, fontweight='bold')
    ax1.legend(loc='upper right', framealpha=0.9)
    ax1.grid(True, linestyle='--', alpha=0.7)
    
    # Memory chart
    for i, load in enumerate(loads):
        load_data = ts_df[ts_df['load_name'] == load]
        ax2.plot(load_data['minute'], load_data['memory_gb'], 
                label=load, color=LOAD_COLORS[i % len(LOAD_COLORS)],
                linewidth=2, marker='o', markersize=3)
    
    ax2.set_ylabel('Memory (GB)', fontsize=11, fontweight='bold')
    ax2.set_title('Memory Usage Over Time', fontsize=12, fontweight='bold')
    ax2.set_xlabel('Time (minutes)', fontsize=11, fontweight='bold')
    ax2.legend(loc='upper right', framealpha=0.9)
    ax2.grid(True, linestyle='--', alpha=0.7)
    
    plt.tight_layout()
    output_path = output_dir / f'report-{timestamp}-timeseries_resources.png'
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"  ✅ Created: {output_path}")


def create_timeseries_throughput_chart(ts_df: pd.DataFrame, output_dir: Path, report_name: str, timestamp: str) -> None:
    """Create time-series throughput chart showing spans/sec and MB/s over time."""
    if ts_df.empty:
        return
    
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(14, 8), sharex=True)
    
    loads = ts_df['load_name'].unique()
    
    # MB/sec chart (primary - bytes ingested is now the main metric)
    for i, load in enumerate(loads):
        load_data = ts_df[ts_df['load_name'] == load]
        # Convert to MB/sec for readability
        ax1.plot(load_data['minute'], load_data['bytes_per_sec'] / (1024 * 1024), 
                label=load, color=LOAD_COLORS[i % len(LOAD_COLORS)],
                linewidth=2, marker='o', markersize=3)
    
    ax1.set_ylabel('MB/sec', fontsize=11, fontweight='bold')
    ax1.set_title(f'{report_name}\nBytes Ingested (MB/sec) Over Time', fontsize=12, fontweight='bold')
    ax1.legend(loc='upper right', framealpha=0.9)
    ax1.grid(True, linestyle='--', alpha=0.7)
    
    # Spans/sec chart
    for i, load in enumerate(loads):
        load_data = ts_df[ts_df['load_name'] == load]
        ax2.plot(load_data['minute'], load_data['spans_per_sec'], 
                label=load, color=LOAD_COLORS[i % len(LOAD_COLORS)],
                linewidth=2, marker='o', markersize=3)
    
    ax2.set_ylabel('Spans/sec', fontsize=11, fontweight='bold')
    ax2.set_title('Throughput (Spans/sec) Over Time', fontsize=12, fontweight='bold')
    ax2.set_xlabel('Time (minutes)', fontsize=11, fontweight='bold')
    ax2.legend(loc='upper right', framealpha=0.9)
    ax2.grid(True, linestyle='--', alpha=0.7)
    
    plt.tight_layout()
    output_path = output_dir / f'report-{timestamp}-timeseries_throughput.png'
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"  ✅ Created: {output_path}")


def create_timeseries_errors_chart(ts_df: pd.DataFrame, output_dir: Path, report_name: str, timestamp: str) -> None:
    """Create time-series error metrics chart."""
    if ts_df.empty:
        return
    
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(14, 8), sharex=True)
    
    loads = ts_df['load_name'].unique()
    
    # Query failures chart
    for i, load in enumerate(loads):
        load_data = ts_df[ts_df['load_name'] == load]
        ax1.plot(load_data['minute'], load_data['query_failures'], 
                label=load, color=LOAD_COLORS[i % len(LOAD_COLORS)],
                linewidth=2, marker='o', markersize=3)
    
    ax1.set_ylabel('Query Failures/sec', fontsize=11, fontweight='bold')
    ax1.set_title(f'{report_name}\nQuery Failures Over Time', fontsize=12, fontweight='bold')
    ax1.legend(loc='upper right', framealpha=0.9)
    ax1.grid(True, linestyle='--', alpha=0.7)
    
    # Dropped spans chart
    for i, load in enumerate(loads):
        load_data = ts_df[ts_df['load_name'] == load]
        ax2.plot(load_data['minute'], load_data['dropped_spans'], 
                label=load, color=LOAD_COLORS[i % len(LOAD_COLORS)],
                linewidth=2, marker='o', markersize=3)
    
    ax2.set_ylabel('Dropped Spans/sec', fontsize=11, fontweight='bold')
    ax2.set_title('Dropped Spans Over Time', fontsize=12, fontweight='bold')
    ax2.set_xlabel('Time (minutes)', fontsize=11, fontweight='bold')
    ax2.legend(loc='upper right', framealpha=0.9)
    ax2.grid(True, linestyle='--', alpha=0.7)
    
    plt.tight_layout()
    output_path = output_dir / f'report-{timestamp}-timeseries_errors.png'
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"  ✅ Created: {output_path}")


def generate_timeseries_charts(ts_df: pd.DataFrame, output_dir: Path, report_name: str, timestamp: str) -> None:
    """Generate all time-series PNG charts."""
    if ts_df.empty:
        print("\n⚠️  No time-series data found, skipping time-series charts")
        return
    
    print("\n📈 Generating time-series charts (PNG)...")
    charts_dir = output_dir / 'charts'
    charts_dir.mkdir(parents=True, exist_ok=True)
    
    create_timeseries_latency_chart(ts_df, charts_dir, report_name, timestamp)
    create_timeseries_resources_chart(ts_df, charts_dir, report_name, timestamp)
    create_timeseries_throughput_chart(ts_df, charts_dir, report_name, timestamp)
    create_timeseries_errors_chart(ts_df, charts_dir, report_name, timestamp)


# =============================================================================
# Interactive Dashboard Generation (plotly)
# =============================================================================

def generate_interactive_dashboard(df: pd.DataFrame, output_dir: Path, report_name: str) -> None:
    """Generate interactive HTML dashboard with plotly."""
    print("\n🌐 Generating interactive dashboard (HTML)...")

    # Create subplot figure
    fig = make_subplots(
        rows=2, cols=2,
        subplot_titles=(
            'Query Latency by Load Level',
            'Resource Usage by Load Level',
            'Bytes Ingested: Target vs Actual',
            'Error Metrics by Load Level'
        ),
        vertical_spacing=0.12,
        horizontal_spacing=0.1
    )

    load_labels = [f"{row['load_name']}<br>({row['mb_per_sec']} MB/s)" for _, row in df.iterrows()]

    # 1. Latency Chart (top-left)
    fig.add_trace(go.Bar(
        name='P50', x=load_labels, y=df['p50_ms'],
        marker_color=COLORS['primary'], text=df['p50_ms'].round(1),
        textposition='outside', textfont=dict(size=10)
    ), row=1, col=1)
    fig.add_trace(go.Bar(
        name='P90', x=load_labels, y=df['p90_ms'],
        marker_color=COLORS['secondary'], text=df['p90_ms'].round(1),
        textposition='outside', textfont=dict(size=10)
    ), row=1, col=1)
    fig.add_trace(go.Bar(
        name='P99', x=load_labels, y=df['p99_ms'],
        marker_color=COLORS['tertiary'], text=df['p99_ms'].round(1),
        textposition='outside', textfont=dict(size=10)
    ), row=1, col=1)

    # 2. Resources Chart (top-right)
    fig.add_trace(go.Bar(
        name='CPU (cores)', x=load_labels, y=df['cpu_cores'],
        marker_color=COLORS['primary'], text=df['cpu_cores'].round(2),
        textposition='outside', textfont=dict(size=10)
    ), row=1, col=2)
    fig.add_trace(go.Bar(
        name='Memory (GB)', x=load_labels, y=df['memory_gb'],
        marker_color=COLORS['secondary'], text=df['memory_gb'].round(2),
        textposition='outside', textfont=dict(size=10)
    ), row=1, col=2)

    # 3. Bytes Ingested Chart (bottom-left)
    fig.add_trace(go.Bar(
        name='Target MB/s', x=load_labels, y=df['mb_per_sec'],
        marker_color=COLORS['quaternary'], opacity=0.7
    ), row=2, col=1)
    fig.add_trace(go.Bar(
        name='Actual MB/s', x=load_labels, y=df['mb_per_sec_actual'],
        marker_color=COLORS['primary'],
        text=[f"{(actual/target*100):.0f}%" if target > 0 else "N/A"
              for actual, target in zip(df['mb_per_sec_actual'], df['mb_per_sec'])],
        textposition='outside', textfont=dict(size=10)
    ), row=2, col=1)

    # 4. Errors Chart (bottom-right)
    fig.add_trace(go.Bar(
        name='Error Rate (%)', x=load_labels, y=df['error_rate'],
        marker_color=COLORS['secondary'], text=df['error_rate'].round(2),
        textposition='outside', textfont=dict(size=10)
    ), row=2, col=2)
    fig.add_trace(go.Bar(
        name='Dropped Spans/sec', x=load_labels, y=df['dropped_spans'],
        marker_color=COLORS['accent'], text=df['dropped_spans'].round(1),
        textposition='outside', textfont=dict(size=10)
    ), row=2, col=2)

    # Update layout
    fig.update_layout(
        title=dict(
            text=f'<b>{report_name}</b><br><span style="font-size:16px">Performance Test Dashboard</span>',
            font=dict(size=24, color=COLORS['text']),
            x=0.5, xanchor='center'
        ),
        showlegend=True,
        legend=dict(
            orientation='h',
            yanchor='bottom',
            y=-0.15,
            xanchor='center',
            x=0.5,
            bgcolor=COLORS['surface'],
            bordercolor=COLORS['text'],
            borderwidth=1,
            font=dict(color=COLORS['text'])
        ),
        paper_bgcolor=COLORS['background'],
        plot_bgcolor=COLORS['surface'],
        font=dict(color=COLORS['text']),
        height=900,
        barmode='group',
        bargap=0.15,
        bargroupgap=0.1
    )

    # Update axes
    fig.update_xaxes(
        showgrid=True, gridwidth=1, gridcolor='#333355',
        tickfont=dict(color=COLORS['text'])
    )
    fig.update_yaxes(
        showgrid=True, gridwidth=1, gridcolor='#333355',
        tickfont=dict(color=COLORS['text'])
    )

    # Add axis labels
    fig.update_yaxes(title_text="Latency (ms)", row=1, col=1)
    fig.update_yaxes(title_text="Value", row=1, col=2)
    fig.update_yaxes(title_text="MB/sec", row=2, col=1)
    fig.update_yaxes(title_text="Value", row=2, col=2)

    # Save dashboard
    output_path = output_dir / 'dashboard.html'
    fig.write_html(
        str(output_path),
        include_plotlyjs=True,
        full_html=True,
        config={
            'displayModeBar': True,
            'displaylogo': False,
            'modeBarButtonsToRemove': ['lasso2d', 'select2d']
        }
    )
    print(f"  ✅ Created: {output_path}")


def generate_timeseries_dashboard(ts_df: pd.DataFrame, output_dir: Path, report_name: str) -> None:
    """Generate interactive HTML dashboard with time-series data."""
    if ts_df.empty:
        print("\n⚠️  No time-series data found, skipping time-series dashboard")
        return
    
    print("\n🌐 Generating time-series dashboard (HTML)...")
    
    loads = ts_df['load_name'].unique()
    
    # Create subplot figure with 4 rows
    fig = make_subplots(
        rows=4, cols=1,
        subplot_titles=(
            'Query Latency Over Time (P50, P90, P99)',
            'Resource Usage Over Time (CPU & Memory)',
            'Bytes Ingested Over Time (MB/sec)',
            'Error Metrics Over Time'
        ),
        vertical_spacing=0.08,
        specs=[[{"secondary_y": False}], [{"secondary_y": True}], 
               [{"secondary_y": False}], [{"secondary_y": True}]]
    )
    
    # Row 1: Latency metrics
    for i, load in enumerate(loads):
        load_data = ts_df[ts_df['load_name'] == load]
        color = LOAD_COLORS[i % len(LOAD_COLORS)]
        
        # P99 (solid)
        fig.add_trace(go.Scatter(
            x=load_data['minute'], y=load_data['p99_ms'],
            name=f'{load} P99', mode='lines+markers',
            line=dict(color=color, width=2),
            marker=dict(size=4),
            legendgroup=load,
        ), row=1, col=1)
        
        # P90 (dashed)
        fig.add_trace(go.Scatter(
            x=load_data['minute'], y=load_data['p90_ms'],
            name=f'{load} P90', mode='lines',
            line=dict(color=color, width=1.5, dash='dash'),
            legendgroup=load, showlegend=False,
        ), row=1, col=1)
        
        # P50 (dotted)
        fig.add_trace(go.Scatter(
            x=load_data['minute'], y=load_data['p50_ms'],
            name=f'{load} P50', mode='lines',
            line=dict(color=color, width=1, dash='dot'),
            legendgroup=load, showlegend=False,
        ), row=1, col=1)
    
    # Row 2: Resource metrics (dual axis)
    for i, load in enumerate(loads):
        load_data = ts_df[ts_df['load_name'] == load]
        color = LOAD_COLORS[i % len(LOAD_COLORS)]
        
        # CPU (primary y-axis)
        fig.add_trace(go.Scatter(
            x=load_data['minute'], y=load_data['cpu_cores'],
            name=f'{load} CPU', mode='lines+markers',
            line=dict(color=color, width=2),
            marker=dict(size=4),
            legendgroup=f'{load}_res',
        ), row=2, col=1, secondary_y=False)
        
        # Memory (secondary y-axis)
        fig.add_trace(go.Scatter(
            x=load_data['minute'], y=load_data['memory_gb'],
            name=f'{load} Memory', mode='lines',
            line=dict(color=color, width=2, dash='dash'),
            legendgroup=f'{load}_res', showlegend=False,
        ), row=2, col=1, secondary_y=True)
    
    # Row 3: Bytes Ingested (MB/sec)
    for i, load in enumerate(loads):
        load_data = ts_df[ts_df['load_name'] == load]
        color = LOAD_COLORS[i % len(LOAD_COLORS)]
        
        # Convert bytes_per_sec to MB/sec
        mb_per_sec = load_data['bytes_per_sec'] / (1024 * 1024)
        
        fig.add_trace(go.Scatter(
            x=load_data['minute'], y=mb_per_sec,
            name=f'{load} MB/sec', mode='lines+markers',
            line=dict(color=color, width=2),
            marker=dict(size=4),
            fill='tozeroy', fillcolor=f'rgba{tuple(list(bytes.fromhex(color[1:])) + [0.1])}',
            legendgroup=f'{load}_tp',
        ), row=3, col=1)
    
    # Row 4: Error metrics (dual axis)
    for i, load in enumerate(loads):
        load_data = ts_df[ts_df['load_name'] == load]
        color = LOAD_COLORS[i % len(LOAD_COLORS)]
        
        # Query failures (primary y-axis)
        fig.add_trace(go.Scatter(
            x=load_data['minute'], y=load_data['query_failures'],
            name=f'{load} Failures', mode='lines+markers',
            line=dict(color=color, width=2),
            marker=dict(size=4),
            legendgroup=f'{load}_err',
        ), row=4, col=1, secondary_y=False)
        
        # Dropped spans (secondary y-axis)
        fig.add_trace(go.Scatter(
            x=load_data['minute'], y=load_data['dropped_spans'],
            name=f'{load} Dropped', mode='lines',
            line=dict(color=color, width=2, dash='dash'),
            legendgroup=f'{load}_err', showlegend=False,
        ), row=4, col=1, secondary_y=True)
    
    # Update layout
    fig.update_layout(
        title=dict(
            text=f'<b>{report_name}</b><br><span style="font-size:16px">Time Series Dashboard</span>',
            font=dict(size=24, color=COLORS['text']),
            x=0.5, xanchor='center'
        ),
        showlegend=True,
        legend=dict(
            orientation='h',
            yanchor='bottom',
            y=-0.08,
            xanchor='center',
            x=0.5,
            bgcolor=COLORS['surface'],
            bordercolor=COLORS['text'],
            borderwidth=1,
            font=dict(color=COLORS['text'], size=10)
        ),
        paper_bgcolor=COLORS['background'],
        plot_bgcolor=COLORS['surface'],
        font=dict(color=COLORS['text']),
        height=1400,
        hovermode='x unified'
    )
    
    # Update axes
    fig.update_xaxes(
        showgrid=True, gridwidth=1, gridcolor='#333355',
        tickfont=dict(color=COLORS['text']),
        title_text="Time (minutes)", row=4, col=1
    )
    fig.update_yaxes(
        showgrid=True, gridwidth=1, gridcolor='#333355',
        tickfont=dict(color=COLORS['text'])
    )
    
    # Add axis labels
    fig.update_yaxes(title_text="Latency (ms)", row=1, col=1)
    fig.update_yaxes(title_text="CPU (cores)", row=2, col=1, secondary_y=False)
    fig.update_yaxes(title_text="Memory (GB)", row=2, col=1, secondary_y=True)
    fig.update_yaxes(title_text="MB/sec", row=3, col=1)
    fig.update_yaxes(title_text="Failures/sec", row=4, col=1, secondary_y=False)
    fig.update_yaxes(title_text="Dropped/sec", row=4, col=1, secondary_y=True)
    
    # Save dashboard
    output_path = output_dir / 'timeseries-dashboard.html'
    fig.write_html(
        str(output_path),
        include_plotlyjs=True,
        full_html=True,
        config={
            'displayModeBar': True,
            'displaylogo': False,
            'modeBarButtonsToRemove': ['lasso2d', 'select2d']
        }
    )
    print(f"  ✅ Created: {output_path}")


# =============================================================================
# Summary Table Generation
# =============================================================================

def generate_summary_table(df: pd.DataFrame, output_dir: Path, report_name: str) -> None:
    """Generate an HTML summary table of results."""
    print("\n📋 Generating summary table...")

    # Calculate efficiency based on target vs actual MB/s
    df['efficiency'] = df.apply(
        lambda row: (row['mb_per_sec_actual'] / row['mb_per_sec'] * 100) if row['mb_per_sec'] > 0 else 0,
        axis=1
    ).round(1)

    html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{report_name} - Performance Test Summary</title>
    <style>
        body {{
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background-color: {COLORS['background']};
            color: {COLORS['text']};
            padding: 20px;
            margin: 0;
        }}
        h1 {{
            text-align: center;
            color: {COLORS['primary']};
            margin-bottom: 10px;
        }}
        h2 {{
            text-align: center;
            color: {COLORS['text']};
            margin-bottom: 30px;
            font-weight: normal;
            font-size: 1.1em;
        }}
        .container {{
            max-width: 1400px;
            margin: 0 auto;
        }}
        table {{
            width: 100%;
            border-collapse: collapse;
            background-color: {COLORS['surface']};
            border-radius: 8px;
            overflow: hidden;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.3);
        }}
        th {{
            background-color: {COLORS['primary']};
            color: {COLORS['background']};
            padding: 15px 10px;
            text-align: left;
            font-weight: 600;
        }}
        td {{
            padding: 12px 10px;
            border-bottom: 1px solid #333355;
        }}
        tr:hover {{
            background-color: rgba(0, 217, 255, 0.1);
        }}
        .metric-good {{ color: {COLORS['success']}; }}
        .metric-warn {{ color: {COLORS['warning']}; }}
        .metric-bad {{ color: {COLORS['secondary']}; }}
        .footer {{
            text-align: center;
            margin-top: 30px;
            color: #888;
            font-size: 0.9em;
        }}
    </style>
</head>
<body>
    <div class="container">
        <h1>{report_name}</h1>
        <h2>Performance Test Summary</h2>
        <table>
            <thead>
                <tr>
                    <th>Load</th>
                    <th>Target (MB/s)</th>
                    <th>Actual (MB/s)</th>
                    <th>P50 (ms)</th>
                    <th>P90 (ms)</th>
                    <th>P99 (ms)</th>
                    <th>CPU (cores)</th>
                    <th>Memory (GB)</th>
                    <th>Spans/sec</th>
                    <th>Efficiency</th>
                    <th>Error Rate</th>
                </tr>
            </thead>
            <tbody>
"""

    for _, row in df.iterrows():
        eff_class = 'metric-good' if row['efficiency'] >= 90 else ('metric-warn' if row['efficiency'] >= 70 else 'metric-bad')
        err_class = 'metric-good' if row['error_rate'] < 1 else ('metric-warn' if row['error_rate'] < 5 else 'metric-bad')

        html_content += f"""                <tr>
                    <td><strong>{row['load_name']}</strong></td>
                    <td>{row['mb_per_sec']:.1f}</td>
                    <td>{row['mb_per_sec_actual']:.2f}</td>
                    <td>{row['p50_ms']:.1f}</td>
                    <td>{row['p90_ms']:.1f}</td>
                    <td>{row['p99_ms']:.1f}</td>
                    <td>{row['cpu_cores']:.2f}</td>
                    <td>{row['memory_gb']:.2f}</td>
                    <td>{row['spans_per_sec']:.0f}</td>
                    <td class="{eff_class}">{row['efficiency']:.1f}%</td>
                    <td class="{err_class}">{row['error_rate']:.2f}%</td>
                </tr>
"""

    html_content += """            </tbody>
        </table>
        <p class="footer">Generated by Tempo Performance Test Framework</p>
    </div>
</body>
</html>
"""

    output_path = output_dir / 'summary.html'
    with open(output_path, 'w') as f:
        f.write(html_content)
    print(f"  ✅ Created: {output_path}")


# =============================================================================
# Main
# =============================================================================

def main():
    if len(sys.argv) < 2:
        print("Usage: ./generate-charts.py <results_dir> [timestamp]")
        print("")
        print("Example: ./generate-charts.py perf-tests/results 20251126-123954")
        sys.exit(1)

    results_dir = Path(sys.argv[1])
    
    # Get timestamp from argument or generate one
    if len(sys.argv) >= 3:
        timestamp = sys.argv[2]
    else:
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")

    if not results_dir.exists():
        print(f"Error: Results directory not found: {results_dir}")
        sys.exit(1)

    print("=" * 60)
    print("  Tempo Performance Test - Chart Generation")
    print("=" * 60)
    print(f"\nResults directory: {results_dir}")

    # Load report metadata and extract report name
    metadata = load_report_metadata(results_dir)
    report_name = get_report_name(metadata)
    print(f"Report name: {report_name}")

    # Load and process results
    results = load_test_results(results_dir)
    print(f"Loaded {len(results)} test result(s)")

    df = results_to_dataframe(results)
    print(f"Processed data for loads: {', '.join(df['load_name'].tolist())}")

    # Extract time-series data
    ts_df = extract_timeseries_data(results)
    if not ts_df.empty:
        print(f"Extracted {len(ts_df)} time-series data points")
    else:
        print("No time-series data found (legacy format)")

    # Generate outputs
    generate_static_charts(df, results_dir, report_name, timestamp)
    generate_timeseries_charts(ts_df, results_dir, report_name, timestamp)
    generate_interactive_dashboard(df, results_dir, report_name)
    generate_timeseries_dashboard(ts_df, results_dir, report_name)
    generate_summary_table(df, results_dir, report_name)

    print("\n" + "=" * 60)
    print("  Chart generation complete!")
    print("=" * 60)
    print(f"\nOutputs:")
    print(f"  📊 Static charts:          {results_dir}/charts/report-{timestamp}-*.png")
    print(f"  📈 Time-series charts:     {results_dir}/charts/report-{timestamp}-timeseries_*.png")
    print(f"  🌐 Summary Dashboard:      {results_dir}/dashboard.html")
    print(f"  🌐 Time-Series Dashboard:  {results_dir}/timeseries-dashboard.html")
    print(f"  📋 Summary Table:          {results_dir}/summary.html")


if __name__ == '__main__':
    main()

