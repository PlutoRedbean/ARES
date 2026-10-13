#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Memory Trace Visualization Tool
------------------------------------------------
Visualizes memory access patterns (Space-Time Graph) to analyze
Locality of Reference. Features automatic address space segmentation
to handle sparse memory maps.

Author: Senior Architecture Engineer
"""

import argparse
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np
import os
import sys

# Configuration
GAP_THRESHOLD = 0x100000  # 1MB. Gaps larger than this trigger a new plot segment.
FIGURE_DPI = 300
PLOT_ALPHA = 0.6
MARKER_SIZE = 10

def parse_args():
    parser = argparse.ArgumentParser(description="Generate Memory Space-Time Scatter Plot from mtrace CSV.")
    parser.add_argument("-i", "--input", type=str, default="./mtrace.csv", help="Input CSV file path")
    parser.add_argument("-o", "--output", type=str, default="build/", help="Output directory for charts")
    return parser.parse_args()

class MemoryVisualizer:
    def __init__(self, df):
        self.df = df
        self.segments = []

    def _preprocess(self):
        """Clean and prepare data."""
        # Ensure column names are stripped of whitespace
        self.df.columns = [c.strip() for c in self.df.columns]
        
        # Sort by instruction count (Time)
        self.df = self.df.sort_values(by='instructions')
        
        # Identify Read/Write for coloring
        self.df['color'] = self.df['type'].apply(lambda x: '#1f77b4' if 'read' in str(x).lower() else '#d62728')

    def _segment_address_space(self):
        """
        Solves the 'Sparse Address Space' problem.
        Identifies active memory regions by finding large gaps in sorted unique addresses.
        """
        unique_addrs = np.sort(self.df['address'].unique())
        if len(unique_addrs) == 0:
            return

        # Calculate diff between consecutive sorted addresses
        diffs = np.diff(unique_addrs)
        
        # Find indices where the gap is huge (indicating jump between memory regions)
        # We look for gaps larger than GAP_THRESHOLD
        split_indices = np.where(diffs > GAP_THRESHOLD)[0] + 1
        
        # Create boundaries: [0, split_1, split_2, ..., len]
        boundaries = [0] + list(split_indices) + [len(unique_addrs)]
        
        # Create segment ranges (min_addr, max_addr) for each cluster
        for i in range(len(boundaries) - 1):
            start_idx = boundaries[i]
            end_idx = boundaries[i+1]
            segment_addrs = unique_addrs[start_idx:end_idx]
            
            self.segments.append({
                'min': segment_addrs.min(),
                'max': segment_addrs.max(),
                # Add a small buffer for visualization comfort
                'view_min': segment_addrs.min() - 1024, 
                'view_max': segment_addrs.max() + 1024
            })
        
        # Sort segments from high address to low address (top to bottom in plot)
        self.segments.sort(key=lambda x: x['min'], reverse=True)
        print(f"[Info] Detected {len(self.segments)} active memory segments.")

    def plot(self, output_path):
        self._preprocess()
        self._segment_address_space()

        if not self.segments:
            print("[Error] No valid segments found.")
            return

        num_segments = len(self.segments)
        
        # Create subplots with shared X axis. 
        # Height ratios can be adjusted, but equal height usually looks neatest for distinct regions.
        fig, axes = plt.subplots(
            nrows=num_segments, 
            ncols=1, 
            figsize=(12, 4 * num_segments), 
            sharex=True,
            constrained_layout=True
        )

        # Handle single subplot case (axes is not iterable)
        if num_segments == 1:
            axes = [axes]

        # Global X range
        x_min, x_max = self.df['instructions'].min(), self.df['instructions'].max()

        for i, segment in enumerate(self.segments):
            ax = axes[i]
            
            # Filter data for this segment
            mask = (self.df['address'] >= segment['min']) & (self.df['address'] <= segment['max'])
            seg_data = self.df[mask]
            
            # Scatter plot
            # Using 'instructions' as X (Time), 'address' as Y (Space)
            ax.scatter(
                seg_data['instructions'], 
                seg_data['address'], 
                s=MARKER_SIZE, 
                c=seg_data['color'], 
                alpha=PLOT_ALPHA, 
                edgecolors='none',
                label='Access'
            )

            # Aesthetics for this subplot
            ax.set_ylim(segment['view_min'], segment['view_max'])
            ax.set_xlim(x_min, x_max)
            
            # Y-Axis Formatting (Hex)
            y_formatter = ticker.FuncFormatter(lambda x, pos: f'0x{int(x):X}')
            ax.yaxis.set_major_formatter(y_formatter)
            ax.tick_params(axis='y', labelsize=8)
            ax.grid(True, linestyle='--', alpha=0.5)
            
            # Label region
            mid_addr = (segment['min'] + segment['max']) // 2
            ax.set_ylabel(f"Addr Region\n~0x{mid_addr:X}", fontsize=10, fontweight='bold')

            # Add Legend only to the first plot
            if i == 0:
                from matplotlib.lines import Line2D
                legend_elements = [
                    Line2D([0], [0], marker='o', color='w', markerfacecolor='#1f77b4', label='Read', markersize=8),
                    Line2D([0], [0], marker='o', color='w', markerfacecolor='#d62728', label='Write', markersize=8)
                ]
                ax.legend(handles=legend_elements, loc='upper right')
                ax.set_title(f"Memory Access Space-Time Plot (Locality Analysis)", fontsize=14)

        # Common X Label
        axes[-1].set_xlabel("Time (Instruction Count)", fontsize=12)
        
        # Format X axis with scientific notation or commas
        axes[-1].xaxis.set_major_formatter(ticker.FuncFormatter(lambda x, p: format(int(x), ',')))

        # Save
        print(f"[Info] Saving plot to {output_path}...")
        plt.savefig(output_path, dpi=FIGURE_DPI)
        plt.close()

def main():
    args = parse_args()
    
    # Check input
    if not os.path.exists(args.input):
        print(f"[Error] Input file not found: {args.input}")
        sys.exit(1)
        
    # Prepare output
    if not os.path.exists(args.output):
        os.makedirs(args.output, exist_ok=True)
        
    try:
        print(f"[Info] Loading data from {args.input}...")
        
        # --- 修复开始 ---
        # 针对无 Header 的 CSV 文件，显式指定列名
        column_names = ['type', 'pc', 'address', 'size', 'instructions']
        
        # 读取 CSV
        # header=None: 告诉 pandas 第一行就是数据，不要把它当表头
        # names=column_names: 强制赋予这些列名
        df = pd.read_csv(args.input, header=None, names=column_names)
        
        # 简单的数据清洗：移除可能存在的空白字符
        if 'type' in df.columns and df['type'].dtype == object:
             df['type'] = df['type'].str.strip()
        # --- 修复结束 ---

        # 检查是否真的读取到了数据
        if df.empty:
            print("[Error] The CSV file is empty.")
            sys.exit(1)

        vis = MemoryVisualizer(df)
        output_file = os.path.join(args.output, "memory_space_time.png")
        vis.plot(output_file)
        
    except Exception as e:
        print(f"[Error] Processing failed: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    main()
