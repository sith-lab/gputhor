#include <rh_kernels.cuh>
#include <rh_utils.cuh>
#include <algorithm>
#include <array>
#include <chrono>
#include <ctime>
#include <fstream>
#include <memory>
#include <random>
#include <set>
#include <sstream>
#include <thread>
#include <iostream>

static void set_row(Row &row, uint8_t pat, uint64_t b_count);
static void clear_L2cache_row(Row &row, uint64_t step);
inline uint64_t CurrentTime_nanoseconds()
{
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             std::chrono::high_resolution_clock::now().time_since_epoch())
      .count();
}

/**
 * @brief Returns the row set in matrix form as seen in the file. Each newline
 * is a row and addresses are tab-seperated
 *
 * @param file
 * @param base_addr
 * @return RowList
 */
RowList read_row_from_file(std::ifstream &file, const uint8_t *base_addr)
{
  std::string buf;
  std::vector<std::vector<uint8_t *>> rows;
  while (std::getline(file, buf))
  {
    rows.emplace_back();
    std::stringstream ss;
    ss << buf;
    while (std::getline(ss, buf, '\t'))
      rows.back().push_back((uint8_t *)(base_addr + std::stoull(buf)));
  }
  return rows;
}

std::vector<uint64_t> get_sequential_victims(RowList &rows, uint64_t row_id,
                                             uint64_t v_count)
{
  std::vector<uint64_t> vic_vec(v_count);
  std::generate(vic_vec.begin(), vic_vec.end(),
                [value = row_id - 2]() mutable -> uint64_t
                {
                  value += 2;
                  return value;
                });
  return vic_vec;
}

/**
 * @brief From victims, get the rows around it to be aggressors
 *
 * @param victims
 * @return std::vector<uint64_t>
 */
std::vector<uint64_t> get_aggressors(std::vector<uint64_t> &victims)
{
  std::set<uint64_t> agg;
  for (const auto &vic : victims)
  {
    agg.insert(vic + 1);
    agg.insert(vic - 1);
  }
  return {agg.begin(), agg.end()};
}

// with variable step size
std::vector<uint64_t> get_sequential_victims(RowList &rows, uint64_t row_id,
                                             uint64_t num_vic, uint64_t step)
{
  std::vector<uint64_t> vic_vec(num_vic);
  std::generate(vic_vec.begin(), vic_vec.end(),
                [value = row_id - step * 3 / 2, step = step]() mutable -> uint64_t
                {
                  value += step;
                  return value;
                });
  return vic_vec;
}

std::vector<uint64_t> get_aggressors(RowList &rows, uint64_t row_id,
                                     uint64_t num_agg, uint64_t step)
{
  std::vector<uint64_t> agg_vec(num_agg);
  std::generate(agg_vec.begin(), agg_vec.end(),
                [value = row_id - step, step = step]() mutable -> uint64_t
                {
                  value += step;
                  return value;
                });
  return agg_vec;
}

std::vector<uint64_t> get_aggressors_dir(RowList &rows, uint64_t row_id,
                                     uint64_t num_agg, uint64_t step, bool left)
{
  std::vector<uint64_t> agg_vec(num_agg);
  std::generate(agg_vec.begin(), agg_vec.end(),
                [value = row_id + (left ? step : -step), &step, &left]() mutable -> uint64_t
                {
                  value += left ? -step : step;
                  return value;
                });
  if (left)
    std::reverse(agg_vec.begin(), agg_vec.end());
  return agg_vec;
}

/**
 * @brief Helper function to set all the target rows to pat
 *
 * @param rows
 * @param target_rows
 * @param pat
 * @param b_count byte difference between each address
 */
void set_rows(RowList &rows, std::vector<uint64_t> &target_rows, uint8_t pat,
              uint64_t b_count)
{
  for (const auto v : target_rows)
    set_row(rows[v], pat, b_count);
}

void clear_L2cache_rows(RowList &rows, std::vector<uint64_t> &target_rows, uint64_t step)
{
  for (const auto v : target_rows)
    clear_L2cache_row(rows[v], step);
}

