import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.lines import Line2D
import numpy as np
import os

HAMMER_ROOT = os.environ['HAMMER_ROOT']
 
 
# ── 1. Configuration ──────────────────────────────────────────────────────────
 
# PATTERN_LENGTHS = [x for x in range(1, 73)]   # x-axis groups (in TREFIs)
PATTERN_LENGTHS = [x for x in range(1, 19)] + [-1, 24, -1, 27, -1, 36]
INTENSITIES     = [2, 3, 4]                      # box-plot series per group
INTENSITY_LABELS = {1: "1x", 2: "2x", 3: "3x", 4: "4x"}
 
# Colors for each intensity level
COLORS = {
    1: "#4C72B0",   # blue
    2: "#DD8452",   # orange
    3: "#55A868",   # green
    4: "#C44E52",   # red
}
 
 
# ── 2. File-name resolver  ────────────────────────────────────────────────────
 
def get_data_filepath(pattern_length: int, intensity: int) -> str:
    """
    Return the path to the data file for a given (pattern_length, intensity)
    combination.
 
    Modify this function to match your actual file naming / directory scheme.
    """
    return os.path.join(
        HAMMER_ROOT,
        f"results/fig6/raw_data/{intensity}x_{pattern_length}trefi_b77_00ff.txt"
    )
 
# ── 3. Data loader ────────────────────────────────────────────────────────────
 
def load_data(pattern_length: int, intensity: int) -> list[float]:
    """
    Read all numeric lines from the file returned by get_data_filepath().
    Returns an empty list if the file does not exist.
    """
    if (pattern_length == -1):
        return [0]
    
    path = get_data_filepath(pattern_length, intensity)
    if not os.path.isfile(path):
        print(f"  [warn] File not found: {path}")
        return []
    values = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    values.append(float(line) * 2 if pattern_length < 40 else float(line) * 5)
                except ValueError:
                    pass   # skip non-numeric lines
    return values
 
 
# ── 4. Build dataset ──────────────────────────────────────────────────────────
 
# data[pattern_length][intensity] = list of floats
data = {}
for pl in PATTERN_LENGTHS:
    data[pl] = {}
    for intensity in INTENSITIES:
        data[pl][intensity] = load_data(pl, intensity)

# def has_data(pattern_length: int) -> bool:
#     """Check if this pattern length has any non-zero data across all intensities."""
#     for intensity in INTENSITIES:
#         if pattern_length not in data:
#             return False
#         if data[pattern_length][intensity]:  # if list is not empty
#             # Check if any value is non-zero
#             if any(v > 0 for v in data[pattern_length][intensity]):
#                 return True
#     return False

# n_bars = sum((1 if (has_data(pl) or has_data(pl + 1)) else 0) for pl in PATTERN_LENGTHS)
# skip_flags = [True if not has_data(pl) and has_data(pl + 1) else False for pl in PATTERN_LENGTHS]
# xticklabels = []
# for pl in PATTERN_LENGTHS:
#     if has_data(pl):
#         xticklabels.append(str(pl))
#     elif has_data(pl + 1):
#         xticklabels.append('...')

# # Keep only pattern lengths with at least some non-zero data
# PATTERN_LENGTHS = [pl for pl in PATTERN_LENGTHS if has_data(pl)]
 
# ── 5. Layout parameters ──────────────────────────────────────────────────────
 
n_groups    = len(PATTERN_LENGTHS)
n_boxes     = len(INTENSITIES)
group_width = 1.0          # total width reserved for each pattern-length group
box_width   = 0.2         # width of a single box
gap         = 0.1         # gap between boxes inside a group
 
# Centre positions for each group
group_centres = np.arange(n_groups, dtype=float)
 
# Offsets of each intensity within its group
half = (n_boxes - 1) / 2.0
offsets = [(i - half) * (box_width + gap) for i in range(n_boxes)]
 
 
# ── 6. Plot ───────────────────────────────────────────────────────────────────
 
fig, ax = plt.subplots(figsize=(7, 3))
 
for g_idx, pl in enumerate(PATTERN_LENGTHS):
    for i_idx, intensity in enumerate(INTENSITIES):
        values = data[pl][intensity]
        pos    = group_centres[g_idx] + offsets[i_idx]
        color  = COLORS[intensity]
 
        if values:
            bp = ax.boxplot(
                values,
                positions=[pos],
                widths=box_width,
                patch_artist=True,
                notch=False,
                showfliers=True,
                boxprops=dict(facecolor=color, color=color, alpha=0.75),
                medianprops=dict(color="white", linewidth=2),
                whiskerprops=dict(color=color, linewidth=1.4),
                capprops=dict(color=color, linewidth=1.4),
                flierprops=dict(
                    marker="o", markerfacecolor=color,
                    markeredgecolor=color, markersize=1, alpha=0.6
                ),
            )
        else:
            # Draw a placeholder 'x' when no data is available
            ax.text(pos, 50, "×", ha="center", va="center",
                    color=color, fontsize=14, alpha=0.2)
 
 
