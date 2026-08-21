

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

std::string CLI_PREFIX = "(gpu-hammer): ";

/** Compute positions for aggressors based on their counts.
 * @param aggressors a vector of aggressor row IDs
 * @return a vector of positions corresponding to each aggressor
 */
std::vector<uint64_t> compute_positions(const std::vector<uint64_t>& aggressors) {
    std::unordered_map<uint64_t, uint64_t> counts;
    std::vector<uint64_t> positions;
    positions.reserve(aggressors.size());

    for (const auto& a : aggressors) {
        uint64_t pos = counts[a] % 8;
        positions.push_back(pos);
        counts[a]++;
    }
    return positions;
}


std::vector<std::vector<int>> read_good_combos(const std::string &filename, int num_reps) {
  std::vector<std::vector<int>> results;
  std::ifstream infile(filename);
  std::string line;

  while (std::getline(infile, line)) {
    std::istringstream iss(line);
    std::vector<int> row;
    int val;
    for (int i = 0; i < num_reps && iss >> val; i++) {
      row.push_back(val);
    }
    results.push_back(row);
  }
  return results;
}


std::vector<uint64_t> generate_pattern(std::mt19937& gen,
                                        RowList rows, std::vector<std::vector<int>> combos,
                                        uint64_t num_rows, uint64_t num_acts, 
                                        uint64_t row_step, uint64_t crit_agg)
{
  std::uniform_int_distribution<> row_dist(0, num_rows - num_acts * row_step - 1);
  std::uniform_int_distribution<> pos_dist(0, combos.size() - 1);

  /* Determine the base pattern */
//   int dummy_row = row_dist(gen);
  std::vector<uint64_t> aggressors = get_aggressors(rows, crit_agg + row_step, num_acts, row_step);

  /* Determine location(s) for the critical aggressor */
  int crit_pos = pos_dist(gen);
  for (auto x : combos[crit_pos]) {
      aggressors[x] = crit_agg;
  }

  return aggressors;
}


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

bool isValid(const std::vector<int>& combo, int candidate, 
             int num_warps, int num_threads) {
    for (int x : combo) {
        // Make sure they're not in the same warp
        if (x / num_threads == candidate / num_threads) return false;  // Grouped by warps
        // if (x % num_warps == candidate % num_warps) return false;  // Grouped by threads
    }
    return true;
}

std::vector<std::vector<int>> generate_combinations(int num_agg, int num_reps,
                                                   int num_warps, int num_threads) {
    std::vector<std::vector<int>> result;
    std::vector<int> combo;

    std::function<void(int, int)> backtrack = [&](int start, int depth) {
        if (depth == num_reps) {
            result.push_back(combo);
            return;
        }
        for (int i = start; i < num_agg; ++i) {
            if (!isValid(combo, i, num_warps, num_threads)) continue;
            combo.push_back(i);
            backtrack(i + 1, depth + 1);
            combo.pop_back();
        }
    };

    backtrack(0, 0);
    return result;
}


void print2D(const std::vector<std::vector<int>>& result) {
    for (const auto& row : result) {
        for (const auto& val : row) {
            std::cout << val << " ";
        }
        std::cout << "\n";
    }
}


int main(int argc, char *argv[])
{
  std::cerr << 'l' << '\n';
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
  const uint64_t num_reps   = std::stoull(argv[18]);
  std::ofstream bitflip_file(argv[19]);

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
  start_simple_hammer(rows, all_vics, 1);

  auto all_combos = generate_combinations(num_acts, num_reps, n, k);

  /*************************************************************************************/

  for (int i = min_rowId; i < max_rowId; i += skip_step) {

    int bitflip_count = 0;

    std::cout << '\n';
    std::cout << CLI_PREFIX << "Chosen Critical Aggressor: " << i << std::endl;
    std::cout << CLI_PREFIX << "==========================================================" << std::endl;

    for (int j = 0; j < count_iter; j++) {

      /* Generate hammering patterns */
      auto aggressors = generate_pattern(gen, rows, all_combos, num_rows, num_acts, row_step, i);
      auto victims    = generate_victims(aggressors, num_rows, 4);
      auto positions  = compute_positions(aggressors);

      std::cout << CLI_PREFIX << "Chosen Victims: " << vector_str(victims) << std::endl;
      std::cout << CLI_PREFIX << "Chosen Aggressors: " << vector_str(aggressors) << std::endl;
      std::cout << CLI_PREFIX << "Aggressor Positions: " << vector_str(positions) << std::endl;
      std::cout << CLI_PREFIX << "Aggressor Iteration: " << j << std::endl;
      auto start_loop = std::chrono::high_resolution_clock::now();

      /* Sets the row and evict cache to store it in the memory. */
      set_rows(rows, victims, vic_pat, step);
      set_rows(rows, aggressors, agg_pat, step);
      cudaDeviceSynchronize();

      evict_L2cache(layout);
      cudaDeviceSynchronize();

      auto start_hammer = std::chrono::high_resolution_clock::now();

      /* Start the hammering and measure the time */
      uint64_t time = start_coalesce_hammer(rows, aggressors, positions, it, n, k, num_acts, delay, period);
      print_time(time);
      std::cout << CLI_PREFIX << "Average time per round: " << time / it << std::endl;

      auto end_hammer = std::chrono::high_resolution_clock::now();

      /* Verify result */
      evict_L2cache(layout);

      bool res = verify_all_content(rows, victims, aggressors, step, vic_pat);
      std::cout << CLI_PREFIX << "Bit-flip in victim rows: " 
                              << (res ? "Observed Bit-Flip" : "No Bit-Flip") << std::endl;
      if (res) bitflip_count ++;

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