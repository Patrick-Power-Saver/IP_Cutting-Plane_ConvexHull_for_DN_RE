#!/bin/bash
# varying v0 (the utility of the outside option for the online segments)
python data_generate_for_varying_v0.py 100 50 5 # generate data
python run_varying_a0_v0.py 10.0 "varying_v0"
python plot_assortment_map.py "varying_v0"

# varying a0 (\alpha0 the arrival ratio of the offline segment)
python data_generate_for_varying_a0.py 100 50 5 # generate data
python run_varying_a0_v0.py 10.0 "varying_a0"
python plot_assortment_map.py "varying_a0"

