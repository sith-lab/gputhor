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

std::string exec_cmd(const std::string& cmd) {
    std::array<char, 128> buffer;
    std::string result;

    std::unique_ptr<FILE, decltype(&pclose)> pipe(popen(cmd.c_str(), "r"), pclose);
    if (!pipe) {
        throw std::runtime_error("popen() failed!");
    }

    while (fgets(buffer.data(), buffer.size(), pipe.get()) != nullptr) {
        result += buffer.data();
    }
    return result;
}

int get_ecc_count()
{
  const std::string cmd = "nvidia-smi --query-gpu=ecc.errors.corrected.volatile.dram "
                      "--format=csv,noheader,nounits -i 0";
  try {
        std::string output = exec_cmd(cmd);

        // Trim trailing newline if present
        output.erase(output.find_last_not_of(" \n\r\t") + 1);

        // Convert to integer
        int dram_correctable = std::stoi(output);

        // std::cout << "Volatile DRAM Correctable ECC Errors (GPU 0): "
        //           << dram_correctable << std::endl;
        return dram_correctable;
    } catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << std::endl;
        return -1;
    }
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

void set_rows_with_bit(RowList &rows, std::vector<uint64_t> &target_rows,
                       uint64_t bit_pos, uint64_t b_count)
{
  for (const auto v : target_rows)
    set_row_with_bit(rows[v], bit_pos, b_count);
}

void set_row_with_bit(Row &row, uint64_t bit_pos, uint64_t b_count)
{
  static int numBlock   = std::get<0>(get_dim_from_size(b_count));
  static int numThreads = std::get<1>(get_dim_from_size(b_count));

  for (const auto addr : row) {
    set_address_bit_kernel<<<numBlock, numThreads>>>(addr, bit_pos, b_count);
    gpuErrchk(cudaPeekAtLastError());
  }
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


bool verify_all_content(RowList &rows, std::vector<uint64_t> &victims,
                        std::vector<uint64_t> &aggressors, 
                        const uint64_t b_count, const uint8_t pat, STATE_OBJECT *state_obj)
{
  int batchSize = 1;

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

  // TODO: set this threshold (in microseconds) based on observed baseline kernel duration
  constexpr long long ECC_TIMING_THRESHOLD_US = 1000;

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
    if (amount == 0)
      continue;

    cudaMemcpy(row_ids_device, row_ids_host, sizeof(int) * amount, cudaMemcpyHostToDevice);

    if (state_obj != nullptr)
    {
      auto t_start = std::chrono::high_resolution_clock::now();
      verify_result_kernel<<<amount, 256>>>(addrs_device, pat, b_count, diff_device, row_ids_device);
      cudaDeviceSynchronize();
      auto t_end = std::chrono::high_resolution_clock::now();
      long long duration_us = std::chrono::duration_cast<std::chrono::microseconds>(t_end - t_start).count();

      if (duration_us > ECC_TIMING_THRESHOLD_US)
      {
        std::cout << "Detected Corrections in Row: " << victims[i] << " (kernel duration: " << duration_us << " us), Starting Bit Search..." << std::endl;
        state_obj->state = SEARCH_STATE::BIT_SEARCH;
        state_obj->flipped_victim_row_id = victims[i];
        break;
      }
    }
    else
    {
      verify_result_kernel<<<amount, 256>>>(addrs_device, pat, b_count, diff_device, row_ids_device);
    }
  }
  cudaDeviceSynchronize();
  cudaMemcpy(&diff, diff_device, sizeof(bool *), cudaMemcpyDeviceToHost);
  cudaFree(diff_device);
  cudaFree(row_ids_device);
  cudaFree(addrs_device);

  return diff;
}


bool verify_all_content_bit_search_32B(RowList &rows, std::vector<uint64_t> &victims,
                        std::vector<uint64_t> &aggressors, 
                        const uint64_t b_count, const uint64_t bit_pos,
                        STATE_OBJECT *state_obj)
{
  const uint64_t WORD_BYTES = 32;
  const uint64_t WORDS_PER_SEG = b_count / WORD_BYTES;  // 256 / 32 = 8 words per segment

  bool *diff_device;
  bool diff = false;
  cudaMalloc(&diff_device, sizeof(bool));
  cudaMemset(diff_device, 0, sizeof(bool));

  uint8_t **addr_device;
  cudaMalloc(&addr_device, sizeof(uint8_t *));

  int *row_id_device;
  cudaMalloc(&row_id_device, sizeof(int));

  // TODO: set this threshold (in microseconds) based on observed baseline kernel duration
  constexpr long long ECC_TIMING_THRESHOLD_US = 1000;

  for (const uint64_t v : victims)
  {
    if (std::count(aggressors.begin(), aggressors.end(), v) != 0) continue;

    for (uint8_t *seg_addr : rows[v])
    {
      // Point the device pointer at this segment
      cudaMemcpy(addr_device, &seg_addr, sizeof(uint8_t *), cudaMemcpyHostToDevice);

      int row_id = (int)v;
      cudaMemcpy(row_id_device, &row_id, sizeof(int), cudaMemcpyHostToDevice);

      for (uint64_t word = 0; word < WORDS_PER_SEG; word++)
      {
        // One block of 32 threads — one thread per byte in this 32B word.
        // Reuse verify_result_bit_kernel with b_len=32 so addr_id=0, byte_id=0..31.
        // Pass a pointer offset to the start of the word so byte_id maps directly.
        uint8_t *word_addr = seg_addr + word * WORD_BYTES;
        cudaMemcpy(addr_device, &word_addr, sizeof(uint8_t *), cudaMemcpyHostToDevice);

        auto t_start = std::chrono::high_resolution_clock::now();
        verify_result_bit_kernel<<<1, WORD_BYTES>>>(addr_device, bit_pos, WORD_BYTES, diff_device, row_id_device);
        gpuErrchk(cudaPeekAtLastError());
        cudaDeviceSynchronize();
        auto t_end = std::chrono::high_resolution_clock::now();
        long long duration_us = std::chrono::duration_cast<std::chrono::microseconds>(t_end - t_start).count();

        if (state_obj != nullptr && duration_us > ECC_TIMING_THRESHOLD_US)
        {
          std::cout << "32B Detected Corrections in Row: " << v
                    << ", Word: " << word << " (kernel duration: " << duration_us << " us)" << std::endl;
          std::stringstream ss;
          ss << "Row: " << state_obj->flipped_victim_row_id << ", Segment Addr" << (void*) seg_addr <<  ", Which 32B word " << word << ", Which Bit " << bit_pos << '\n';
          state_obj->flips_in_victim.push_back(ss.str());
        }
      }
    }
  }

  
  cudaDeviceSynchronize();
  cudaMemcpy(&diff, diff_device, sizeof(bool), cudaMemcpyDeviceToHost);
  cudaFree(diff_device);
  cudaFree(row_id_device);
  cudaFree(addr_device);

  return diff;
}

