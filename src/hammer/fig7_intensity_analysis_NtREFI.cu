

#include <rh_utils.cuh>
#include <rh_impls.cuh>

#include <atomic>
#include <chrono>
#include <fstream>
#include <iostream>
#include <pthread.h>
#include <stdint.h>
#include <vector>
#include <numeric>
#include <chrono>
#include <random>
#include <algorithm>
#include <unordered_map>
#include <functional>
#include <random>
#include <set>

std::string CLI_PREFIX = "(gpu-thor-fig7): ";

std::vector<uint64_t> generate_victims(std::vector<uint64_t> aggressors, 
                                        uint64_t num_rows, uint64_t radius) {
    std::set<uint64_t> victim_set;
    for (auto a : aggressors) {
        for (uint64_t victim = a - radius; victim <= a + radius; victim++) {
            if (victim >= num_rows) continue;
            victim_set.insert(victim);
        }
    }

    std::vector<uint64_t> victims(victim_set.begin(), victim_set.end());
    return victims;
}

int main(int argc, char *argv[])
{
  const uint64_t num_acts    = std::stoull(argv[2]);
  const uint64_t step       = std::stoull(argv[3]);
  const uint64_t it         = std::stoull(argv[4]);
  const uint64_t min_rowId  = std::stoull(argv[5]);
  const uint64_t max_rowId  = std::stoull(argv[6]);
  const uint64_t row_step   = std::stoull(argv[7]);
  const uint64_t skip_step  = std::stoull(argv[8]);
  const uint64_t size       = std::stoull(argv[9]);
  const uint64_t n          = std::stoull(argv[10]);
  const uint64_t k          = std::stoull(argv[11]);
  const uint64_t delay      = std::stoull(argv[12]);
  const uint64_t period     = std::stoull(argv[13]);
  const uint64_t count_iter = std::stoull(argv[14]);
  const uint64_t num_rows   = std::stoull(argv[15]);
  const uint64_t vic_pat    = std::stoull(argv[16], nullptr, 16);
  const uint64_t agg_pat    = std::stoull(argv[17], nullptr, 16);
  const uint64_t trefi    = std::stoull(argv[18]);
  const uint64_t total_acts    = std::stoull(argv[19]);
  std::ofstream bitflip_file(argv[20]);
  std::random_device rd;
  std::mt19937 gen(rd());

  /* Read the row set */
  uint8_t *layout;
  cudaMalloc(&layout, size);
  
  std::ifstream row_set_file(argv[1]);
  RowList rows = read_row_from_file(row_set_file, layout);
  row_set_file.close();

  std::cout << CLI_PREFIX << "Layout address: " << static_cast<void*>(layout) << '\n';
  std::cout << std::hex;
  std::cout << CLI_PREFIX << "Victim pattern: " << vic_pat << '\n';
  std::cout << CLI_PREFIX << "Aggressor pattern: " << agg_pat << '\n';
  std::cout << std::dec;

  /* Initialize all rows */
  std::vector<uint64_t> all_vics(num_rows);
  std::iota(all_vics.begin(), all_vics.end(), 0);
  set_rows(rows, all_vics, vic_pat, step);
  cudaDeviceSynchronize();

  /* Dummy hammer to keep timing consistent, due to device startup time */
  // for (int i = 0; i < 10000; i++)
  //   start_simple_hammer(rows, all_vics, 1);
  // cudaDeviceSynchronize();

  /*************************************************************************************/

  for (int i = min_rowId; i < max_rowId; i += skip_step) {

    int bitflip_count = 0;

    std::cout << '\n';
    std::cout << CLI_PREFIX << "Chosen Critical Aggressor: " << i << std::endl;
    std::cout << CLI_PREFIX << "==========================================================" << std::endl;
    

    for (int j = 0; j < count_iter; j++) {

      /* Generate hammering patterns */
      std::vector<uint64_t> aggressors = get_aggressors(rows, i, num_acts, row_step);
      std::vector<uint64_t> victims    = generate_victims(aggressors, num_rows, 16);

      /*********** Generate our own aggressor pattern ***********/
      auto target = aggressors[0];
      aggressors.clear();
      aggressors.push_back(32 + 4);

      for (int z = 1; z < num_acts * trefi; z++)
        aggressors.push_back(aggressors.back() + 4);

      uint64_t usable_blocks = trefi - 1;
      uint64_t remaining = total_acts;
      
      for (uint64_t pos = 0; pos < num_acts && remaining > 0; pos += k)
      {
        for (uint64_t b = 0; b < usable_blocks && remaining > 0; b++)
        {
          aggressors[b * num_acts + pos] = target;
          remaining--;
        }
      }
      
      for (uint64_t pos = 2; pos < num_acts && remaining > 0; pos += k)
      {
        for (uint64_t b = 0; b < usable_blocks && remaining > 0; b++)
        {
          aggressors[b * num_acts + pos] = target + 1;
          remaining--;
        }
      }

      /*********** Generate our own aggressor pattern ***********/

      std::cout << CLI_PREFIX << "Chosen Victims: " << vector_str(victims) << std::endl;
      std::cout << CLI_PREFIX << "Chosen Aggressors: " << vector_str(aggressors) << std::endl;
      std::cout << CLI_PREFIX << "Aggressor Iteration: " << j << std::endl;
      auto start_loop = std::chrono::high_resolution_clock::now();

      set_rows(rows, victims, vic_pat, step);
      set_rows(rows, aggressors, agg_pat, step);
      cudaDeviceSynchronize();
      evict_L2cache(layout);
      cudaDeviceSynchronize();

      auto start_hammer = std::chrono::high_resolution_clock::now();

      /* Start the hammering and measure the time */
      uint64_t time = gputhor_nonuniform_hammer(rows, aggressors, it, n, k, num_acts, delay, period, trefi);
      print_time(time);
      std::cout << CLI_PREFIX << "Average time per round: " << time / it << std::endl;
      gpuErrchk(cudaPeekAtLastError());

      auto end_hammer = std::chrono::high_resolution_clock::now();

      /* Verify result */
      evict_L2cache(layout);

      bool res = verify_all_content(rows, victims, aggressors, step, vic_pat);
      std::cout << CLI_PREFIX << "Bit-flip in victim rows: " 
                              << (res ? "Observed Bit-Flip" : "No Bit-Flip") << std::endl;
      if (res) bitflip_count ++;
      gpuErrchk(cudaPeekAtLastError());

      /* Clean up and prepare for next launch*/
      cudaDeviceSynchronize();
      auto end_loop = std::chrono::high_resolution_clock::now();

      std::chrono::duration<double, std::milli> duration_evict = start_hammer - start_loop;
      std::chrono::duration<double, std::milli> duration_hammer = end_hammer - start_hammer;
      std::chrono::duration<double, std::milli> duration_verify = end_loop - end_hammer;
      std::chrono::duration<double, std::milli> duration_total = end_loop - start_loop;
      std::cout << CLI_PREFIX << "Evict time: " << duration_evict.count() << " ms" << std::endl;
      std::cout << CLI_PREFIX << "Hammer time: " << duration_hammer.count() << " ms" << std::endl;
      std::cout << CLI_PREFIX << "Verify time: " << duration_verify.count() << " ms" << std::endl;
      std::cout << CLI_PREFIX << "Total time: " << duration_total.count() << " ms" << std::endl;

      std::cout << CLI_PREFIX << "==========================================================" << std::endl;
    }
  
    bitflip_file << bitflip_count << std::endl;
    bitflip_file.flush();
    
  }

  bitflip_file.close();
  cudaFree(layout);
  return 0;
}