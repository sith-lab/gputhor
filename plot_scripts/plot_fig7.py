import argparse
import csv
import statistics
import matplotlib.pyplot as plt
import matplotlib.transforms as mtransforms
import numpy as np
import os
from matplotlib.ticker import PercentFormatter
import seaborn as sns

sns.set_context('paper')
colors = sns.color_palette('muted', n_colors=6)

parser = argparse.ArgumentParser()
parser.add_argument("iterations", type=int,
                     help="Number of times each pattern was hammered (count_iter in run_fig7.sh), used to compute the reproduction probability")
parser.add_argument("--bank-id", type=int, default=77,
                     help="Bank id used when hammering (bank_id in run_fig7.sh)")
parser.add_argument("--vic-pat", default="00",
                     help="Victim row data pattern in hex (vic_pat in run_fig7.sh)")
parser.add_argument("--agg-pat", default="ff",
                     help="Aggressor row data pattern in hex (agg_pat in run_fig7.sh)")
parser.add_argument("--num-trials", type=int, default=5,
                     help="Number of independent trials per (tREFI, intensity) to average over (num_trials in run_fig7.sh)")
parser.add_argument("--agg-method", choices=["mean", "median"], default="mean",
                     help="How to combine the per-trial bitflip counts")
parser.add_argument("--intensity-min", type=int, default=2,
                     help="Lowest intensity (ACTs/tREFI) swept (intensity_min in run_fig7.sh)")
parser.add_argument("--intensity-max", type=int, default=7,
                     help="Highest intensity (ACTs/tREFI) swept (intensity_max in run_fig7.sh)")
args = parser.parse_args()

agg_func = statistics.mean if args.agg_method == "mean" else statistics.median

HAMMER_ROOT = os.environ['HAMMER_ROOT']
raw_dir = os.path.join(HAMMER_ROOT, "results/fig7/raw_data")
csv_file = os.path.join(HAMMER_ROOT, "results/fig7_output.csv")

trefi_cols = [3, 4, 6, 9, 18, 24]
intensities = list(range(args.intensity_min, args.intensity_max + 1))

# Aggregate the per-trial raw bitflip counts (across independent trials) and
# write out the summary CSV.
rows = []
for i in intensities:
    row = [i]
    for trefi in trefi_cols:
        trial_values = []
        for trial in range(1, args.num_trials + 1):
            bitflip_file = os.path.join(
                raw_dir,
                f"{i}x_{trefi}trefi_b{args.bank_id}_{args.vic_pat}{args.agg_pat}_trial{trial}.txt")
            if os.path.isfile(bitflip_file):
                with open(bitflip_file) as f:
                    trial_values.append(float(f.read().strip()))
            else:
                trial_values.append(0.0)
        row.append(agg_func(trial_values))
    rows.append(row)

with open(csv_file, 'w', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(["Intensity"] + [f"{t}-TREFI" for t in trefi_cols])
    writer.writerows(rows)

# Unpack for plotting
intensity = [row[0] for row in rows]
trefi_3 = [row[1] / args.iterations * 100 for row in rows]
trefi_4 = [row[2] / args.iterations * 100 for row in rows]
trefi_6 = [row[3] / args.iterations * 100 for row in rows]
trefi_9 = [row[4] / args.iterations * 100 for row in rows]
trefi_18 = [row[5] / args.iterations * 100 for row in rows]
trefi_24 = [row[6] / args.iterations * 100 for row in rows]

# Convert x-axis to positions
x = np.arange(len(intensity))

# 6 bars → shrink width
width = 0.13

# Create plot
fig, ax = plt.subplots(figsize=(9, 3))
ax.tick_params(axis='both', which='major', labelsize=16)
ax.tick_params(axis='both', which='minor', labelsize=16)

# Center bars around x
# Colors chosen to match intensity_plot.pdf: shared labels (3, 6, 9, 18-TREFI)
# use the same color there; 4- and 24-TREFI (not present there) get spare cycle colors
ax.bar(x - 2.5*width, trefi_3, width, label='3-TREFI', color=colors[1], alpha=0.88)
ax.bar(x - 1.5*width, trefi_4, width, label='4-TREFI', color=colors[0], alpha=0.88)
ax.bar(x - 0.5*width, trefi_6, width, label='6-TREFI', color=colors[2], alpha=0.88)
ax.bar(x + 0.5*width, trefi_9, width, label='9-TREFI', color=colors[3], alpha=0.88)
ax.bar(x + 1.5*width, trefi_18, width, label='18-TREFI', color=colors[4], alpha=0.88)
ax.bar(x + 2.5*width, trefi_24, width, label='24-TREFI', color=colors[5], alpha=0.88)

# Labels and formatting
ax.set_xlabel('Aggressor Intensity (ACTs/tREFI)', fontsize=16)
ax.set_ylabel('Flip Probability (%)', fontsize=16)

# intensity[6] = "8-16"
# Extra tick at the end to show that everything from 8-15 is 0
break_x = x[-1]
ax.set_xticks(list(x))
ax.set_xticklabels(intensity)
# ax.set_xlim(x[0] - 0.5, break_x + 0.5)

# # Draw a zig/kink to indicate the axis break between 8 and 15
# kink_x = (x[-1] + break_x) / 2
# trans = mtransforms.blended_transform_factory(ax.transData, ax.transAxes)
# d = 0.4  # kink half-width in x data units
# h = 0.05  # kink half-height in axes fraction units
# kwargs = dict(transform=trans, color='k', clip_on=False, lw=1.2)
# for offset in (-0.08, 0.08):
#     cx = kink_x + offset
#     ax.plot([cx - d / 2, cx + d / 2], [-h, h], **kwargs)

ax.yaxis.set_major_formatter(PercentFormatter(xmax=100))

ax.legend( fontsize=12)

fig.savefig(os.path.join(HAMMER_ROOT, "results/fig7.pdf"), dpi=500, bbox_inches="tight", format="pdf")
# plt.show()
