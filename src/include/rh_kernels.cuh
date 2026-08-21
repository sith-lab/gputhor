#include <fstream>
#include <stdint.h>
#include <stdio.h>
#include <vector>
#include <iostream>
#include <cuda_runtime.h>
#ifndef GPU_ROWHAMMER_RH_KERNELS_CUH
#define GPU_ROWHAMMER_RH_KERNELS_CUH

__global__ void set_address_kernel(uint8_t *addr_arr, uint64_t value,
                                   uint64_t b_len);
__global__ void set_address_bit_kernel(uint8_t *addr_arr, uint64_t bit_pos,
                                       uint64_t b_len);
__global__ void clear_address_kernel(uint8_t *addr, uint64_t step);

__global__ void evict_kernel(uint8_t *addr, uint64_t size);

__global__ void verify_result_kernel(uint8_t **addr_arr, uint64_t target,
  uint64_t b_len, bool *has_diff, int *row_ids);
__global__ void verify_result_bit_kernel(uint8_t **addr_arr, uint64_t bit_pos,
                                         uint64_t b_len, bool *has_diff, int *row_ids);
__global__ void simple_hammer_kernel(uint8_t **addr_arr, uint64_t count, uint64_t* time);

__global__ void single_thread_hammer_kernel(uint8_t **addr_arr, uint64_t count, uint64_t n, uint64_t *time);

__global__ void sync_hammer_kernel(uint8_t **addr_arr, uint64_t count,
                                   uint64_t delay, uint64_t period,
                                   uint64_t *time);

__global__ void warp_simple_hammer_kernel(uint8_t **addr_arr, uint64_t count, uint64_t n, uint64_t k, uint64_t len, uint64_t delay, uint64_t period, uint64_t* time);

__global__ void gputhor_hammer(uint8_t **addr_arr, uint64_t count, uint64_t n, uint64_t k, uint64_t len, uint64_t delay, uint64_t period, int trefi, uint64_t* time);

__global__ void gputhor_nonuniform_kernel(uint8_t **addr_arr, uint64_t count, 
                                     uint64_t n, uint64_t k, uint64_t len, 
                                     uint64_t delay, uint64_t period, int trefi, 
                                     uint64_t* time);

__global__ void rh_threshold_kernel(uint8_t **agg_arr, uint8_t **dum_arr, 
                                    uint64_t count, uint64_t n, uint64_t k, 
                                    uint64_t len, uint64_t delay, uint64_t period,
                                    uint64_t* time, 
                                    uint64_t agg_period, uint64_t dum_period);

#endif /* GPU_ROWHAMMER_RH_KERNELS_CUH */