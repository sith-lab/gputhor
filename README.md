# GPUThor (The ACM Conference on Computer and Communications Security (CCS) 2026)

## Introduction

This is the code artifact for the paper
**"GPUThor: Amplifying Rowhammer Attacks via Non-Uniform Patterns to Exploit ECC-Protected GPUs"**, to be presented at [The ACM Conference on Computer and Communications Security (CCS) 2026](https://www.sigsac.org/ccs/CCS2026/).

Authors: 
Chris S. Lin, Joyce Qu, Aditya Rajeev, Gururaj Saileshwar.
University of Toronto

## Results Reproduced by this Artifact

In this artifact, we aim to reproduce the following:

1. **Reverse-engineering measurements (Section 4 & 5)** — the memory coalescing behavior (Figure 4) and the intensity/tREFI analyses that characterize the GPUThor hammering primitive (Figures 6 and 7).

2. **GPUThor bit-flip campaign (Section 6)** — the multi-bank, multi-pattern campaign that demonstrates GPUThor's amplified flip rates (Table 3).

3. **Exploit w/ DUE under GPU ECC (Section 8)** - the GPUBreach-style exploit that escalates privilege on the host using the 10ms window after a _DUE_ during which the GPU memory remains accessible.

All of the results in items 1 and 2 are generated non-interactively by
`run_artifact.sh`.

Please see [HOW_TO_USE.md](HOW_TO_USE.md) for additional usage/implementation details.

> **NOTE:** We provide sample outputs of the automated experiments in the
> folder `results/sample` (`fig4.pdf`, `fig6.pdf`, `fig7.pdf`,
> `t3_flip_summary.txt`, and `t3_flip_summary.csv`) for reference.

## Required Environment

**Run-time Environment:** We follow a similar setup as prior work, GPUHammer.

- Software Dependencies:
   - CMake 3.22+
   - g++ with C++17 support
   - Python 3.10+ (the plotting/summary scripts install
     `matplotlib`, `numpy`, and `seaborn` from `requirements.txt`)
   - NVIDIA CUDA Driver 580.95.05
   - NVIDIA CUDA Toolkit
   - NVIDIA System Management Interface `nvidia-smi`

- Hardware Dependencies:
   - NVIDIA GPU sm_80+ (the build targets sm_86)

### Artifact Evaluation Environment

> Note: Other GPUs studied in this paper are accessed through cloud providers and are no longer available.

Our reference system:

- OS: Ubuntu 22.04 LTS
- GPU: NVIDIA RTX A6000 (48 GB GDDR6, sm_86)
- Driver: NVIDIA driver 580.95.05 (includes `nvidia-smi`)
- CUDA Toolkit: 12.8

## Steps for Artifact Evaluation

## 1. (Ignore if using Zenodo) Repository Setup

Ensure you have already cloned the repository and are in its root directory:

```bash
git clone https://github.com/sith-lab/gputhor.git
cd gputhor
```

## 2. GPU/System Setup

All scripts locate files relative to the repository root through the
`HAMMER_ROOT` environment variable. Set it once per terminal (or add it to
`.bashrc`):

```bash
# Run this from the repository root.
export HAMMER_ROOT=`pwd`
```

Our code can be run with or without ECC. The following snippet shows how to enable/disable ECC:


```bash
sudo rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia

# Disable ECC
sudo nvidia-smi -e 0

# or

# Enable ECC
sudo nvidia-smi -e 1

sudo reboot
```

The automated experiments in Section 4 (Figures 4, 6, 7 and Table 3) run with
**ECC disabled**. We observe that this is the default setting on A6000 GPUs on
many cloud providers.

Our profiling is easier with persistence mode enabled and with fixed GPU and
memory clock rates, although these are not hard prerequisites (we reproduced our results on cloud-hosted GPUs without fixing their clock rates). `run_artifact.sh` applies
the clocks automatically; you can also apply them manually:

```bash
# Example usage:
#  bash ./util/init_cuda.sh <MAX_GPU_CLOCK> <MAX_MEMORY_CLOCK>
bash ./util/init_cuda.sh 1800 8000
```

**MAX_GPU_CLOCK** and **MAX_MEMORY_CLOCK** are the **Application Clocks** from
`nvidia-smi`. Clock changes can be undone with `bash ./util/reset_cuda.sh`.

## 3. Run Artifacts (ECC-disabled)

Run the following commands to set up environment variables, install dependencies, build GPUThor, and run the artifacts.

```bash
# HAMMER_ROOT must be set (see Step 2).
bash ./run_artifact.sh
```

`run_artifact.sh` installs the Python
dependencies from `requirements.txt`, fixes the GPU clocks with
`util/init_cuda.sh`, and builds GPUThor.

Then, the script runs, in order:

```
1. run_fig4.sh              (<5 min)
2. run_fig6.sh              (<45 min)
3. run_fig7.sh              (~1 h 15 min)
4. run_table3_campaign.sh   (~1 h 30 min)
```

Total estimated runtime is about 3.5 hours. Each step's console output is also
saved to a timestamped log directory, `results/artifact_run_<timestamp>/`, and
the script prints a per-step summary at the end.

You can also run any step on its own with the corresponding
`run_figN.sh` / `run_table3_campaign.sh` script.

---

### Figure 4 (`run_fig4.sh`)

Produces timing measurements for same/different-cacheline accesses in same-warp and cross-warp scenarios, sweeping intensity levels.

Reproduced with `bash run_fig4.sh`. The result is reproduced successfully if the
output at `results/fig4.pdf` shows different-warp different-cacheline configuration to match exactly with red baseline line where all access are to different rows, while deviating on other configurations, using `./results/sample/fig4.pdf` as a reference.

### Figure 6 (`run_fig6.sh`)

Produces bit-flip reproduction-rate measurements for hammering across different tREFI lengths (1 to 36) with varying intensity (2x to 4x).

Reproduced with `bash run_fig6.sh`. The result is reproduced successfully if the
output at `results/fig6.pdf` shows that most pattern lengths that divide 72 (2, 3, 4, 6, 8, 9, 12, 18, 24, 36) can reproduce bit flips, using `./results/sample/fig6.pdf` as a reference.

> Note: The reproduced Figure 6 may differ from the figure in the paper, as we scaled down this experiment for a more reasonable runtime (4+ days otherwise), by running across a smaller set of offsets. This may cause some of the pattern lengths to not reproduce bit flips or have lower probabilities than in the paper in the resulting figure. The core claims remain.

### Figure 7 (`run_fig7.sh`)

Demonstrates the maximum hammering intensity (ACT/tREFI) sustainable for
different multi-tREFI configurations (tREFI of 3, 4, 6, 9, 18, and 24). It runs
the `intensity_analysis_NtREFI` binary over several independent trials, then
aggregates them.

Reproduced with `bash run_fig7.sh`. The aggregated data is written to
`results/fig7_output.csv` and the plot to `results/fig7.pdf`. The result is
reproduced successfully if the flip probability drops in higher intensities (6, 7, 8) and that 6 TREFI pattern is relatively better than the others at 6 ACTs/tREFI. See `./results/sample/fig7.pdf` for reference.

> Note: For the paper, we performed this experiment on an A5000, while for AE, we are using an A6000, which may be using different memory chips. This causes our figure to look different from the figure in the paper, but the claim remains.

### Table 3 (`run_table3_campaign.sh`)

Runs the GPUThor campaign across 4 banks and 4
victim/aggressor data patterns (`55/aa`, `aa/55`, `00/ff`, `ff/00`) for 1000 rows per bank. Then it collects and summarizes the
bit-flip statistics with `rowhammer_stats/collector.py` and
`rowhammer_stats/flip_summary.py`.

Reproduced with `bash run_table3_campaign.sh`. The summary is written to
`results/t3_campaign/flip_summary.txt` (and `flip_summary.csv`). The result is
reproduced successfully if the following statistics:
- "Avg. Flip / Row"
- "Avg. Flip / GB"
- "Flip / Hour"

are in relatively the same range as the paper, using `./results/sample/t3_flip_summary.txt` as a reference. Note that not all flips reproduce every run due to the temporal randomness of Rowhammer, and fluctuations are expected.

> Note: To keep runtime reasonable for AE, we only hammer 1000 rows per bank, whereas a full bank contains ~64000 rows. Consequently, the "Total Unique Flips" and "Avg. Flip / Bank" are smaller than the paper's full-campaign numbers, while the rate-based statistics ("Avg. Flip / Row", "Avg. Flip / GB", and "Flip / Hour") are scale-invariant and should fall in a similar range. Regardless, the summary also reports two **estimated** "Total Unique Flips" and "Avg. Flip / Bank" statistics under the `ESTIMATED FULL BANK` section for reference.


## 4. Run Artifact (ECC-enabled)

As per [2. GPU / System Setup](#2-gpusystem-setup), run the following to enable ECC and reboot the system:

```bash
sudo rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia

# Enable ECC
sudo nvidia-smi -e 1

sudo reboot
```

> Note: After completing the evaluation, please disable ECC for the next reviewer.

Now, run the following to perform the exploit using DUE:

```
bash run_ecc_exploit.sh
```

The script is mostly non-interactive, until it opens an interactive _Root Shell_, which you can use to verify the exploit. Simply enter `exit` when you want to exit.

> Note 1: the program will exit gracefully when you exit the root shell or after five failed exploit attempts. Please avoid force quitting it.

> Note 2: after a fresh reboot, an uncorrectable DRAM error (DUE) may not immediately be present and the script first hammers continuously to check when it re-appears. **This can take anywhere from a few minutes up to about 24 hours.** The script is not hung during this phase — please let it run; the waiting period is expected.


### Exploit w/ DUE (`run_ecc_exploit.sh`)

Performs the GPUBreach-style exploit with ECC-enabled, leveraging the 10ms window after a DUE, during which the GPU remains accessible for memory accesses.

Reproduced with `bash run_ecc_exploit.sh`. The result is reproduced successfully if the script eventually opens a _Root Shell_ from this script, which the reviewer can interact with. For instance, the reviewer can verify it is a root shell by inspecting command outputs such as from `whoami` and `ps -u`.

