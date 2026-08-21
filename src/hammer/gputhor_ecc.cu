

#include <rh_impls.cuh>
#include <rh_utils.cuh>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <fstream>
#include <functional>
#include <iostream>
#include <numeric>
#include <pthread.h>
#include <random>
#include <set>
#include <stdint.h>
#include <unordered_map>
#include <vector>

std::string CLI_PREFIX = "(gpu-thor-ecc): ";

/* Parameters shared across every hammering phase. Parsed once from the CLI in
   main() and passed by const reference so the phase helpers stay small. */
struct HammerConfig
{
  uint64_t it;
  uint64_t n;
  uint64_t k;
  uint64_t delay;
  uint64_t period;
  uint64_t step;
  uint64_t vic_pat;
  uint64_t agg_pat;
  uint64_t trefi;
  uint64_t count_iter;
};

std::vector<uint64_t>
generate_victims (std::vector<uint64_t> aggressors, uint64_t num_rows,
                  uint64_t radius)
{
  std::set<uint64_t> victim_set;
  for (auto a : aggressors)
    {
      for (uint64_t victim = a - radius; victim <= a + radius; victim++)
        {
          if (victim >= num_rows)
            continue;
          victim_set.insert (victim);
        }
    }

  std::vector<uint64_t> victims (victim_set.begin (), victim_set.end ());
  return victims;
}

/* Build the aggressor access pattern used for a given critical aggressor. The
   pattern is a fixed, evenly strided set of rows with a subset of slots pinned
   to the chosen target row. */
static std::vector<uint64_t>
build_aggressor_pattern (uint64_t target)
{
  /*********** Generate our own aggressor pattern ***********/
  std::vector<uint64_t> aggressors;
  aggressors.push_back (32 + 8);

  for (int z = 1; z < 24 * 2; z++)
    aggressors.push_back (aggressors.back () + 8);

  /*********** Manually placed the Aggressors ***********/

  for (int z = 0; z < 24; z += 3)
    aggressors[z] = target;
  /*************************************************************************************/

  return aggressors;
}

/* Run `count` hammer rounds against `aggressors`, timing each round. On the
   final round the L2 cache is evicted and `verify` is invoked to report and
   record any observed bit flips, followed by a per-round timing breakdown.
   Returns the number of rounds in which a bit flip was observed. */
static int
hammer_and_verify_loop (RowList &rows, std::vector<uint64_t> &aggressors,
                        uint64_t count, const HammerConfig &cfg, int num_trefi,
                        uint8_t *layout, const std::function<bool ()> &verify)
{
  int bitflip_count = 0;
  for (int j = 0; j < count; j++)
    {
      std::cout << CLI_PREFIX << "Aggressor Iteration: " << j << std::endl;
      auto start_loop = std::chrono::high_resolution_clock::now ();

      auto start_hammer = std::chrono::high_resolution_clock::now ();

      /* Start the hammering and measure the time */
      uint64_t time = gputhor_hammer (rows, aggressors, cfg.it, cfg.n, cfg.k,
                                      aggressors.size () / 2, cfg.delay,
                                      cfg.period, num_trefi);

      auto end_hammer = std::chrono::high_resolution_clock::now ();

      if (j == count - 1)
        {
          print_time (time);
          std::cout << CLI_PREFIX
                    << "Average time per round: " << time / cfg.it << std::endl;
          /* Verify result */
          evict_L2cache (layout);
          bool res = false;

          res = verify ();
          std::cout << CLI_PREFIX << "Bit-flip in victim rows: "
                    << (res ? "Observed Bit-Flip" : "No Bit-Flip")
                    << std::endl;
          if (res)
            bitflip_count++;
        }
      /* Clean up and prepare for next launch*/
      cudaDeviceSynchronize ();
      auto end_loop = std::chrono::high_resolution_clock::now ();

      std::chrono::duration<double, std::milli> duration_evict
          = start_hammer - start_loop;
      std::chrono::duration<double, std::milli> duration_hammer
          = end_hammer - start_hammer;
      std::chrono::duration<double, std::milli> duration_verify
          = end_loop - end_hammer;
      std::chrono::duration<double, std::milli> duration_total
          = end_loop - start_loop;
      if (j == count - 1)
        {
          std::cout << CLI_PREFIX
                    << "Evict time: " << duration_evict.count () << " ms"
                    << std::endl;
          std::cout << CLI_PREFIX
                    << "Hammer time: " << duration_hammer.count () << " ms"
                    << std::endl;
          std::cout << CLI_PREFIX
                    << "Verify time: " << duration_verify.count () << " ms"
                    << std::endl;
          std::cout << CLI_PREFIX
                    << "Total time: " << duration_total.count () << " ms"
                    << std::endl;

          std::cout
              << CLI_PREFIX
              << "=================================================="
                 "========"
              << std::endl;
        }
    }
  return bitflip_count;
}

