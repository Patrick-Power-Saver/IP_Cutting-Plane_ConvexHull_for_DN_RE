import os, sys
from scipy.stats import pearsonr, spearmanr, kendalltau
import gc
import json

import matplotlib.pyplot as plt
import pylab as pl
import itertools, time, copy
import pandas as pd
import numpy as np
import gurobipy as grb

import BuildModels as bm # BuildModels
import ToolFunctions as tf
import CompareFunc as cm


#%% define functions
# get the demand // fluid approximation
def get_demand(data, solutions, T):
    value_off_0 = data.value_off_0
    value_off_v = data.value_off_v
    value_on_0 = data.value_on_0
    value_on_v = data.value_on_v
    r_off = data.r_off
    r_on = data.r_on
    I = data.I
    J = data.J
    arriveRatio_off = data.arriveRatio[0] / (data.arriveRatio[0] + data.arriveRatio[1])
    arriveRatio_on = data.arriveRatio[1] / (data.arriveRatio[0] + data.arriveRatio[1])
    arriveRatio_on = np.repeat(arriveRatio_on, data.numCust) / data.numCust

    m = 'MC_Conv-mo-soc-aC'
    obj = solutions.loc["obj", m]
    s_y_off_y = solutions.loc[[ind for ind in solutions.index if 'y_off_y' in ind], m]
    s_y_on_y = solutions.loc[[ind for ind in solutions.index if 'y_on_y' in ind], m]
    s_y_on_y = s_y_on_y.values.reshape(data.numProd, data.numCust)
    demand_off = s_y_off_y.values *value_off_v * arriveRatio_off
    demand_on = np.sum(s_y_on_y * value_on_v * arriveRatio_on, axis=1)

    demand = demand_off + demand_on
    V_fluid = float(T * obj)
    Q_fluid = T * demand
    S_off_fluid = np.where(s_y_off_y > 1e-8)
    S_on_fluid = [np.where(s_y_on_y[:,j] > 1e-8)[0] for j in data.J]
    S_total = np.where(demand > 1e-8)[0]


    sigma = int(np.ceil(sum(Q_fluid)) - sum(np.floor(Q_fluid)))
    weighted_revenue = r_off.reshape(data.numProd) * arriveRatio_off + np.sum(r_on * arriveRatio_on, axis=1)
    r_sort_ind = np.argsort(-weighted_revenue[S_total])
    Q_round = copy.copy(Q_fluid)

    Q_round[S_total[r_sort_ind[:sigma]]] = np.ceil(Q_round[S_total[r_sort_ind[:sigma]]])
    Q_round[S_total[r_sort_ind[sigma:]]] = np.floor(Q_round[S_total[r_sort_ind[sigma:]]])

    return Q_round, Q_fluid, V_fluid, S_off_fluid, S_on_fluid, sigma


# -------- inventory simulation related ----------------
def rand_customer_type(data):
    """generate a random customer type"""
    arriveRatio_off = data.arriveRatio[0] / (data.arriveRatio[0] + data.arriveRatio[1])
    arriveRatio_on = data.arriveRatio[1] / (data.arriveRatio[0] + data.arriveRatio[1])
    arriveRatio_on = np.repeat(arriveRatio_on, data.numCust) / data.numCust
    _rand = [arriveRatio_off, *arriveRatio_on]
    _rand = np.cumsum(_rand)/sum(_rand)
    _r  = np.random.rand()
    _j = next(i for i, val in enumerate(_rand) if val > _r)
    _j = _j - 1
    # - means the offline customer segment
    return _j

"""get the available product set according to the inventory Q"""
get_available_set = lambda Q: [i for i in data.I if Q[i] > 0]

def purchase(data, j, assortment, cost):
    """customer type j make a purchase decision"""
    r_off = data.r_off
    r_on = data.r_on
    value_off_0 = data.value_off_0
    value_off_v = data.value_off_v
    value_on_0 = data.value_on_0
    value_on_v = data.value_on_v

    if len(assortment) == 0:
        i = -1
        revenue = 0.0
        return i, revenue # purchase nothing, thus zero revenue
    if j < 0 :
        _p = 1 / (value_off_0 + sum(value_off_v[assortment]))
        p0 = _p * value_off_0
        purchase_probability = _p * value_off_v[assortment]
    else:
        _p = 1 / (value_on_0[j] + sum(value_on_v[assortment,j]))
        p0 = _p * value_on_0[j]
        purchase_probability = _p * value_on_v[assortment,j]
    p = [p0, *purchase_probability]
    p_cumsum = np.cumsum(p)
    _r = np.random.rand()
    _i = next(i for i, val in enumerate(p_cumsum) if val > _r)
    _i = _i - 1
    if _i < 0:
        i = _i # -1 means the non-purchase option
    else:
        i = assortment[_i]

    # get the revenue for product i from customer segment j
    if j < 0:
        _r = r_off.reshape(data.numProd) + cost
    else:
        _r = r_on[:,j] + cost
    if i < 0:
        revenue = 0
    else:
        revenue = _r[i]
    return int(i), float(revenue)

# fix assortment, no reoptimize
def simulate_fixed_assortment(data, Q_int, S_off_fixed, S_on_fixed, cost, T =100, seed=2025):
    """inventory simulation with the fixed assortment"""
    np.random.seed(seed)
    Q = copy.copy(Q_int)
    purchase_revenue_path = list()
    inventory_path = list()
    for t in range(T):
        available_set = get_available_set(Q)
        j = rand_customer_type(data)
        if j < 0:
            assortment = np.intersect1d(S_off_fixed, available_set)
        else:
            assortment = np.intersect1d(S_on_fixed[j], available_set)
        i, revenue = purchase(data, j, assortment, cost)
        purchase_revenue_path.append((i, j, revenue))
        if i >= 0:
            Q[i] = Q[i] - 1
        inventory_path.append(copy.copy(Q))

    revenue_path = [v[2] for v in purchase_revenue_path]
    revenue = sum(revenue_path)
    return revenue, purchase_revenue_path, inventory_path

