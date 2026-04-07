# -*- coding: utf-8 -*-
"""
Created on Sunday 13th April 2025

@author: wyl2020

"""

import os, sys
# cpy  = os.path.abspath(__file__)
# cwd = os.path.abspath(os.path.join(cpy, "../"))
# os.chdir(cwd)
# if cwd not in sys.path:
#     sys.path.append(cwd)
from scipy.stats import pearsonr, spearmanr, kendalltau

import matplotlib.pyplot as plt
import pylab as pl
import itertools, time, copy
import pandas as pd
import numpy as np



pd.set_option("display.max_columns", 20)
pd.set_option("display.width", 150)


import BuildModels as bm  # BuildModels
import ToolFunctions as tf
import CompareFunc as cm
#%% obtain the parameter
n = int(sys.argv[1])
m = int(sys.argv[2]) # (n,m) should be one of (100, 50), (150, 75), (200,100).
linspaceNum = int(sys.argv[3]) # should be odd number

#%% define the functions
def varying_v0(data, option, v0_list=np.array([2, 5, 10])):
    _dataOptionDict = {}
    probSettingSet_info_list = []
    v0_list = v0_list.astype(int)
    for v0_on in v0_list:
        data.v0_on = round(v0_on, 3)
        probSettingSet_info = (
        (data.numProd, data.numCust), 0.5, (data.v0_off, data.v0_on), data.luce, (data.kappaOff, data.kappaOn),
        (data.knapsackOff, data.knapsackOn))
        probSettingSet_info_list.append(probSettingSet_info)
        data.arriveRatio = [0.5, 0.5]
        data.update()
        _dataOptionDict[probSettingSet_info] = data.probName, [copy.deepcopy(data), copy.deepcopy(option)]

    for v0_on in v0_list:
        data.v0_on = round(v0_on, 3)
        data.luce = 1
        data.ExtraConstrList = ["Luce"]
        probSettingSet_info = (
        (data.numProd, data.numCust), 0.5, (data.v0_off, data.v0_on), data.luce, (data.kappaOff, data.kappaOn),
        (data.knapsackOff, data.knapsackOn))
        probSettingSet_info_list.append(probSettingSet_info)
        data.arriveRatio = [0.5, 0.5]
        data.update()
        _dataOptionDict[probSettingSet_info] = data.probName, [copy.deepcopy(data), copy.deepcopy(option)]

    _probSettingSet = pd.MultiIndex.from_tuples(probSettingSet_info_list)

    return _dataOptionDict, _probSettingSet


#%% save the data file
dataFolder = 'DataSet/'
dataNameList = [name for name in os.listdir(dataFolder)  if "dataOption" in name]
# dataNameList = ['CustomizationCAP_dataOptionDictsparseCAPCardiOff_repeat36_2024-09-30-03-01-16.pkl']
dataNameList = ['agg_dataOptionDictsparseVIPLuce_repeat36_2024-09-22-04-20-19.pkl']
filename = dataFolder+dataNameList[0]
modelReport = ['MC_Conv-mo-soc-aC']

dataOptionDict_repeat, probSettingSet, repeatNum, _modelReport = tf.load(filename)
match_size_loc = probSettingSet.get_level_values(0) == (100, 50)
probSettingSet =  probSettingSet[match_size_loc]


probName, (data, option) = dataOptionDict_repeat[0][probSettingSet[1]]
dataOptionDict, probSettingSet = varying_v0(data, option, v0_list=np.linspace(1, 20, linspaceNum) ) # v0_list = np.linspace(1,20,20) or [1, 10, 20]

os.makedirs('./output_assortment_map/dataset/', exist_ok=True)
filename = './output_assortment_map/dataset/dataOptionDict'+data.probType + f"_varying_v0_m{data.numProd}_n{data.numCust}"
tf.save(filename, dataOptionDict, probSettingSet)
print("\n" + "="*50+"\n dataOptionDict_varying_a0 \nsave to "+filename+"\n"+"="*50 + "\n" )