# ── 7. Axes formatting ────────────────────────────────────────────────────────
 
ax.set_xticks(group_centres)
ax.set_xticklabels([str(pl) if pl != -1 else '' for pl in PATTERN_LENGTHS], fontsize=11)
ax.set_xlabel("Pattern Length (Number of tREFIs)", fontsize=13, labelpad=8)
ax.set_ylabel("Flip Probability (%)", fontsize=13, labelpad=8)
# ax.set_title("Reproduction Rate by Pattern Length and Intensity", fontsize=15, pad=14)
 
# ax.set_ylim(0, 105)
# ax.yaxis.set_major_formatter(matplotlib.ticker.PercentFormatter(xmax=100, decimals=0))
 
ax.set_xlim(group_centres[0] - 0.55, group_centres[-1] + 0.55)

lines = []

lines.append(Line2D([0.77, 0.78], [0.2, 0.25], 
              transform=fig.transFigure,
              color='white', linewidth=4))
lines.append(Line2D([0.765, 0.775], [0.2, 0.25], 
              transform=fig.transFigure,
              color='black', linewidth=1))
lines.append(Line2D([0.775, 0.785], [0.2, 0.25], 
              transform=fig.transFigure,
              color='black', linewidth=1))

lines.append(Line2D([0.845, 0.855], [0.2, 0.25], 
              transform=fig.transFigure,
              color='white', linewidth=4))
lines.append(Line2D([0.84, 0.85], [0.2, 0.25], 
              transform=fig.transFigure,
              color='black', linewidth=1))
lines.append(Line2D([0.85, 0.86], [0.2, 0.25], 
              transform=fig.transFigure,
              color='black', linewidth=1))

lines.append(Line2D([0.915, 0.925], [0.2, 0.25], 
              transform=fig.transFigure,
              color='white', linewidth=4))
lines.append(Line2D([0.91, 0.92], [0.2, 0.25], 
              transform=fig.transFigure,
              color='black', linewidth=1))
lines.append(Line2D([0.92, 0.93], [0.2, 0.25], 
              transform=fig.transFigure,
              color='black', linewidth=1))

for line in lines:
    fig.add_artist(line)
# ax.plot([0.77, 0.78], [-1, 0.3], 'black', linewidth=1, transform=fig.transFigure)
# ax.text(17.75, -7, '≈', 
#         bbox=dict(boxstyle='round', facecolor='white', edgecolor='none'))
# ax.text(19.75, -7, '≈', 
#         bbox=dict(boxstyle='round', facecolor='white', edgecolor='none'))
# ax.text(21.75, -7, '≈', 
#         bbox=dict(boxstyle='round', facecolor='white', edgecolor='none'))

# Light horizontal grid
ax.yaxis.grid(True, linestyle="--", linewidth=0.7, alpha=0.6)
ax.set_axisbelow(True)
 
# Faint vertical separators between groups
for x in group_centres[:-1] + 0.5:
    ax.axvline(x, color="grey", linewidth=0.5, linestyle=":", alpha=0.5)
 
ax.spines["top"].set_visible(False)
ax.spines["right"].set_visible(False)
 

 
# ── 8. Legend ─────────────────────────────────────────────────────────────────
 
legend_handles = [
    mpatches.Patch(facecolor=COLORS[i], edgecolor=COLORS[i],
                   alpha=0.75, label=INTENSITY_LABELS[i])
    for i in INTENSITIES
]
ax.legend(handles=legend_handles, title="Intensity per tREFI",
          title_fontsize=11, fontsize=10,
          loc="upper right",
          bbox_to_anchor=(1.0, 1.08),
          ncol=len(INTENSITIES),
          framealpha=0.9,
          handlelength=1.5, handleheight=1.0,
          columnspacing=1.2)
 
 
# ── 9. Save ───────────────────────────────────────────────────────────────────
 
plt.tight_layout()
 
# out_png = "fig6.png"
out_pdf = os.path.join(HAMMER_ROOT, f"results/fig6.pdf")
 
# fig.savefig(out_png, dpi=180, bbox_inches="tight")
fig.savefig(out_pdf, bbox_inches="tight")
 
# print(f"Saved: {out_png}")
print(f"Saved: {out_pdf}")