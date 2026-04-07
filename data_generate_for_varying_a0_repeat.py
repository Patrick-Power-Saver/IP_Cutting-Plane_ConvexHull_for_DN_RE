# -*- coding: utf-8 -*-
"""
Created on Fri Jul 19 16:06:20 2024

@author: wyl2020
"""

import os, sys
import itertools, time, copy
import pandas as pd
import numpy as np

import BuildModels as bm  # BuildModels
import ToolFunctions as tf
import CompareFunc as cm
#%% obtain the parameters
# n = int(sys.argv[1])
# m = int(sys.argv[2]) # (n,m) should be one of (100, 50), (150, 75), (200,100).
# linspaceNum = int(sys.argv[3]) # should be odd number, 5
# repeatNum = int(sys.argv[4]) # the number of repeating times

n = 100
m = 50 # (n,m) should be one of (100, 50), (150, 75), (200,100).
linspaceNum = 5
repeatNum = 3 # the number of repeating times

#%% define the functions
def varying_a0(data, option, a0_list = np.linspace(0.1,0.9,5) ):
    _dataOptionDict = {}
    probSettingSet_info_list = []
    for a0 in a0_list:
        a0 = float(round(a0,3))
        probSettingSet_info = ((data.numProd, data.numCust), a0, (data.v0_off, data.v0_on), data.luce, (data.kappaOff, data.kappaOn), (data.knapsackOff, data.knapsackOn) )
        probSettingSet_info_list.append(probSettingSet_info)
        data.arriveRatio = [a0, 1-a0]
        _dataOptionDict[probSettingSet_info] = data.probName, [copy.deepcopy(data), copy.deepcopy(option)]

    for a0 in a0_list:
        a0 = float(round(a0,3))
        data.luce = 1
        data.ExtraConstrList = ["Luce"]
        probSettingSet_info = (
        (data.numProd, data.numCust), a0, (data.v0_off, data.v0_on), data.luce, (data.kappaOff, data.kappaOn),
        (data.knapsackOff, data.knapsackOn))
        probSettingSet_info_list.append(probSettingSet_info)
        data.arriveRatio = [a0, 1 - a0]
        _dataOptionDict[probSettingSet_info] = data.probName, [copy.deepcopy(data), copy.deepcopy(option)]

    _probSettingSet= pd.MultiIndex.from_tuples(probSettingSet_info_list)

    return _dataOptionDict, _probSettingSet




#%% save the data file
dataFolder = 'DataSet/'
dataNameList = [name for name in os.listdir(dataFolder)  if "dataOption" in name]
dataNameList = ['agg_dataOptionDictsparseVIPLuce_repeat36_2024-09-22-04-20-19.pkl']
filename = dataFolder+dataNameList[0]
modelReport = ['MC_Conv-mo-soc-aC']

dataOptionDict_repeat, probSettingSet, repeatNum, _modelReport = tf.load(filename)
match_size_loc = probSettingSet.get_level_values(0) == (100, 50)
probSettingSet =  probSettingSet[match_size_loc]

_dataOptionDict_repeat = {}
for r in range(repeatNum):
    probName, (data, option) = dataOptionDict_repeat[r][probSettingSet[1]] # v0_on=5
    _dataOptionDict, _probSettingSet = varying_a0(data, option, a0_list=np.linspace(0,.99,linspaceNum))
    _dataOptionDict_repeat[r] = copy.deepcopy(_dataOptionDict)

os.makedirs('./output_joint_benefit_luce_loss/dataset/', exist_ok=True)
filename = './output_joint_benefit_luce_loss/dataset/dataOptionDict'+data.probType + f"_varying_a0_m{data.numProd}_n{data.numCust}"
tf.save(filename, _dataOptionDict_repeat, _probSettingSet, repeatNum, modelReport)
print("\n" + "="*50+"\n dataOptionDict_varying_a0 \nsave to "+filename+"\n"+"="*50 + "\n" )


