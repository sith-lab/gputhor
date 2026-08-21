#include <gpubreach_util.cuh>
#include <iostream>
#include <stdint.h>

#ifndef S2_FIRSTREGION_CUH
#define S2_FIRSTREGION_CUH

/**
 * @brief Test the PT region timing side-channel for section 5 step 2.
 *
 * @param argc 3
 * @param argv [0] num_alloc_init [1] threshold [2] skip. Detail see
 * first_PT_region comment.
 * @param alloc_ptrs returns the list of pointers allocated
 */
void first_PT_region_test (int argc, char *argv[]);

/**
 * @brief Step 2, Massages the first PT region to a desired memory space.
 *
 * @param num_alloc_init size of allocation for alloc_all_mem
 * @param threshold time deemed to be evictions
 * @param skip first few entries in case timing isn't reliable
 * @param agg_ptrs returns memory pointers reserved by GPUHammer here for
 * future steps
 * @param agg_row_list returns a minimal row_list used for launching GPUHammer
 * @param agg_vec returns the minimal aggressor row ids used for launching
 * GPUHammer
 * @return false, Something is wrong. True otherwise.
 */
bool first_PT_region (uint64_t num_alloc_init, double threshold, uint64_t skip,
                      GPUBreachContext &ctx);

/**
 * @brief Same as above but takes the arguments as command line, starting index
 * 0.
 */
bool first_PT_region (int argc, char *argv[]);

#endif /* S2_FIRSTREGION_CUH */