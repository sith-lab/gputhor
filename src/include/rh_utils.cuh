#include <atomic>
#include <iostream>
#include <iterator>
#include <sstream>
#include <stdint.h>
#include <stdio.h>
#include <vector>
#ifndef GPU_ROWHAMMER_RH_UTIL_CUH
#define GPU_ROWHAMMER_RH_UTIL_CUH

#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true)
{
   if (code != cudaSuccess) 
   {
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}

using RowList = std::vector<std::vector<uint8_t *>>;
using Row = std::vector<uint8_t *>;
enum SEARCH_STATE
{
  SEGMENT_ROW_SEARCH,
  SECTOR_32B_SEARCH,
  BIT_SEARCH,
};
struct STATE_OBJECT
{
  SEARCH_STATE state;
  uint64_t flipped_victim_row_id;
  std::vector<uint8_t> flipped_bit_positions;
  std::vector<std::string> flips_in_victim;
  // Number of bit flips found in the current target victim during BIT_SEARCH.
  // Reset to 0 once we are done with a target victim.
  uint32_t victim_flip_count = 0;
};

enum MEM_PAT
{
  VICTIM_PAT = 0xAA, 
  AGGRES_PAT = 0x55
  // Alternative padding patterns:
  // VICTIM_PAT = 0x55,
  // AGGRES_PAT = 0xAA
};

extern std::string CLI_PREFIX;

RowList read_row_from_file(std::ifstream &file, const uint8_t *base_addr);

std::vector<uint64_t> get_sequential_victims(RowList &rows, uint64_t row_id,
                                             uint64_t v_count);

std::vector<uint64_t> get_sequential_victims(RowList &rows, uint64_t row_id,
                                             uint64_t num_vic, uint64_t step);

std::vector<uint64_t> get_aggressors(std::vector<uint64_t> &victims);

std::vector<uint64_t> get_aggressors(RowList &rows, uint64_t row_id,
                                     uint64_t num_agg, uint64_t step);

void set_rows(RowList &rows, std::vector<uint64_t> &target_rows, uint8_t pat,
              uint64_t b_count);
void set_rows_with_bit(RowList &rows, std::vector<uint64_t> &target_rows,
                       uint64_t bit_pos, uint64_t b_count);
void set_row_with_bit(Row &row, uint64_t bit_pos, uint64_t b_count);

void clear_L2cache_rows(RowList &rows, std::vector<uint64_t> &target_rows, uint64_t step);

bool verify_all_content(RowList &rows, std::vector<uint64_t> &victims,
                        std::vector<uint64_t> &aggressors, 
                        const uint64_t b_count, const uint8_t pat);
bool verify_all_content(RowList &rows, std::vector<uint64_t> &victims,
                        std::vector<uint64_t> &aggressors, 
                        const uint64_t b_count, const uint8_t pat, STATE_OBJECT *state_obj);
bool verify_all_content_bit_search_32B(RowList &rows, std::vector<uint64_t> &victims,
                        std::vector<uint64_t> &aggressors, 
                        const uint64_t b_count, const uint64_t bit_pos,
                        STATE_OBJECT *state_obj);
bool verify_all_content_bit_search(RowList &rows, std::vector<uint64_t> &victims,
                        std::vector<uint64_t> &aggressors, 
                        const uint64_t b_count, const uint64_t bit_pos,
                        STATE_OBJECT *state_obj);
void evict_L2cache(uint8_t *layout);

void print_time (uint64_t time_ns);

uint64_t toNS(uint64_t time);

std::tuple<int, int> get_dim_from_size(uint64_t size);

/* Returns vector in string form, thats it. */
template <typename T> std::string vector_str(const std::vector<T> &vec)
{
  std::ostringstream oss;
  oss << '[';
  std::copy(vec.begin(), vec.end(), std::ostream_iterator<T>(oss, ", "));
  oss << ']';
  return oss.str();
}


#endif /* GPU_ROWHAMMER_RH_UTIL_CUH */