/* 1->0 flip guard. Before committing to BIT_SEARCH, re-hammer the freshly
   discovered victim row with an all-ones pattern. If a 1->0 flip appears we
   back out of BIT_SEARCH to avoid accidental double flips during bit search. */
static void
run_one_to_zero_flip_phase (RowList &rows, std::vector<uint64_t> &aggressors,
                            uint8_t *layout, const HammerConfig &cfg,
                            STATE_OBJECT &state_object)
{
  std::vector<uint64_t> target_victim{ state_object.flipped_victim_row_id };
  std::cout << CLI_PREFIX << "1->0 Flip Phase: Testing victim row "
            << state_object.flipped_victim_row_id << " with 0xFF pattern"
            << std::endl;
  set_rows (rows, target_victim, 0xFF, cfg.step);
  set_rows (rows, aggressors, 0xFF, cfg.step);
  cudaDeviceSynchronize ();
  evict_L2cache (layout);
  cudaDeviceSynchronize ();

  bool one_to_zero_flip = false;
  for (int j = 0; j < 100; j++)
    {
      uint64_t time = gputhor_hammer (rows, aggressors, cfg.it, cfg.n, cfg.k,
                                      aggressors.size () / 2, cfg.delay,
                                      cfg.period, cfg.trefi);

      if (j == 100 - 1)
        {
          print_time (time);
          evict_L2cache (layout);
          STATE_OBJECT one_to_zero_state;
          one_to_zero_state.state = SEARCH_STATE::SEGMENT_ROW_SEARCH;
          verify_all_content (rows, target_victim, aggressors, cfg.step, 0xFF,
                              &one_to_zero_state);
          one_to_zero_flip
              = (one_to_zero_state.state == SEARCH_STATE::BIT_SEARCH);
          std::cout << CLI_PREFIX << "1->0 Flip Phase: "
                    << (one_to_zero_flip
                            ? "Found 1->0 flip, skipping BIT_SEARCH"
                            : "No 1->0 flip, proceeding to BIT_SEARCH")
                    << std::endl;
        }
      cudaDeviceSynchronize ();
    }

  if (one_to_zero_flip)
    {
      state_object.flipped_victim_row_id = 0;
      state_object.state = SEARCH_STATE::SEGMENT_ROW_SEARCH;
    }
}

/* SEGMENT_ROW_SEARCH phase. Sweep the refresh intervals looking for the first
   victim row that flips. Once a flip promotes the search to BIT_SEARCH, run the
   1->0 flip guard before returning. */
