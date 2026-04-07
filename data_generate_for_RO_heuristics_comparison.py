import os
import numpy as np
import pandas as pd

import BuildModels as bm # BuildModels
import ToolFunctions as tf
import CompareFunc as cm
import copy

#%% generate new data
modelReport = ['MC_Conv-mo-soc-aC']

model_list = tf.get_model_list(modelReport)
# %% set the options
option = bm.Option()
option.para_randomData = 1
option.attV_Type = 'sparse'  # sparse, CAP, INT, CTN,
option.revenue_Type = 'VIP'  # VIP, CAP, INT, CTN,  COR_P, COR_N,
option.revenue_vip_group_number = 2  # default 2, if 1, online=offline, if 0, automatically selete the numCust
option.revenue_disc_range = [0.8, 1]  # default [0.9,1]
option.revenue_range = [10, 20]  # defaule [10,20]
option.ExtraConstrList = ['Luce']  # ['CardiOff', 'CardiOn', 'Prior', 'Luce', 'KnapsackOff', '']
option.kappaOff = 1  # default = 0.2
option.kappaOn = 1  # default = 0.2
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

# %%
numProd_numPust_list = [(20,10), (50, 10), (50, 25), (100,50)]
v0_off_v0_on_list = [(1, 2), (1, 5), (1, 10)]
arriveRatio_off_list = [0.1, 0.5]
luce_on_list = [0, 1]
capacity_off_on_list = [(0.1, 1), (1, 1)]
knapsack_off_on_list = [(0, 0)]

repeatNum = 12

probSettingSet = pd.MultiIndex.from_product(
    [numProd_numPust_list,
     arriveRatio_off_list,
     v0_off_v0_on_list,
     luce_on_list,
     capacity_off_on_list,
     knapsack_off_on_list],
    names=['Size', 'a0', 'v0', 'luce', 'capacity', 'knapsack'])

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

#%% generate data and option
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
            data.arriveRatio = [arriveRatio_off, 1 - arriveRatio_off]
            data.generate_extraCstr_data(numProd, numCust, exist=True)
            data.update()
        else:
            data = bm.Data(option, probSetting_info)

        probSetting_str = 'Sz{}_{}_v{}_{}_s{:.1f}_{:.1f}_c{:.1f}_{:.1f}_luce{:d}'.format(
            data.numProd, data.numCust,
            int(data.value_off_0), int(data.value_on_0[0]),
            data.utilitySparsity_off, data.utilitySparsity_on,
            data.kappaOff, data.kappaOn, luce)
        data.probName = data.probType + '_r%d_' % (r) + probSetting_str + '_%d_' % (s) + time_stamp_str
        dataOptionDict[probSetting_info] = data.probName, [copy.deepcopy(data), copy.deepcopy(option)]
    dataOptionDict_repeat[r] = copy.deepcopy(dataOptionDict)


#%% save dataOptionDict_repeat
filename = './DataSet/agg_dataOptionDict'+data.probType + '_repeat%d_'%repeatNum + time_stamp_str
tf.save(filename, dataOptionDict_repeat, probSettingSet, repeatNum, modelReport)
print("\n" + "="*50+"\n dataOptionDict_repeat \nsave to "+filename+"\n"+"="*50 + "\n" )