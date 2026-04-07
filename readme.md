# An Integer Programming Approach for Quick-Commerce Assortment Planning

This repository contains the code and data to reproduce the results in our paper, **An Integer Programming Approach for Quick-Commerce Assortment Planning**.
The online manuscript is available on [arXiv](https://arxiv.org/pdf/2405.02553).

---

## Installation

### Create the Python Environment
```bash
conda create --name myenv python=3.11
```
This project was developed and tested **using Python 3.11**, which serves as the reference environment. Newer versions have not been fully tested and may introduce unexpected issues. For best results, use Python 3.11. 

To remove this Python environment:
```bash
conda remove --name myenv --all
```

### Activate the Python Environment
```bash
conda activate myenv
```

### Install Required Packages
```bash
pip install -r requirements.txt
```
The [`requirements.txt`](https://github.com/YLW2018/IP_Assortment_CODE/blob/ac6d2f4a04d9c7072e69310ceda234d3fb98372c/requirements.txt) file is located in the project root folder.

**Note:** Before proceeding, you must obtain a license for the commercial solver [Gurobi](https://www.gurobi.com/).

---

## How to Run

### Dataset

I have prepared the dataset used in Table 2 of Section 6 (Computational Experiments). You can find it in `./DataSet/` or [download the dataset](https://github.com/YLW2018/IP_Assortment_CODE/tree/502b5c428f1c9fe71b555bbd6c9f09a4a62496b8/DataSet). The dataset file is over 200 MB in size. Due to GitHub's size limit, if you encounter download issues, please contact the author via email.

After downloading and unpacking the dataset file, place the `.pkl` file into the `./DataSet/` folder. (See [data structure introduction](data_structure_intro.md) for more details.)

Alternatively, you can generate the dataset randomly using:
```bash
python data_generate.py 36  # repeatNum
```
This will generate the dataset and save it to `./DataSet/`. The parameter `36` represents the number of repetitions.

---
### Run and Test

#### Computational Results (Table 2)

Run `run_plain_repeat.py` to replicate Table 2. This script will:
- Load the instance data
- Create a folder named `output_plain_repeat`
- Run the instances
- Save solution details as `SolutionDict_InfoDict_dataOptionDict_repeat_<timestamp>_<r>.pkl` (where `timestamp` has the format `yyyy-mm-dd-hh-mm-ss` and `r` is the repeat number)
- Save a table named `Tables_ReportTable1_<timestamp>_<r>.xlsx` containing detailed results for each repeat
- Save a table named `Tables_ReportTable1_<timestamp>_runtime_stat_<r>.xlsx` containing runtime statistics across all `r` repeats
- Save a table named `Tables_ReportTable1_<timestamp>_agg<r>.xlsx` containing aggregated results across `r` repeats

Usage:
```bash
python run_plain_repeat.py 100 2 12  # timelimit, K, repeatNum
```

**Note:** This will take more than 240 hours if testing on instances with the same size and repetition count as Table 2.

#### Time Performance Profile

Run `plot_perf_profile.py` to plot the performance profile figure:
- You should indicate the `filepath` to the folder containing the solution files (`.pkl` files)
- The performance profile figure will be saved in the `Output` folder

```bash
python plot_perf_profile.py
```

---

## Managerial Insights

See **EC.4** for details.

### Assortment Map (EC.4.1)

Run `varying_v0_a0.bash` in the terminal to plot and save the assortment map figures as shown in **EC.4.1**:

```bash
#!/bin/bash
# varying_v0_a0.bash

# Varying v0 (the utility of the outside option for the online segments)
python data_generate_for_varying_v0.py 100 50 5  # generate the required dataset
python run_varying_a0_v0.py 10.0 "varying_v0"
python plot_assortment_map.py "varying_v0"

# Varying a0 (α₀, the arrival ratio of the offline segment)
python data_generate_for_varying_a0.py 100 50 5  # generate the required dataset
python run_varying_a0_v0.py 10.0 "varying_a0"
python plot_assortment_map.py "varying_a0"
```

### Benefit of Joint Optimization (EC.4.2) and Revenue Loss of Model Mis-Specification (EC.4.3)

Since both **EC.4.2** and **EC.4.3** involve varying the arrival ratio (α₀) and the non-purchase utility (u₀), they are combined here.

Run `joint_benefit_luce_loss.bash` in the terminal to plot and save the box charts shown in **EC.4.2** and **EC.4.3**:

```bash
#!/bin/bash
# joint_benefit_luce_loss.bash

# Generate data
python data_generate_for_varying_v0_repeat.py 100 50 5 3  # n, m, linspaceNumber, repeatNumber
python data_generate_for_varying_a0_repeat.py 100 50 5 3  # n, m, linspaceNumber, repeatNumber

# Run for given data
python run_joint_benefit_luce_loss.py 10 "varying_v0"
python run_joint_benefit_luce_loss.py 10 "varying_a0"

# Plot
python plot_joint_benefit_luce_loss.py "varying_v0"
python plot_joint_benefit_luce_loss.py "varying_a0"
```

**Note:** This will take more than 100 hours if testing on instances with the same size and repetition count as **EC.4.2** and **EC.4.3**.

---

## Impact of Different K (Number of Cutting-Plane Generation Rounds)

What is the influence of different K values in **Algorithm 2** (where K is the number of cutting-plane generation rounds)?

See main results and discussion in **EC.5.1**.

- `run_different_K.py`: Implements different K values when calling **Algorithm 2**. Results (`.pkl` files) will be saved in subfolders of `output_different_K/<timestamp>_compare_different_K` for each K value.
- `plot_objChangewithK.py`: Generates the figure in **EC.5.1.1** showing the impact of different K values on the *reduced gap*. Figures with filenames starting with `gapReducedChangewithK_` are saved in the `Output` folder.
- `plot_timeChangewithK.py`: Generates the figure in **EC.5.1.2** showing the impact of different K values on computational performance. Figures with filenames starting with `timeChangewithK_` are saved in the `Output` folder.

```bash
#!/bin/bash
# different_K.bash

python run_different_K.py 100  # timelimit (seconds), you can set it as 3600
python plot_objChangewithK.py
python plot_timeChangewithK.py
```

**Note:** This will take more than 100 hours if testing on instances with the same size and repetition count as **EC.5.1**.

---

## Callback Implementation via Gurobi

Run `run_callback.py` to implement the callback via Gurobi. See details in **EC.5.2**.

This will generate the table reported in **EC.5.2**. The table is saved in a subfolder with a filename ending in `_callback.xlsx`.

```bash
python run_callback.py
```

**Note:** This will take more than 100 hours if testing on instances with the same size and repetition count as the table in **EC.5.2**.

---

## Joint Assortment and Personalization Problem

See **EC.5.3** and the [joint assortment and personalization problem (El Housni and Topaloglu 2023)](https://pubsonline.informs.org/doi/full/10.1287/opre.2022.2384).

- `data_generation_for_CAP.py`: Generates data according to **EC.5.3**. The data (`.pkl` file) will be saved to the dataset folder.
- `run_compare_with_customization.py`: Tests the [joint assortment and personalization problem (El Housni and Topaloglu 2023)](https://pubsonline.informs.org/doi/full/10.1287/opre.2022.2384). See details in **EC.5.3**. This generates the table reported in **EC.5.3**. The table is saved in a subfolder with a filename ending in `_runtime_stat<r>.xlsx`.

```bash
python data_generation_for_CAP.py
python run_compare_with_customization.py
```

**Note:** If everything goes well, this comparison should complete within 5 hours.

---

## Inventory Simulation

The detailed algorithm for the Monte Carlo simulation is provided in the online appendix of our paper.

- `run_inventory_simulation.py`: Python implementation that automatically generates the corresponding tables.

---

## Revenue-Ordered Heuristics

The detailed algorithm for the simple `Revenue-Ordered` heuristic method is first introduced in **Section 2.2**. The improved heuristic method is outlined as an algorithm in **EC.5.5**.

The implementation is incorporated into `BuildModels.py`.

- `data_generate_for_RO_heuristics_comparison.py`: Generates the instances for the results in **EC.5.5**.
- `run_compare_heuristics.py`: Generates results in the `./output_compare_heuristics_SO` folder. You should update the filename to point to the correct instance `.pkl` file.

---

## Additional Notes

You can also transfer and save the `.pkl` dataset to `.txt` format using `data_save_to_txt.py`. For details, please see the script.

---

## Contact

Feel free to reach out if you're interested in contributing additional features to this project or if you find any errors in the code.

- [Read the paper on arXiv](https://arxiv.org/pdf/2405.02553)
- [Email me](mailto:wylwork2018@gmail.com)