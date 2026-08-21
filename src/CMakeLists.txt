cmake_minimum_required(VERSION 3.22 FATAL_ERROR)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CUDA_STANDARD 17)

set(CMAKE_CUDA_ARCHITECTURES 86)

project(GPURowhammer LANGUAGES CXX CUDA)
set(CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS} --generate-line-info -O3 -Xcicc -O0 -Xptxas -O3 -gencode=arch=compute_86,code=sm_86")

include_directories(include)
set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)

# Hammer
add_library(hammer_lib ./include/rh_kernels.cu ./include/rh_utils.cu ./include/rh_impls.cu)
target_link_libraries(hammer_lib PUBLIC Threads::Threads)

# Reverse Engineering
add_library(re_lib ./re_gddr/drama_conflict_prober.cu)
target_link_libraries(re_lib PUBLIC hammer_lib)

# Get Conflict Set
add_executable(conf_set ./re_gddr/conf_set_main.cu)
target_link_libraries(conf_set PUBLIC re_lib)

# Get Row Set
add_executable(row_set ./re_gddr/row_set_main.cu)
target_link_libraries(row_set PUBLIC re_lib)

# Get Bank Set
add_executable(bank_set ./re_gddr/bank_set_main.cu)
target_link_libraries(bank_set PUBLIC re_lib)

# Get Timing values
add_executable(gen_time ./re_gddr/gen_time_main.cu)
target_link_libraries(gen_time PUBLIC re_lib)

# Get Timing values
add_executable(gen_time_same ./re_gddr/gen_time_same_main.cu)
target_link_libraries(gen_time_same PUBLIC re_lib)

add_executable(load_modifiers ./re_gddr/load_modifiers_main.cu)
target_link_libraries(load_modifiers PUBLIC re_lib)

add_executable(gpu_hammer ./hammer/gpu_hammer.cu)
target_link_libraries(gpu_hammer PUBLIC hammer_lib)
target_link_libraries(gpu_hammer PRIVATE Threads::Threads)

add_executable(gputhor ./hammer/gputhor.cu)
target_link_libraries(gputhor PUBLIC hammer_lib)
target_link_libraries(gputhor PRIVATE Threads::Threads)

add_executable(gputhor_nonuniform ./hammer/gputhor_nonuniform.cu)
target_link_libraries(gputhor_nonuniform PUBLIC hammer_lib)
target_link_libraries(gputhor_nonuniform PRIVATE Threads::Threads)

add_executable(rep_hammer ./hammer/rep_hammer.cu)
target_link_libraries(rep_hammer PUBLIC hammer_lib)
target_link_libraries(rep_hammer PRIVATE Threads::Threads)

add_executable(extend_NtREFI ./hammer/fig6_extend_NtREFI.cu)
target_link_libraries(extend_NtREFI PUBLIC hammer_lib)
target_link_libraries(extend_NtREFI PRIVATE Threads::Threads)

add_executable(coalesce ./hammer/fig4_coalesce.cu)
target_link_libraries(coalesce PUBLIC hammer_lib)
target_link_libraries(coalesce PRIVATE Threads::Threads)

add_executable(intensity_analysis_NtREFI ./hammer/fig7_intensity_analysis_NtREFI.cu)
target_link_libraries(intensity_analysis_NtREFI PUBLIC hammer_lib)
target_link_libraries(intensity_analysis_NtREFI PRIVATE Threads::Threads)

add_executable(gputhor_ecc ./hammer/gputhor_ecc.cu)
target_link_libraries(gputhor_ecc PUBLIC hammer_lib)
target_link_libraries(gputhor_ecc PRIVATE Threads::Threads)
