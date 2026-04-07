# -*- coding: utf-8 -*-
"""
Created on Fri Jul 19 16:06:20 2024

@author: wyl2020

generate the data set with capacity constraints.
"""

import os, sys

import matplotlib.pyplot as plt
import pylab as pl
import itertools, time, copy
import pandas as pd
import numpy as np

import gurobipy as grb

import BuildModels as bm  # BuildModels
import ToolFunctions as tf
import CompareFunc as cm

modelReport = ['MC_Conv-mo-soc-aC']

opt_modelname = 'MC_Conv-soc-aC'

model_list = tf.get_model_list(modelReport)
print(model_list)

# %%
option = bm.Option()
option.para_randomData = 1
option.attV_Type = 'sparse'  # sparse, CAP, INT, CTN,
option.utilitySparsity_off = 1
option.utilitySparsity_on = 0.5
option.revenue_Type = 'CAP'  # VIP, CAP, INT, CTN,  COR_P, COR_N,
option.revenue_vip_group_number = 2  # default 2, if 1, online=offline, if 0, automatically selete the numCust
option.revenue_disc_range = [0.8, 1]  # default [0.9,1]
option.revenue_range = [10, 20]  # defaule [10,20]
option.ExtraConstrList = ['Luce']  # ['CardiOff', 'CardiOn', 'Prior', 'Luce', 'KnapsackOff', '']
# option.kappaOff = 0.5 # default = 0.2
# option.kappaOn = 0.2 # default = 0.2
option.luceType = 'Tree'  # Tree, GroupPair
option.luceTree_nodeRatio = 0.25  # default 0.25
option.luceGroup_nodeRatio = 1  # default 0.5
# option.grb_para_timelimit = 200 #3600  100
option.arriveRatio = [0.0, 1]  # default [0.5, 0.5]

option.read_data = 0

if 'CardiOff' in option.ExtraConstrList or 'CardiOn' in option.ExtraConstrList:
    option.cardiMC = 1

option.plot_network = 0
option.para_plot = 0
option.para_plot_save = 0
option.para_logging = 0
option.para_write_lp = 0
option.gapApproach = ['continuous']  # nodeLimit or continuous
option.compute_relax_gap = 1

option.modelReport = modelReport
option.model_list = model_list

option.savereport = 1

option.cut_round_limit = 2
option.MMNL = 0

useOldDataOption = 0
repeatNum = 6
# %%

# numProd_numPust_list = [(100, 50), (100, 100), (100,500), (1000, 100)]
# numProd_numPust_list = [(50, 10), (50,50), (50, 100),  (100, 10), (100, 50), (100, 100), (1000,10), (1000, 50), (1000,100)]
# numProd_numPust_list = [(50, 10)]

# numProd_numPust_list = [(50, 10), (50,50), (50, 100),  (100, 10), (100, 50), (100, 100), (200, 500)]

numProd_numPust_list = [(100,75), (200,100)]



arriveRatio_off_list = [0]
v0_off_v0_on_list = [(1, 2), (1, 5), (1, 10)]
luce_on_list = [0, 1]
capacity_off_on_list = [(0.1, 1),  (0.3, 1), (0.5, 1)]
knapsack_off_on_list = [(0, 0)]



probSettingSet = pd.MultiIndex.from_product(
    [numProd_numPust_list, arriveRatio_off_list, v0_off_v0_on_list, luce_on_list, capacity_off_on_list,
     knapsack_off_on_list])

rootnodeGap = []
if 'nodeLimit' in option.gapApproach:
    rootnodeGap.append('r_gap')
    rootnodeGap.append('ObjRoot+')
if 'continuous' in option.gapApproach:
    rootnodeGap.append('c_gap')
    rootnodeGap.append('ObjCtn+')
option.variableNeed = ['Runtime', 'Separtime', 'addConstrTime', 'ObjVal', 'NumAssort', 'NumAssort_onAvg', 'gap',
                       'Status'] + rootnodeGap + ['e_gap', 'NumConstrs', 'NodeCount', 'R_Status', 'R_Runtime',
                                                  'ObjRoot', 'ObjCtn', 'ObjBound', 'ObjValLuce']
option.variableReport = rootnodeGap + ['ObjVal', 'gap', 'Runtime', 'NumConstrs', 'NumAssort_onAvg', 'NodeCount',
                                       'NumAssort', 'NumSolved', 'ObjValLuce']

