# How to Use GPUThor

A step-by-step guide to running GPUThor manually and understanding the core components, beyond the automated
`run_artifact.sh` flow described in the [README](README.md).

## Repository Layout

Main folders and scripts under `HAMMER_ROOT`:

```text
📂 GPUThor/
├── 📂 src/: Core CUDA/C++ code.
│   ├── 📂 hammer/: Hammering and figure experiments.
│   ├── 📂 include/: Shared kernels and utilities.
├── 📂 util/: GPU setup, profiling, and campaign scripts.
├── 📂 plot_scripts/: Figure plotting scripts.
├── 📂 rowhammer_stats/: Bit-flip analysis on rowhammer output.
├── 📂 gpubreach-section8-DUE/: Section 8 DUE exploit.
├── 📂 nvflash/: NVIDIA flashing tools for InfoROM.
├── 📂 results/: Row sets, rowhammer output logs, plots, and samples.
│
├── 📄 build.sh: Builds GPUThor and the DUE exploit.
├── 📄 run_artifact.sh: Automated ECC-disabled experiments.
├── 📄 run_fig*.sh: Experiments for Figures 4, 6, and 7.
├── 📄 run_table3_campaign.sh: Table 3 bit-flip campaign (1000 rows).
├── 📄 run_ecc_exploit.sh: ECC-enabled exploit workflow.
├── 📄 run_row_sets.sh: Row-set generation.
├── 📄 flash_inforom.sh: Board-specific InfoROM backup/restore.
└── 📄 BANK_SET.txt: Bank offsets for row-set generation.
```

## 1. GPU System Setup

Same as [README Section 2](README.md#2-gpusystem-setup).

## 2. Building the Executables (`build.sh`)

`build.sh` in the repository root builds the executables. It has two targets:

- `src` — the top-level GPUThor rowhammer tool (`src/`), used by the ECC-disabled
  artifacts (Section 3).
- `due` — the GPUBreach Section 8 (DUE) exploit under `gpubreach-section8-DUE/`
  (its `gpuhammer`, `src`, and `cred_mod` kernel module), used by the
  ECC-enabled exploit (Section 4).

```bash
# Build both (default), or pass a single target: src | due | all
bash ./build.sh          # same as: bash ./build.sh all
bash ./build.sh src      # top-level GPUThor tool only
bash ./build.sh due      # GPUBreach Section 8 (DUE) exploit only
```

You do **not** need to run this manually for artifact evaluation: `run_artifact.sh`
builds the `src` target automatically (Section 3), and `run_ecc_exploit.sh`
builds both the `src` and `due` targets it needs (Section 4).

## 3. Generating Row Sets

After GPU setup and building the `src` target (Section 2), run from the repository root:

```bash
bash ./run_row_sets.sh
```

The script uses GPU memory-access timings to reverse-engineer bank and row
groupings in three stages:

1. `bank_set` finds offsets for four banks and writes `$HAMMER_ROOT/BANK_SET.txt`
   (assigned bank IDs 0–3 in file order).
2. `conf_set` finds addresses that cause row conflicts with each bank's offset,
   saving them to `results/row_sets/CONF_SET_<bank_id>.txt`.
3. `row_set` groups those offsets by DRAM row and writes
   `results/row_sets/ROW_SET_<bank_id>.txt`, with one row per line.

For more detail, run help on `util/run_timing_task.py`.

## 4. Flashing the InfoROM

From the repository root, stop GPU workloads and run:

```bash
bash ./flash_inforom.sh
```

The script unloads NVIDIA drivers and restores GPU 0's InfoROM from
`$HAMMER_ROOT/backup.ifr`, checking the board serial first. If the file is absent, it offers to create it and an embedded backup, then exits without flashing; rerun to restore.

**Risks:** Images are board-specific; flashing another board's image can corrupt
the GPU's InfoROM identity. Preserve the original backup, never bypass the serial check, and avoid interrupting power during flashing, which can leave InfoROM corrupted.

## 5. Running GPU Rowhammer

### 5.1 Finding Proper Delays

The `delays` parameter helps align attack patterns to TREFI, and is essential to breaking TRR defenses:

```bash
bash ./util/run_delay.sh
```

Given different GPU Rowhammer kernels and attack patterns require different delays, you can edit the `exe` parameter and the others to find delays for different GPU Rowhammer executables. By default, it runs on GPUThor.

### 5.2 Running the GPUThor Campaign

#### Without ECC

The following script allows you to hammer a single bank using its Row Set. Inspect the file and change its parameters for customized behavior:

```bash
bash ./util/run_gputhor.sh
```
**Dependency:** `run_ecc_exploit.sh` uses this in AE to check whether the DUE still exists.

For hammering more than one banks, adopt the following script or directly modify and run it:
```bash
bash run_table3_campaign.sh
```

#### With ECC

With ECC enabled, the Bank/Row Set obtained while its disabled is no longer useful and you need to regenerate them.

Afterwards, modify then run the following
```bash
bash util/run_ecc_campaign.sh
```

The ECC campaign will find bit flip locations through side-channel described in the paper. Depending on the vulnerability of a bank, can take at least 2-7 days for a bank on a single data pattern.

Another way to find bit flips is to simply trigger DUEs (Section 7.1 and 8.2 Approach 1). The following script can be used to find flips in one or more banks you specified. It automatically records the resulting flips when a DUE occurs, then continues by clearing the ecc error:

```bash
bash util/run_gputhor_find_due.sh
```

### 5.4 Finding Easy-to-Flip Bits (Figures 6 & 7)

On a new GPU, if you wish to run Figure 6 and 7, you will need a easy to flip bit (low HC_first < 16 K) to achieve similar results compared to the figures. GPUHammer is currently the best way to do that as it hammers with intensity 1 (16K ACT) already.

```bash
bash util/run_gpuhammer.sh
```

## 6. Misc

- The GPUThor kernels reside in src/include/rh_*.cuh and is directly named.
- The exploit in ECC setting is located in `gpubreach-section8-DUE`. It modifies the original GPUBreach by using cuMemMap to predict PTE corruptions. Look into `gpubreach-section8-DUE/src/s*.cu` for the detailed changes.