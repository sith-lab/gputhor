#include <rh_kernels.cuh>
#include <rh_impls.cuh>
#include <rh_utils.cuh>
#include <memory>
#include <algorithm>
#include <unordered_map>


static uint8_t **get_aggressor_device_addr(RowList &rows,
                                           std::vector<uint64_t> &agg_vec);

static uint8_t **get_aggressor_device_addr(RowList &rows,
                                    std::vector<uint64_t> &agg_vec,
                                    std::vector<uint64_t> &pos_vec);

uint64_t start_simple_hammer(RowList &rows, std::vector<uint64_t> &agg_vec,
                             uint64_t it)
{
  /* GPU memory to store aggressors */
  uint8_t **agg_device_arr = get_aggressor_device_addr(rows, agg_vec);

  /* Start hammering */
  auto dim = get_dim_from_size(agg_vec.size());
  int numBlock = std::get<0>(dim);
  int numThreads = std::get<1>(dim);

  /* Setup time measures */
  uint64_t *timeSpentDevice;
  uint64_t timeSpentHost;
  cudaMalloc(&timeSpentDevice, sizeof(uint64_t *));

  std::cout << CLI_PREFIX << "Iterating: " << it << " times\n";

  simple_hammer_kernel<<<numBlock, numThreads>>>(agg_device_arr, it,
                                                 timeSpentDevice);
  cudaDeviceSynchronize();
  cudaMemcpy(&timeSpentHost, timeSpentDevice, sizeof(uint64_t *),
             cudaMemcpyDeviceToHost);

  cudaFree(agg_device_arr);
  return toNS(timeSpentHost);
}

uint64_t start_single_thread_hammer(RowList &rows, std::vector<uint64_t> &agg_vec,
                                  uint64_t it, uint64_t n, uint64_t k, uint64_t len, uint64_t delay, uint64_t period)
{
  /* GPU memory to store aggressors */
  uint8_t **agg_device_arr = get_aggressor_device_addr(rows, agg_vec);

  uint64_t *timeSpentDevice;
  uint64_t timeSpentHost;
  cudaMalloc(&timeSpentDevice, sizeof(uint64_t *));

  std::cout << CLI_PREFIX << "Iterating: " << it << " times\n";
  std::cout << CLI_PREFIX << "Delay: " << delay << "\n";

  single_thread_hammer_kernel<<<1, 1>>>(agg_device_arr, it, len, timeSpentDevice);
  cudaDeviceSynchronize();

  cudaMemcpy(&timeSpentHost, timeSpentDevice, sizeof(uint64_t *),
             cudaMemcpyDeviceToHost);
  cudaFree(agg_device_arr);
  cudaFree(timeSpentDevice);
  return toNS(timeSpentHost);
}

uint64_t start_multi_thread_hammer(RowList &rows, std::vector<uint64_t> &agg_vec,
                                  uint64_t it, uint64_t n, uint64_t k, uint64_t len, uint64_t delay, uint64_t period)
{
  /* GPU memory to store aggressors */
  uint8_t **agg_device_arr = get_aggressor_device_addr(rows, agg_vec);

  uint64_t *timeSpentDevice;
  uint64_t timeSpentHost;
  cudaMalloc(&timeSpentDevice, sizeof(uint64_t *));

  std::cout << CLI_PREFIX << "Iterating: " << it << " times\n";
  std::cout << CLI_PREFIX << "Delay: " << delay << "\n";

  sync_hammer_kernel<<<1, len>>>(agg_device_arr, it, delay, period, timeSpentDevice);
  cudaDeviceSynchronize();

  cudaMemcpy(&timeSpentHost, timeSpentDevice, sizeof(uint64_t *),
             cudaMemcpyDeviceToHost);
  cudaFree(agg_device_arr);
  cudaFree(timeSpentDevice);
  return toNS(timeSpentHost);
}

