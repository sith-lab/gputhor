#!/usr/bin/env python3

import argparse
import subprocess
import os

BREACH_ROOT = os.getenv("BREACH_ROOT")
if BREACH_ROOT is None:
    print("BREACH_ROOT not set")
    exit(1)

def arg_2_setup(subparsers, func):
    parser = subparsers.add_parser(
        "all_mem_test",
        help="Step 1 Testing: Should output n_step1 for furthur steps"
    )
    parser.add_argument(
        "-t", "--threshold",
        type=float,
        help="Timing side-channel threshold that is considered as an eviction.",
        required=True,
    )
    parser.add_argument(
        "-s", "--skip",
        type=int,
        help="Skip a specified amount of measurements, as the first few can be slow from GPU warmup.",
        required=True,
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Print out debug information like timing or relevant addresses"
    )
    parser.add_argument(
        "-c", "--config",
        type=str,
        help="Path to bit-flip config file",
        required=True,
    )
    parser.set_defaults(func=func)


def arg_3_setup(subparsers, name, help, func):
    parser = subparsers.add_parser(
        name,
        help=help
    )
    parser.add_argument(
        "--n_step1",
        type=int,
        help="Numer of 2MB allocations in step 1 that will fill the GPU memory to full.",
        required=True,
    )
    parser.add_argument(
        "-t", "--threshold",
        type=float,
        help="Timing side-channel threshold that is considered as an eviction.",
        required=True,
    )
    parser.add_argument(
        "-s", "--skip",
        type=int,
        help="Skip a specified amount of measurements, as the first few can be slow from GPU warmup.",
        required=True,
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Print out debug information like timing or relevant addresses"
    )
    parser.add_argument(
        "-c", "--config",
        type=str,
        help="Path to bit-flip config file",
        required=True,
    )
    parser.set_defaults(func=func)


def arg_4_setup(subparsers, name, help, func):
    parser = subparsers.add_parser(
        name,
        help=help,
    )
    parser.add_argument(
        "--n_step1",
        type=int,
        help="Numer of 2MB allocations in step 1 that will fill the GPU memory to full.",
        required=True,
    )
    parser.add_argument(
        "-t", "--threshold",
        type=float,
        help="Timing side-channel threshold that is considered as an eviction.",
        required=True,
    )
    parser.add_argument(
        "-s", "--skip",
        type=int,
        help="Skip a specified amount of measurements, as the first few can be slow from GPU warmup.",
        required=True,
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Print out debug information like timing or relevant addresses"
    )
    parser.add_argument(
        "-c", "--config",
        type=str,
        help="Path to bit-flip config file",
        required=True,
    )
    parser.set_defaults(func=func)



def arg_5_setup(subparsers, name, help, func):
    parser = subparsers.add_parser(
        name,
        help=help,
    )
    parser.add_argument(
        "--n_step1",
        type=int,
        help="Numer of 2MB allocations in step 1 that will fill the GPU memory to full.",
        required=True,
    )
    parser.add_argument(
        "-t", "--threshold",
        type=float,
        help="Timing side-channel threshold that is considered as an eviction.",
        required=True,
    )
    parser.add_argument(
        "-s", "--skip",
        type=int,
        help="Skip a specified amount of measurements, as the first few can be slow from GPU warmup.",
        required=True,
    )
    parser.add_argument(
        "-a", "--app_cmd",
        type=str,
        help="Command to execute the attacker code.",
        required=True,
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Print out debug information like timing or relevant addresses"
    )
    parser.add_argument(
        "-c", "--config",
        type=str,
        help="Path to bit-flip config file",
        required=True,
    )
    parser.set_defaults(func=func)


def run_command(command):
    print("Running: " + command)
    p = subprocess.Popen(command, shell=True)
    p.wait()


def all_mem_test(args):
   run_command(f"BREACH_DEBUG={1 if args.verbose else 0} {BREACH_ROOT}/src/out/gpubreach_main {args.command} {args.threshold} {args.skip} {args.config}")


def arg3_tasks(args):
    run_command(f"BREACH_DEBUG={1 if args.verbose else 0} {BREACH_ROOT}/src/out/gpubreach_main {args.command} {args.n_step1} {args.threshold} {args.skip} {args.config}")


def arg4_tasks_app(args):
    run_command(f"BREACH_DEBUG={1 if args.verbose else 0} {BREACH_ROOT}/src/out/{args.command} {args.n_step1} {args.threshold} {args.skip} {args.config}")


def arg5_tasks_app(args):
    run_command(f"BREACH_DEBUG={1 if args.verbose else 0} {BREACH_ROOT}/src/out/{args.command} {args.n_step1} {args.threshold} {args.skip} {args.config} '{args.app_cmd}' ")


def main():
    parser = argparse.ArgumentParser(
        description="GPUBreach CLI tool"
    )

    subparsers = parser.add_subparsers(
        dest="command",
        required=True,
        help="Available tasks"
    )

    # -------- Task 1 --------
    arg_2_setup(subparsers, all_mem_test)
    task_tuple = [
        ("all_mem", "Step 1: Fill GPU memory to full with n_step1 2MB allocations"),
        ("first_region_test", "Step 2 Testing: Should output timing for 2MB+4KB page allocations, used to verify whether the side-channel is working"),
        ("first_region", "Step 2: Massage a PT region into the specified bit-flip page."),
        ("first_region_atk_mem_test", "Step 3 Testing: Should output n_step3 for furthur steps."),
        ("first_region_atk", "Step 3: Attempts to corrupt PTEs in the massaged PT region"),
        ("second_region", "Step 4: Massage another PT region into the corrupted location."),
    ]
    for name, help in task_tuple:
        arg_3_setup(subparsers, name, help, arg3_tasks)

    task_tuple = [
        ("app_cpu_exploit", "Modify the CPU exploit's virtual-to-physical mapping"),
        ("app_demo", "Demo using GPUBreach, dumping and changing other process' memory."),
    ]
    for name, help in task_tuple:
        arg_4_setup(subparsers, name, help, arg4_tasks_app)
    
    arg_5_setup(subparsers, "app_transfer", "Provide another process arbitrary RW primitives.", arg5_tasks_app)
    args = parser.parse_args()

    # Dispatch to the selected task
    args.func(args)


if __name__ == "__main__":
    main()