static void
run_segment_row_search (RowList &rows, std::vector<uint64_t> &victims,
                        std::vector<uint64_t> &aggressors, uint8_t *layout,
                        const HammerConfig &cfg, STATE_OBJECT &state_object,
                        int &bitflip_count)
{
  for (int num_trefi = 2; num_trefi < cfg.trefi + 1; num_trefi++)
    {
      std::cout << CLI_PREFIX << "Chosen Victims: " << vector_str (victims)
                << std::endl;
      std::cout << CLI_PREFIX
                << "Chosen Aggressors: " << vector_str (aggressors)
                << std::endl;

      bitflip_count += hammer_and_verify_loop (
          rows, aggressors, cfg.count_iter, cfg, num_trefi, layout, [&] () {
            return verify_all_content (rows, victims, aggressors, cfg.step,
                                       cfg.vic_pat, &state_object);
          });

      if (state_object.state == SEARCH_STATE::BIT_SEARCH)
        break;
    }

  /* 1->0 flip phase: before entering BIT_SEARCH, verify that the
     vulnerable row does not exhibit 1->0 flips. If it does, skip
     BIT_SEARCH to avoid accidental double flips during bit search. */
  if (state_object.state == SEARCH_STATE::BIT_SEARCH)
    run_one_to_zero_flip_phase (rows, aggressors, layout, cfg, state_object);
}

/* BIT_SEARCH phase. For the recorded victim row, sweep all 256 bit positions,
   hammering each and recording the exact bits that flip. Stops early once three
   flips are found, then persists the results and resets state for the next
   critical aggressor. */
static void
run_bit_search (RowList &rows, std::vector<uint64_t> &aggressors,
                uint8_t *layout, const HammerConfig &cfg,
                STATE_OBJECT &state_object, std::ofstream &bitflip_file,
                int &bitflip_count)
{
  // Loop through All bit positions
  // Switch to 32B searching when found a position
  std::vector<uint64_t> target_victim{ state_object.flipped_victim_row_id };
  for (int bit = 0; bit < 256; bit++)
    {
      std::cout << CLI_PREFIX << "Searching Bit " << bit << std::endl;
      set_rows_with_bit (rows, target_victim, bit, cfg.step);
      set_rows (rows, aggressors, cfg.agg_pat, cfg.step);
      cudaDeviceSynchronize ();
      evict_L2cache (layout);
      cudaDeviceSynchronize ();

      // Statistically we should see flips after 20 attempts in 6
      // TREFI.
      std::cout << CLI_PREFIX
                << "Target Victim: " << vector_str (target_victim) << std::endl;
      std::cout << CLI_PREFIX
                << "Chosen Aggressors: " << vector_str (aggressors)
                << std::endl;

      bitflip_count += hammer_and_verify_loop (
          rows, aggressors, 20, cfg, cfg.trefi, layout, [&] () {
            return verify_all_content_bit_search (rows, target_victim,
                                                  aggressors, cfg.step, bit,
                                                  &state_object);
          });

      // Stop the bit sweep once we have found 3 bit flips in this
      // target victim.
      if (state_object.victim_flip_count >= 3)
        {
          std::cout << CLI_PREFIX << "Found " << state_object.victim_flip_count
                    << " bit flips in target victim, ending bit "
                       "search early"
                    << std::endl;
          break;
        }
    }
  for (const auto &flip : state_object.flips_in_victim)
    {
      bitflip_file << flip << "\n";
    }
  bitflip_file.flush ();
  state_object.flipped_bit_positions.clear ();
  state_object.flipped_victim_row_id = 0;
  state_object.flips_in_victim.clear ();
  state_object.victim_flip_count = 0;
  state_object.state = SEARCH_STATE::SEGMENT_ROW_SEARCH;
}

