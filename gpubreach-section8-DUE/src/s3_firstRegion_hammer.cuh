#include <gpubreach_util.cuh>
#include <iostream>
#include <stdint.h>

#ifndef S3_FIRSTREGION_ATTACK_CUH
#define S3_FIRSTREGION_ATTACK_CUH

/**
 * @brief Step 3, Hammer the PT region PTEs, repeat until corrupted
 *
 * @param num_alloc_init size of allocation for alloc_all_mem
 * @param num_alloc_post_msg memory limit after massaging
 * @param threshold time deemed to be evictions
 * @param skip first few entries in case timing isn't reliable
 * @param out_region_ptrs returns memory pointers used to fill VRAM
 * @param out_agg_ptr returns memory pointers reserved by GPUHammer.
 * @param out_corrupted_ptr returns address with corrupted PTE we control
 * @param out_victim_ptr returns the address out_corrupted_ptr now point to
 * @param out_corrupt_id returns the index for out_corrupted_ptr in
 * out_region_ptrs
 * @param out_victim_id returns the index for out_victim_ptr in out_region_ptrs
 * @return false, Something is wrong. True otherwise.
 */
bool first_PT_region_attack (uint64_t num_alloc_init, double threshold,
                             uint64_t skip, GPUBreachContext &ctx);

/**
 * @brief Same as above but takes the arguments as command line, starting index
 * 0.
 */
bool first_PT_region_attack (int argc, char *argv[]);

#endif /* S3_FIRSTREGION_ATTACK_CUH */