uint64_t start_multi_warp_hammer(RowList &rows, std::vector<uint64_t> &agg_vec,
                                  uint64_t it, uint64_t n, uint64_t k, uint64_t len, uint64_t delay, uint64_t period)
{
  /* GPU memory to store aggressors */
  uint8_t **agg_device_arr = get_aggressor_device_addr(rows, agg_vec);

  uint64_t *timeSpentDevice;
  uint64_t timeSpentHost;
  cudaMalloc(&timeSpentDevice, sizeof(uint64_t *));

  std::cout << CLI_PREFIX << "Iterating: " << it << " times\n";
  std::cout << CLI_PREFIX << "Delay: " << delay << "\n";

  warp_simple_hammer_kernel<<<1, 1024>>>(agg_device_arr, it, n, k, len, delay, period, timeSpentDevice);

  cudaDeviceSynchronize();

  cudaMemcpy(&timeSpentHost, timeSpentDevice, sizeof(uint64_t *),
             cudaMemcpyDeviceToHost);
  cudaFree(agg_device_arr);
  cudaFree(timeSpentDevice);
  return toNS(timeSpentHost);
}

uint64_t gputhor_hammer(RowList &rows, std::vector<uint64_t> &agg_vec,
                                  uint64_t it, uint64_t n, uint64_t k, uint64_t len, uint64_t delay, uint64_t period, int trefi)
{
  /* GPU memory to store aggressors */
  uint8_t **agg_device_arr = get_aggressor_device_addr(rows, agg_vec);

  uint64_t *timeSpentDevice;
  uint64_t timeSpentHost;
  cudaMalloc(&timeSpentDevice, sizeof(uint64_t *));

  std::cout << CLI_PREFIX << "Iterating: " << it << " times\n";
  std::cout << CLI_PREFIX << "Delay: " << delay << "\n";

  gputhor_hammer<<<1, 1024>>>(agg_device_arr, it, n, k, len, delay, period, trefi, timeSpentDevice);

  cudaDeviceSynchronize();

  cudaMemcpy(&timeSpentHost, timeSpentDevice, sizeof(uint64_t *),
             cudaMemcpyDeviceToHost);
  cudaFree(agg_device_arr);
  cudaFree(timeSpentDevice);
  return toNS(timeSpentHost);
}


uint64_t gputhor_nonuniform_hammer(RowList &rows, std::vector<uint64_t> &agg_vec,
                              uint64_t it, uint64_t n, uint64_t k, uint64_t len, 
                              uint64_t delay, uint64_t period, int trefi)
{
  /* GPU memory to store aggressors */
  uint8_t **agg_device_arr = get_aggressor_device_addr(rows, agg_vec);

  uint64_t *timeSpentDevice;
  uint64_t timeSpentHost;
  cudaMalloc(&timeSpentDevice, sizeof(uint64_t *));

  std::cout << CLI_PREFIX << "Iterating: " << it << " times\n";
  std::cout << CLI_PREFIX << "Delay: " << delay << "\n";

  gputhor_nonuniform_kernel<<<1, 1024>>>(agg_device_arr, it, n, k, len, delay, 
                                    period, trefi, timeSpentDevice);

  cudaDeviceSynchronize();

  cudaMemcpy(&timeSpentHost, timeSpentDevice, sizeof(uint64_t *),
             cudaMemcpyDeviceToHost);
  cudaFree(agg_device_arr);
  cudaFree(timeSpentDevice);
  return toNS(timeSpentHost);
}

uint64_t start_coalesce_hammer(RowList &rows, std::vector<uint64_t> &agg_vec, std::vector<uint64_t> &pos_vec,
                                uint64_t it, uint64_t n, uint64_t k, uint64_t len, uint64_t delay, uint64_t period)
{
  /* GPU memory to store aggressors */
  uint8_t **agg_device_arr = get_aggressor_device_addr(rows, agg_vec, pos_vec);

  uint64_t *timeSpentDevice;
  uint64_t timeSpentHost;
  cudaMalloc(&timeSpentDevice, sizeof(uint64_t *));

  std::cout << CLI_PREFIX << "Iterating: " << it << " times\n";
  std::cout << CLI_PREFIX << "Delay: " << delay << "\n";

  warp_simple_hammer_kernel<<<1, 1024>>>(agg_device_arr, it, n, k, len, delay, period, timeSpentDevice);

  cudaDeviceSynchronize();

  cudaMemcpy(&timeSpentHost, timeSpentDevice, sizeof(uint64_t *),
             cudaMemcpyDeviceToHost);
  cudaFree(agg_device_arr);
  cudaFree(timeSpentDevice);
  return toNS(timeSpentHost);
}