# %% generate (load) data and option
modeify_v0= 1
dataOptionDict_repeat = {}
for r in range(repeatNum):
    time_stamp = pd.Timestamp.now()
    time_stamp_str = str(time_stamp.date()) + '-{:02}-{:02}-{:02}'.format(time_stamp.hour, time_stamp.minute,
                                                                          time_stamp.second)

    dataOptionDict = {}
    for s, probSetting_info in enumerate(probSettingSet):
        (numProd, numCust), arriveRatio_off, (v0_off, v0_on), luce, (kappa_off, kappa_on), (
        knapsack_off, knapsack_on) = probSetting_info

        print('\n\n==============================================\n')
        print('======{}th prob with setting:'.format(s) + str(probSetting_info))
        print('\n==============================================\n\n')

        if (s > 0) & ((knapsack_off, knapsack_on) == probSettingSet[s - 1][5]) & (
                (numProd, numCust) == probSettingSet[s - 1][0]):
            data.v0_off, data.v0_on = v0_off, v0_on
            data.kappaOff, data.kappaOn = kappa_off, kappa_on
            data.knapsackOff, knapsack_on = knapsack_off, knapsack_on
            data.luce = luce
            data.generate_extraCstr_data(numProd, numCust)
            data.arriveRatio = [arriveRatio_off, 1 - arriveRatio_off]
            data.update()

            if v0_off < 0:
                data.value_off_0 = data.value_off_v.sum(axis=0) / -v0_off
            if v0_on < 0:
                data.value_on_0 = data.value_on_v.sum(axis=0) / -v0_on

            # if modeify_v0 == 1:
            #     # modify value_on_0
            #     if v0_on < 0:
            #         v0_off = data.value_off_v.sum(axis=0)
            #         v0_on = data.value_on_v.sum(axis=0)
            #     data.value_off_0 = data.value_off_v.sum(axis=0) / v0_off
            #     data.value_on_0 = data.value_on_v.sum(axis=0) / v0_on
        else:
            data = bm.Data(option, probSetting_info)

            ################################ refining the data
            #$$ generate the revenue
            r_off = np.random.exponential(1, size=(numProd, 1)) # exponential distribution
            r_on = np.repeat(r_off, numCust, axis=1)

            r_off = r_off.round(3)
            r_on = r_on.round(3)

            data.r_off = r_off
            data.r_on = r_on

            #$$ generate the attractive value
            k_off = int(data.utilitySparsity_off * numProd)
            k_on = int(data.utilitySparsity_on * numProd)
            value_off_0 = data.v0_off  # np.random.rand() * self.v0_off
            value_off_v = np.zeros(numProd)
            loc = list(np.random.permutation(numProd))
            value_off_v[loc[:k_off]] = np.random.rand(k_off)
            value_on_0 = np.ones(numCust) * data.v0_on
            value_on_v = np.zeros((numProd, numCust)) #+ np.eye(numProd, numCust)
            for col in range(numCust):
                loc = list(np.random.permutation(numProd))
                if (col < numProd):
                    loc.remove(col)
                    if (k_on == numProd):
                        k_on = k_on - 1
                value_on_v[loc[:k_on], col] = abs(np.random.randn(1, k_on)) # folder standard normal
                # value_on_v[loc[:k_on], col] = np.random.rand(1, k_on) # uniform U[0,1]
                # value_on_v[loc[:k_on], col] = np.random.exponential(1, size=(1,k_on)) # uniform U[0,1]

            if v0_off < 0:
                data.value_off_0 = data.value_off_v.sum(axis=0) / -v0_off
            if v0_on < 0:
                data.value_on_0 = data.value_on_v.sum(axis=0) / -v0_on
            # if modeify_v0 == 1:
            #     #modify value_on_0
            #     if v0_on < 0:
            #         v0_off = value_off_v.sum(axis=0)
            #         v0_on = value_on_v.sum(axis=0)
            #     value_on_off = value_off_v.sum(axis=0) / v0_off
            #     value_on_0 = value_on_v.sum(axis=0) / v0_on

            value_off_0 = value_off_0
            value_off_v = value_off_v.round(3)
            value_on_0 = value_on_0.round(3)
            value_on_v = value_on_v.round(3)

            data.value_off_0 = value_off_0
            data.value_off_v = value_off_v
            data.value_on_0 = value_on_0
            data.value_on_v = value_on_v
            data.numProd = numProd
            data.numCust = numCust
            data.I = list(range(numProd))  # index set of products
            data.J = list(range(numCust))  # index set of online-customer type
            data.prod_cust = list(itertools.product(data.I, data.J))

            ################################ end of refining the data

        probSetting_str = 'Sz{}_{}_v{}_{}_s{:.1f}_{:.1f}_c{:.1f}_{:.1f}_luce{:d}'.format(
            data.numProd, data.numCust,
            int(data.value_off_0), int(data.value_on_0[0]),
            data.utilitySparsity_off, data.utilitySparsity_on,
            data.kappaOff, data.kappaOn, luce)
        data.probName = data.probType + '_r%d_' % (r) + probSetting_str + '_%d_' % (s) + time_stamp_str
        dataOptionDict[probSetting_info] = data.probName, [copy.deepcopy(data), copy.deepcopy(option)]
    dataOptionDict_repeat[r] = copy.deepcopy(dataOptionDict)


#%% save dataOptionDict_repeat
os.makedirs('./output_customization/dataset/', exist_ok=True)
filename = './output_customization/dataset/CustomizationCAP_dataOptionDict' + data.probType + '_repeat%d_' % repeatNum + time_stamp_str
tf.save(filename, dataOptionDict_repeat, probSettingSet, repeatNum, modelReport)
print("\n" + "=" * 50 + "\n dataOptionDict_repeat \nsave to " + filename + "\n" + "=" * 50 + "\n")