def simulate(data, solutions, T=100, paths_number=1000):
    """simulate
        data: include all the necessary data discribing the instance
        solutions: the solution
    """


    # get rounded inventory
    # T = 100
    Q_round, Q_fluid, V_fluid, S_off_fluid, S_on_fluid, sigma = get_demand(data, solutions, T)

    V_simul_paths = []
    cost = np.ones(data.numProd)
    # cost = np.zeros(data.numProd)
    for l in range(paths_number):
        revenue, purchase_revenue_path, Q_path = simulate_fixed_assortment(data, Q_round, S_off_fluid, S_on_fluid, cost, T=T, seed=2025+l)
        V = revenue - sum(Q_round*cost) #+ sum(Q_hist[-1] * cost)
        V_simul_paths.append(float(V))
        # print(f"V_fluid: {V_fluid}, V_simul: {V}")
    V_simul = float(np.mean(V_simul_paths))
    print("T: %3d, V_fluid: %8.3f, V_simul: %8.3f, gap%%: %3.3f, " % (T, V_fluid, V_simul, 100*(V_fluid-V_simul)/V_fluid))
    return V_fluid, V_simul, V_simul_paths

def get_table_result(simulation_result):
    """get dataframe result from simulation_result"""
    pd.set_option('display.max_columns', 100)
    pd.set_option('display.width', 200)
    df = pd.DataFrame(index = simulation_result.keys(),
                      columns=["V_fluid", "V_simul", "abs_gap", "gap%", "max_V_simul", "max_gap%"])
    df.index.names = ['size', 'a0', 'v0', 'luce', 'cardi', 'knap', 'T']
    for key, value in simulation_result.items():
        V_fluid = value["V_fluid"]
        V_simul = value["V_simul"]
        V_simul_paths = value["V_simul_paths"]
        abs_gap = V_fluid - V_simul
        gap = (V_fluid - V_simul)/V_fluid * 100
        gap_max = (V_fluid - np.max(V_simul_paths)) / V_fluid * 100
        df.loc[key,:] = [V_fluid, V_simul, abs_gap, gap, np.max(V_simul_paths), gap_max]
    df = df.astype(float)
    return df
#%% load data
dataNameList = [name for name in os.listdir('./DataSet/')  if "Customization" in name]
dataNameList = ['agg_dataOptionDictsparseVIPLuceCardiOff_repeat36_2024-09-22-04-20-19.pkl']
filename = './DataSet/' +dataNameList[0]


# modelReport = ['MC_Conv-mo-soc-aC', 'SO-enumerate_off', "SO-enumerate_off_enumerate_on"]
# modelReport = ["SO-enumerate_off", "SO-enumerate_off_enumerate_on"]
modelReport = ['MC_Conv-mo-soc-aC']
time_stamp_str = pd.Timestamp.now().strftime('%Y-%m-%d-%H-%M-%S')
tosavefolder = f"./out_inventory_simulation/"
#%% solve problem
timelimit = 3600.0
roundlimit = 2 #
repeatNum = 1
# probSettingRange = list(range(0, 1))
probSettingRange = list(range(0, 3)) #+ list(range(18,36))
Table_repeat = cm.RUN_WITH_SETTING(tosavefolder,
                                   filename,
                                   modelReport,
                                   roundlimit=roundlimit, # no-negative integer
                                   timelimit=timelimit, # 3600
                                   repeatRange=range(repeatNum), # <=36
                                   probSettingRange=probSettingRange,
                                   ) # range(18)

#%%
# load the result
foldername = f"{tosavefolder}"
# dataNameList = [name for name in os.listdir(foldername)  if "InfoDict" in name]
dataNameList = ['SolutionDict_InfoDict_dataOptionDict_repeat_2025-06-07-23-19-35_0.pkl']
filename = foldername + dataNameList[0]
SolutionDict = tf.load(filename)[0]['SolutionDict']
InfoDict = tf.load(filename)[0]['InfoDict']
dataOptionDict = tf.load(filename)[0]['dataOptionDict']
probSettingSet = tf.load(filename)[0]['probSettingSet']
modelReport = tf.load(filename)[0]['modelReport']

simulation_result = dict()
probSettingRange = list(range(0, 3))
for s in probSettingRange:
    probSettingSet_info = probSettingSet[s]
    print(f"\n=========={probSettingSet_info}=========\n")
    data, option = dataOptionDict[probSettingSet_info][1]
    solutions = SolutionDict[probSettingSet_info][1]

    T_range = 10 * 2 ** np.array(range(5))
    T_range = [500, 1000, 2000]
    for T in T_range:
        V_fluid, V_simul, V_simul_paths = simulate(data, solutions, T=T, paths_number=1000)
        result = {"V_fluid": V_fluid, "V_simul": V_simul, "V_simul_paths": V_simul_paths}
        key = probSettingSet_info + (T, )
        simulation_result[key] = result

#%% process the result
df = get_table_result(simulation_result)
print(round(df, 3))
filename = f"{tosavefolder}inventory_simulation_T" + "_".join(str(T) for T in T_range)
df.to_csv(filename + ".csv")
print(f"\n=================== save to {filename}============")

# Save to file
with open(filename + '.json', 'w') as f:
    json.dump(simulation_result, f)

# Load from file
# with open('data.json', 'r') as f:
#     data = json.load(f)