uint64_t start_trh_hammer(RowList &rows, std::vector<uint64_t> &agg_vec,
                          std::vector<uint64_t> &dum_vec,
                          uint64_t it, uint64_t n, uint64_t k, uint64_t len, 
                          uint64_t delay, uint64_t period,
                          uint64_t agg_period, uint64_t dum_period)
{
  /* GPU memory to store aggressors */
  uint8_t **agg_device_arr = get_aggressor_device_addr(rows, agg_vec);
  uint8_t **dum_device_arr = get_aggressor_device_addr(rows, dum_vec);

  uint64_t *timeSpentDevice;
  uint64_t timeSpentHost;
  cudaMalloc(&timeSpentDevice, sizeof(uint64_t *));

  std::cout << CLI_PREFIX << "Iterating: " << it << " times\n";
  std::cout << CLI_PREFIX << "Delay: " << delay << "\n";

  rh_threshold_kernel<<<1, 1024>>>(agg_device_arr, dum_device_arr, it, n, k, len, 
                                    delay, period, timeSpentDevice, 
                                    agg_period, dum_period);
  cudaDeviceSynchronize();

  cudaMemcpy(&timeSpentHost, timeSpentDevice, sizeof(uint64_t *),
             cudaMemcpyDeviceToHost);
  cudaFree(agg_device_arr);
  cudaFree(dum_device_arr);
  cudaFree(timeSpentDevice);
  return toNS(timeSpentHost);
}


uint8_t **get_aggressor_device_addr(RowList &rows,
                                    std::vector<uint64_t> &agg_vec)
{
  uint8_t **agg_device_arr;
  cudaMalloc(&agg_device_arr, sizeof(uint8_t *) * agg_vec.size());

  auto agg_host_arr = std::make_unique<uint8_t *[]>(agg_vec.size());

  std::unordered_map<uint64_t, size_t> repeat_count;

  for (size_t i = 0; i < agg_vec.size(); i++) {
    uint64_t row = agg_vec[i];

    // how many times we've seen this row so far
    size_t j = repeat_count[row]++;
    size_t increment = j % 2 ? 128 : 0;

    // take rows[row][j]
    agg_host_arr[i] = rows[row][(j/2) % rows[row].size()] + increment;
  }

  cudaMemcpy(agg_device_arr,
             agg_host_arr.get(),
             sizeof(uint8_t *) * agg_vec.size(),
             cudaMemcpyHostToDevice);

  return agg_device_arr;
}

/**
 * @param rows
 * @param agg_vec which rows to hammer
 * @param pos_vec positions of the aggressors in the rows
 */
uint8_t **get_aggressor_device_addr(RowList &rows,
                                    std::vector<uint64_t> &agg_vec,
                                    std::vector<uint64_t> &pos_vec)
{
  uint8_t **agg_device_arr;
  cudaMalloc(&agg_device_arr, sizeof(uint8_t *) * agg_vec.size());

  /* Copy aggressors to GPU Memory */
  auto agg_host_arr = std::make_unique<uint8_t *[]>(agg_vec.size());  
  for (auto i = 0; i < agg_vec.size(); i++)
    agg_host_arr[i] = rows[agg_vec[i]][pos_vec[i]];

  cudaMemcpy(agg_device_arr, agg_host_arr.get(),
             sizeof(uint8_t *) * agg_vec.size(), cudaMemcpyHostToDevice);

  return agg_device_arr;
}