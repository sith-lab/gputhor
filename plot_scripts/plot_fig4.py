import matplotlib.pyplot as plt
import numpy as np
import os

HAMMER_ROOT = os.environ['HAMMER_ROOT']

def read_avg(filename, folder=os.path.join(HAMMER_ROOT, "results/fig4/raw_data")):
    with open(os.path.join(folder, filename), 'r') as f:
        values = [float(line.strip()) for line in f if line.strip()]
    return np.mean(values)

# --- Series: (label, file prefix, color) ---
series = [
    ('2x Intensity', '2x_', 'cornflowerblue'),
    ('3x Intensity', '3x_', 'sandybrown'),
]

# --- Configurations ---
configs = {
    'Same Warp\nSame Cacheline': 'warp1_cacheline1_timing.txt',
    'Same Warp\nDiff Cacheline': 'warp1_cacheline0_timing.txt',
    'Diff Warp\nSame Cacheline': 'warp0_cacheline1_timing.txt',
    'Diff Warp\nDiff Cacheline': 'warp0_cacheline0_timing.txt',
}

labels = list(configs.keys())
filenames = list(configs.values())

# avgs[i] = list of per-config averages for series i
avgs = [
    [read_avg(f'{prefix}{f}') for f in filenames]
    for _, prefix, _ in series
]

baseline_avg = read_avg('baseline.txt')

# --- Layout ---
n_configs = len(labels)
n_series  = len(series)
bar_width = 0.15
inner_gap = 0.02  # gap between bars in the same group
group_gap = 0.15                          # extra space between config groups
x = np.arange(n_configs) * (n_series * bar_width + group_gap)

fig, ax = plt.subplots(figsize=(9, 4))

for i, ((s_label, _, color), s_avgs) in enumerate(zip(series, avgs)):
    offsets = x + i * (bar_width + inner_gap) - (n_series - 1) * (bar_width + inner_gap) / 2
    bars = ax.bar(offsets, s_avgs, width=bar_width,
                  color=color, edgecolor='black', zorder=3, label=s_label)

    for bar, val in zip(bars, s_avgs):
        ax.text(
            bar.get_x() + bar.get_width() / 2,
            bar.get_height() ,
            f'{val:.0f}',
            ha='center', va='bottom', fontsize=13
        )

# Baseline
ax.axhline(
    y=baseline_avg,
    color='red', linestyle='--', linewidth=1.8,
    label=f'Baseline: {baseline_avg:.0f} ns', zorder=4
)

ax.set_xticks(x)
ax.set_xticklabels(labels, fontsize=13)
ax.set_xlabel('Configurations', fontsize=15)
ax.set_ylabel('Time per Round (ns)', fontsize=15)
ax.legend(fontsize=12, loc="upper right")
ax.grid(axis='y', linestyle='--', alpha=0.5, zorder=0)

all_vals = [v for s in avgs for v in s] + [baseline_avg]
ax.set_ylim(400, max(all_vals) * 1.1)

plt.tight_layout()
plt.savefig(os.path.join(HAMMER_ROOT, "results/fig4.pdf"), dpi=300)
plt.show()