int
main (int argc, char *argv[])
{
  const uint64_t num_acts = std::stoull (argv[2]);
  const uint64_t step = std::stoull (argv[3]);
  const uint64_t it = std::stoull (argv[4]);
  const uint64_t min_rowId = std::stoull (argv[5]);
  const uint64_t max_rowId = std::stoull (argv[6]);
  const uint64_t row_step = std::stoull (argv[7]);
  const uint64_t skip_step = std::stoull (argv[8]);
  const uint64_t size = std::stoull (argv[9]);
  const uint64_t n = std::stoull (argv[10]);
  const uint64_t k = std::stoull (argv[11]);
  const uint64_t delay = std::stoull (argv[12]);
  const uint64_t period = std::stoull (argv[13]);
  const uint64_t count_iter = std::stoull (argv[14]);
  const uint64_t num_rows = std::stoull (argv[15]);
  const uint64_t vic_pat = std::stoull (argv[16], nullptr, 16);
  const uint64_t agg_pat = std::stoull (argv[17], nullptr, 16);
  const uint64_t trefi = std::stoull (argv[18]);
  std::ofstream bitflip_file (argv[19]);

  const HammerConfig cfg{ it,   n,       k,       delay, period,
                          step, vic_pat, agg_pat, trefi, count_iter };

  std::random_device rd;
  std::mt19937 gen (rd ());

  /* Read the row set */
  uint8_t *layout;
  cudaMalloc (&layout, size);

  std::ifstream row_set_file (argv[1]);
  RowList rows = read_row_from_file (row_set_file, layout);
  row_set_file.close ();

  std::cout << CLI_PREFIX << "Layout address: " << static_cast<void *> (layout)
            << '\n';
  std::cout << std::hex;
  std::cout << CLI_PREFIX << "Victim pattern: " << vic_pat << '\n';
  std::cout << CLI_PREFIX << "Aggressor pattern: " << agg_pat << '\n';
  std::cout << std::dec;

  /* Initialize all rows */
  std::vector<uint64_t> all_vics (num_rows);
  std::iota (all_vics.begin (), all_vics.end (), 0);
  set_rows (rows, all_vics, vic_pat, step);
  cudaDeviceSynchronize ();

  // Handle 2 bit errors.
  //  State 1: Search for segment
  // State 2: Only look at a single row's segment, search in 32B sectors
  // State 3: If both in 32B, search every bit by masking.

  STATE_OBJECT state_object;
  state_object.state = SEARCH_STATE::SEGMENT_ROW_SEARCH;
  int i = min_rowId;
  while (i < max_rowId)
    {
      int bitflip_count = 0;

      std::cout << '\n';
      std::cout << CLI_PREFIX << "Chosen Critical Aggressor: " << i
                << std::endl;
      std::cout << CLI_PREFIX
                << "=========================================================="
                << std::endl;

      std::vector<uint64_t> aggressors
          = get_aggressors (rows, i, num_acts, row_step);

      auto target = aggressors[0];
      std::vector<uint64_t> victims
          = generate_victims ({ target }, num_rows, 16);

      aggressors = build_aggressor_pattern (target);

      set_rows (rows, victims, vic_pat, step);
      set_rows (rows, aggressors, agg_pat, step);
      cudaDeviceSynchronize ();
      evict_L2cache (layout);
      cudaDeviceSynchronize ();

      // ROW_SEARCH looks for bit flips in a particular row.
      // When found, record in state_object and move on to deeper searches.
      // BIT_SEARCH: Search bit-by-bit with highest intensity,
      //   by masking across all 32B segments in the found Row and look in
      //   parallel. On each bit position located (may have multiple in the
      //   same), simply search which 32B segment was it. Then continue until
      //   all 256 bit position is searched.
      switch (state_object.state)
        {
        case SEARCH_STATE::SEGMENT_ROW_SEARCH:
          run_segment_row_search (rows, victims, aggressors, layout, cfg,
                                  state_object, bitflip_count);
          break;
        case SEARCH_STATE::BIT_SEARCH:
          run_bit_search (rows, aggressors, layout, cfg, state_object,
                          bitflip_file, bitflip_count);
          break;
        default:
          break;
        }

      switch (state_object.state)
        {
        case SEARCH_STATE::SEGMENT_ROW_SEARCH:
          i += skip_step;
          break;
        case SEARCH_STATE::BIT_SEARCH:
        default:
          break;
        }
    }
  bitflip_file.close ();
  cudaFree (layout);
  return 0;
}