bool verify_all_content(RowList &rows, std::vector<uint64_t> &victims,
                        std::vector<uint64_t> &aggressors, 
                        const uint64_t b_count, const uint8_t pat)
{
  int batchSize = 64;

  bool *diff_device;
  bool diff;
  cudaMalloc(&diff_device, sizeof(bool *));
  cudaMemset(diff_device, 0, sizeof(bool *));

  uint8_t **addrs_device;
  cudaMalloc(&addrs_device, sizeof(uint8_t *) * 8 * batchSize);

  // Store and pass row IDs to the kernel to be printed.
  int *row_ids_device;
  int row_ids_host[8 * batchSize];
  cudaMalloc(&row_ids_device, sizeof(int) * 8 * batchSize);

  for (int i = 0; i < victims.size(); i += batchSize)
  {
    int amount = 0;
    for (int j = i; j < i + batchSize && j < victims.size(); j++)
    {
      auto& v = victims[j];
      if (std::count(aggressors.begin(), aggressors.end(), v) != 0) continue;

      int size = rows[v].size() <= 8 ? rows[v].size() : 8;
      cudaMemcpy(addrs_device + amount, rows[v].data(), size * sizeof(uint8_t *), cudaMemcpyHostToDevice);
      for (int k = 0; k < size; ++k)
        row_ids_host[amount + k] = v;
      amount += size;
    }
    
    cudaMemcpy(row_ids_device, row_ids_host, sizeof(int) * amount, cudaMemcpyHostToDevice);

    verify_result_kernel<<<amount, 256>>>(addrs_device, pat, b_count, diff_device, row_ids_device);
  }

  cudaDeviceSynchronize();
  cudaMemcpy(&diff, diff_device, sizeof(bool *), cudaMemcpyDeviceToHost);
  cudaFree(diff_device);
  cudaFree(row_ids_device);
  cudaFree(addrs_device);

  return diff;
}

/**
 * @brief Attempts to Evicts the L2 cache to enforce write backs for rows we
 * just set patterns to.
 *
 * @param layout
 */
void evict_L2cache(uint8_t *layout)
{
  struct cudaDeviceProp device_prop;
  cudaGetDeviceProperties(&device_prop, 0);

  uint64_t size = device_prop.l2CacheSize * 8;
  static uint64_t maxThreads = []()
  {
    struct cudaDeviceProp device_prop;
    cudaGetDeviceProperties(&device_prop, 0);
    return device_prop.maxThreadsDim[2];
  }();
  
  evict_kernel<<<1, maxThreads>>>(layout, size / maxThreads);
}

void print_time(uint64_t time_ns)
{
  std::cout << "Took Approx: " << time_ns << "ns\n";
  std::cout << "Took Approx: " << (time_ns) / 1000.0 << "us\n";
  std::cout << "Took Approx: " << (time_ns) / 1000000.0 << "ms\n";
}

/**
 * @brief Set the b_count bytes of each address in row to pat. This uses L2
 * cache.
 *
 * @param row
 * @param pat
 * @param b_count
 */
void set_row(Row &row, uint8_t pat, uint64_t b_count)
{
  /* Constant for this function */
  static int numBlock = std::get<0>(get_dim_from_size(b_count));
  static int numThreads = std::get<1>(get_dim_from_size(b_count));

  for (const auto addr : row) {
    set_address_kernel<<<1, 1>>>(addr, pat, b_count);
    gpuErrchk(cudaPeekAtLastError());
  }
}

void clear_L2cache_row(Row &row, uint64_t step)
{
  for (auto addr : row)
    clear_address_kernel<<<1, 1>>>(addr, step);
}

/**
 * @brief Returns the GPU clock value in nanoseconds.
 *
 * @param time GPU clock value
 * @return uint64_t time in nanoseconds
 */
uint64_t toNS(uint64_t time)
{
  /* System variable that should be constant in a run. */
  static long double clock_rate = []()
  {
    struct cudaDeviceProp device_prop;
    cudaGetDeviceProperties(&device_prop, 0);
    // std::cout << "Stable Max Clock Rate: "
    //           << ((long double)(device_prop.clockRate)) * 1000 << '\n';
    // std::cout << "Using Current Clock Rate: " << ((long double)(val)) <<
    // '\n';
    return ((long double)(device_prop.clockRate)) * 1000;
  }();

  // TODO: Later we might need dynamic clockRate for attack./
  return (time / clock_rate) * 1000000000.0;
}

/**
 * @brief Get the dimension of the suitable kernel for size
 *
 * @param size
 * @return std::tuple<int, int> first is Blocks and seconds is threads
 */
std::tuple<int, int> get_dim_from_size(uint64_t size)
{
  /* Constant in the system */
  static uint64_t maxThreads = []()
  {
    struct cudaDeviceProp device_prop;
    cudaGetDeviceProperties(&device_prop, 0);
    return device_prop.maxThreadsDim[2];
  }();

  /* Depending on std::string CLI_PREFIX = "(bitflip-characterization): ";size, dispatch dimension needed to handle the payload */
  int numBlocks = (size + (maxThreads - 1)) / maxThreads;
  int numThreads = size > maxThreads ? maxThreads : size;
  return std::make_tuple<>(numBlocks, numThreads);
}
