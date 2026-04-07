#!/bin/bash
# generate data
python data_generate_for_varying_v0_repeat.py 100 50 3 3 # n, m, linspaceNumber,  repeatNumber
python data_generate_for_varying_a0_repeat.py 100 50 3 3 # n, m, linspaceNumber,  repeatNumber

# run for given data
python run_joint_benefit_luce_loss.py 10 "varying_v0"
python run_joint_benefit_luce_loss.py 10 "varying_a0"

# plot
python plot_joint_benefit_luce_loss.py "varying_v0"
python plot_joint_benefit_luce_loss.py "varying_a0"