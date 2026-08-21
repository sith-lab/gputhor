#include "./s1_allocallmem.cuh"
#include "./s2_firstRegion.cuh"
#include "./s3_firstRegion_hammer.cuh"
#include <iostream>
#include <chrono>

enum Task
{
  ALL_MEM_TEST,
  ALL_MEM,
  FIRST_REGION_TEST,
  FIRST_REGION,
  FIRST_REGION_ATK,
  SECOND_REGION,
  INVALID
};

static Task
parseTask (const std::string &tsk)
{
  if (tsk == "all_mem_test")
    return Task::ALL_MEM_TEST;
  if (tsk == "all_mem")
    return Task::ALL_MEM;
  if (tsk == "first_region_test")
    return Task::FIRST_REGION_TEST;
  if (tsk == "first_region")
    return Task::FIRST_REGION;
  if (tsk == "first_region_atk")
    return Task::FIRST_REGION_ATK;
  return Task::INVALID;
}

int
main (int argc, char *argv[])
{
  if (argc <= 2)
    {
      std::cout << "Not enough arguments.\n";
      return 0;
    }

  std::string cmd = argv[1];
  removeFirstNArgs (argc, argv, 2);
  switch (parseTask (cmd))
    {
    case Task::ALL_MEM_TEST:
      alloc_all_mem_test (argc, argv);
      break;
    case Task::ALL_MEM:
      alloc_all_mem (argc, argv);
      break;
    case Task::FIRST_REGION_TEST:
      first_PT_region_test (argc, argv);
      break;
    case Task::FIRST_REGION:
      first_PT_region (argc, argv);
      break;
    case Task::FIRST_REGION_ATK:
      first_PT_region_attack (argc, argv);
      break;
    case INVALID:
      std::cout << "Unkown Task.\n";
    }

  return 0;
}