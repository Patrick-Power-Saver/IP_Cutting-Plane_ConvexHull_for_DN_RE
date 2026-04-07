# Data Structure Introduction

The data is packaged as a `.pkl` file in the `DataSet` folder. You can find it in `./DataSet/` or [download the dataset](https://github.com/YLW2018/IP_Assortment_CODE/tree/502b5c428f1c9fe71b555bbd6c9f09a4a62496b8/DataSet). The dataset file is over 200 MB in size. Due to GitHub's size limit, if you encounter download issues, please contact the author via email.

---

## Data Dictionary

### Loading the Data

The overall data is saved in a single `.pkl` file, which provides everything necessary for reproducing the results in Table 2 (Section 6). You can load the data usingß:
```python
import BuildModels as bm 
import ToolFunctions as tf
import CompareFunc as cm

filename = 'DataSet/agg_dataOptionDictsparseVIPLuce_repeat36_2024-09-22-04-20-19.pkl'
dataOptionDict_repeat, probSettingSet, repeatNum, modelReport = tf.load(filename)
```

### Data Components

The loaded data contains four parts:

1. **`dataOptionDict_repeat`**: Provides all the necessary entries characterizing the instances.

1. **`probSettingSet`**: Provides a pandas `MultiIndex` characterizing the problem size and type. Each index corresponds to a combination of problem parameters:
   
   `(n, m), (alpha0), (v0_off, v0_on), (luce), (kappa_on, kappa_off), (knapsack_off, knapsack_on)`
   
   The structure looks like:
    ```python
    MultiIndex([( (100, 50), 0.5,  (1, 2), 0, (1, 1), (0, 0)),
                ( (100, 50), 0.5,  (1, 5), 0, (1, 1), (0, 0)),
                ( (100, 50), 0.5, (1, 10), 0, (1, 1), (0, 0)),
                ( (100, 50), 0.5,  (1, 2), 1, (1, 1), (0, 0)),
                ( (100, 50), 0.5,  (1, 5), 1, (1, 1), (0, 0)),
                ( (100, 50), 0.5, (1, 10), 1, (1, 1), (0, 0)),
                ( (150, 75), 0.5,  (1, 2), 0, (1, 1), (0, 0)),
                ( (150, 75), 0.5,  (1, 5), 0, (1, 1), (0, 0)),
                ( (150, 75), 0.5, (1, 10), 0, (1, 1), (0, 0)),
                ( (150, 75), 0.5,  (1, 2), 1, (1, 1), (0, 0)),
                ( (150, 75), 0.5,  (1, 5), 1, (1, 1), (0, 0)),
                ( (150, 75), 0.5, (1, 10), 1, (1, 1), (0, 0)),
                ((200, 100), 0.5,  (1, 2), 0, (1, 1), (0, 0)),
                ((200, 100), 0.5,  (1, 5), 0, (1, 1), (0, 0)),
                ((200, 100), 0.5, (1, 10), 0, (1, 1), (0, 0)),
                ((200, 100), 0.5,  (1, 2), 1, (1, 1), (0, 0)),
                ((200, 100), 0.5,  (1, 5), 1, (1, 1), (0, 0)),
                ((200, 100), 0.5, (1, 10), 1, (1, 1), (0, 0))]
    )
    ```
   
   **Parameter Definitions:**
   - `m`: Number of products
   - `n`: Number of customer segments
   - `alpha0`: Arrival ratio of the offline customer segment
   - `v0_off` and `v0_on`: Non-purchase option utility for the offline and online segments, respectively
   - `luce`: Indicates whether it is subject to the 2-Stage-Luce-Model for the online channel (`luce=1`) or not (`luce=0`)
   - `kappa_on` and `kappa_off`: Right-hand side of the capacity constraints for online and offline segments, respectively
   - `knapsack_off` and `knapsack_on`: Right-hand side of the knapsack constraints for offline and online segments, respectively (coefficients should be provided separately)

1. **`repeatNum`**: The total number of repetitions. This should be 36, as each combination was repeated 36 times.

1. **`modelReport`**: The models to be compared. The expected value is: 
   ```python
   modelReport = ['Conic_Conic-mo', 'MC_Conv-mo-soc-aC', 'MILP']
   ```
   
   Where:
   - `Conic_Conic-mo`: The **Conic** formulation
   - `MILP`: The **MILP** formulation
   - `MC_Conv-mo-soc-aC`: The implementation of our proposed approach, corresponding to **CH-K** (see Algorithm 2 in the paper for details)

---

## Understanding `dataOptionDict_repeat`

The `dataOptionDict_repeat` component plays the most important role in delivering the instance parameters, including:

- Instance scale (number of customer segments and products)
- Preference weight for each product for each customer segment
- Revenue for each product for each customer segment
- Online and offline customer arrival ratios
- Adjacency matrix characterizing the dominating relationships used for the 2-Stage-Luce-Model
### Structure of `dataOptionDict_repeat`

The `dataOptionDict_repeat` is a dictionary with keys `range(0, repeatNum)`.

To view the keys:
```python
>>> dataOptionDict_repeat.keys()
```

You will see:
```python
dict_keys([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35])
```

Access a specific repetition:
```python
>>> dataOptionDict = dataOptionDict_repeat[r]  # r is the repetition number
```

### Structure of `dataOptionDict`

The `dataOptionDict` is a dictionary with keys from `probSettingSet`.

To see the keys:
```python
>>> list(dataOptionDict.keys())
```

You will get: 
```python
    [((100, 50), 0.5, (1, 2), 0, (1, 1), (0, 0)),
    ((100, 50), 0.5, (1, 5), 0, (1, 1), (0, 0)),
    ((100, 50), 0.5, (1, 10), 0, (1, 1), (0, 0)),
    ((100, 50), 0.5, (1, 2), 1, (1, 1), (0, 0)),
    ((100, 50), 0.5, (1, 5), 1, (1, 1), (0, 0)),
    ((100, 50), 0.5, (1, 10), 1, (1, 1), (0, 0)),
    ((150, 75), 0.5, (1, 2), 0, (1, 1), (0, 0)),
    ((150, 75), 0.5, (1, 5), 0, (1, 1), (0, 0)),
    ((150, 75), 0.5, (1, 10), 0, (1, 1), (0, 0)),
    ((150, 75), 0.5, (1, 2), 1, (1, 1), (0, 0)),
    ((150, 75), 0.5, (1, 5), 1, (1, 1), (0, 0)),
    ((150, 75), 0.5, (1, 10), 1, (1, 1), (0, 0)),
    ((200, 100), 0.5, (1, 2), 0, (1, 1), (0, 0)),
    ((200, 100), 0.5, (1, 5), 0, (1, 1), (0, 0)),
    ((200, 100), 0.5, (1, 10), 0, (1, 1), (0, 0)),
    ((200, 100), 0.5, (1, 2), 1, (1, 1), (0, 0)),
    ((200, 100), 0.5, (1, 5), 1, (1, 1), (0, 0)),
    ((200, 100), 0.5, (1, 10), 1, (1, 1), (0, 0))]
```

Access a specific problem setting:
```python
probName, (data, option) = dataOptionDict[probSetting_info]  
# probSetting_info is a key (index from probSettingSet) that locates the specific problem
```

**Components:**
- **`probName`**: The name of this problem instance
- **`(data, option)`**: Contains the parameters including:
  - Preference weights
  - Revenue
  - Arrival ratios
  - 2-Stage-Luce-Model characterizing parameters
  - Additional problem-specific data

These use custom classes defined in `BuildModels.py`. See the `Option` and `Data` class definitions for details. These objects are the necessary inputs for the subsequent solving procedures.

---

## Converting Data to Text Format

If you want to convert the data to `.txt` files, use the provided `data_save_to_txt.py` script. This is also helpful for understanding the data structure.

---

## Note

**The datasets for other numerical results follow a similar structure. See `readme.md` for details.**