bool verify_all_content_bit_search(RowList &rows, std::vector<uint64_t> &victims,
                        std::vector<uint64_t> &aggressors,
                        const uint64_t b_count, const uint64_t bit_pos,
                        STATE_OBJECT *state_obj)
{
  const uint64_t WORD_BYTES = 32;
  const uint64_t WORDS_PER_SEG = b_count / WORD_BYTES;

  // TODO: set this threshold (in microseconds) based on observed baseline kernel duration
  constexpr long long ECC_TIMING_THRESHOLD_US = 1000;

  bool *diff_device;
  bool diff = false;
  cudaMalloc(&diff_device, sizeof(bool));
  cudaMemset(diff_device, 0, sizeof(bool));

  uint8_t **addr_device;
  cudaMalloc(&addr_device, sizeof(uint8_t *));

  int *row_id_device;
  cudaMalloc(&row_id_device, sizeof(int));

  for (const uint64_t v : victims)
  {
    if (std::count(aggressors.begin(), aggressors.end(), v) != 0) continue;

    for (uint8_t *seg_addr : rows[v])
    {
      int row_id = (int)v;
      cudaMemcpy(row_id_device, &row_id, sizeof(int), cudaMemcpyHostToDevice);

      for (uint64_t word = 0; word < WORDS_PER_SEG; word++)
      {
        uint8_t *word_addr = seg_addr + word * WORD_BYTES;
        cudaMemcpy(addr_device, &word_addr, sizeof(uint8_t *), cudaMemcpyHostToDevice);

        auto t_start = std::chrono::high_resolution_clock::now();
        verify_result_bit_kernel<<<1, WORD_BYTES>>>(addr_device, bit_pos, WORD_BYTES, diff_device, row_id_device);
        gpuErrchk(cudaPeekAtLastError());
        cudaDeviceSynchronize();
        auto t_end = std::chrono::high_resolution_clock::now();
        long long duration_us = std::chrono::duration_cast<std::chrono::microseconds>(t_end - t_start).count();

        if (state_obj != nullptr && duration_us > ECC_TIMING_THRESHOLD_US)
        {
          std::cout << "Detected Corrections in Row: " << v
                    << ", Word: " << word << " (kernel duration: " << duration_us << " us)" << std::endl;
          diff = true;
          state_obj->flipped_bit_positions.push_back(bit_pos);
          state_obj->victim_flip_count++;
          std::stringstream ss;
          ss << "Row: " << state_obj->flipped_victim_row_id << ", Segment Addr: " << static_cast<void *>(seg_addr) << ", Which 32B word: " << word  << ", Which bit: " << bit_pos << '\n';
          state_obj->flips_in_victim.push_back(ss.str());
        }
      }
    }
  }

  cudaDeviceSynchronize();
  cudaMemcpy(&diff, diff_device, sizeof(bool), cudaMemcpyDeviceToHost);
  cudaFree(diff_device);
  cudaFree(row_id_device);
  cudaFree(addr_device);

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
  std::cout << CLI_PREFIX << "Took Approx: " << time_ns << "ns\n";
  std::cout << CLI_PREFIX << "Took Approx: " << (time_ns) / 1000.0 << "us\n";
  std::cout << CLI_PREFIX << "Took Approx: " << (time_ns) / 1000000.0 << "ms\n";
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
    set_address_kernel<<<numBlock, numThreads>>>(addr, pat, b_count);
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
  static long double clock_rate = []()
  {
    int clock_khz = 0;
    cudaDeviceGetAttribute(&clock_khz, cudaDevAttrClockRate, 0);
    std::cout << "Stable Max Clock Rate: "
              << ((long double)(clock_khz)) * 1000 << '\n';
    return ((long double)(clock_khz)) * 1000;
  }();

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
