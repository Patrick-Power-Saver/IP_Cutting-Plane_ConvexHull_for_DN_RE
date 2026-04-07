# -*- coding: utf-8 -*-
"""
Created on May 31 20 02:01:46 2025

@author: wyl2020

"""


import os, sys
from scipy.stats import pearsonr, spearmanr, kendalltau
import gc

import matplotlib.pyplot as plt
import pylab as pl
import itertools, time, copy
import pandas as pd
import numpy as np
import gurobipy as grb

import ToolFunctions as tf
import CompareFunc as cm

#%% obtain the parameter
# timelimit = float(sys.argv[1]) # sys.argv[1] #3600.0
# roundlimit = sys.argv[2] # recommend to use 2.
# repeatNum = sys.argv[3]  # should be less than 36.
# # probRnage = sys.argv[4] # should be 6, 12, or 18. see RUN_WITH_SETTING

timelimit = 3600.0
roundlimit = 2 #
repeatNum = 12  # should be less than 36
# probRnage = 6 # should be 6, 12, or 18. see RUN_WITH_SETTING
# (a, b) = (0, 3)
# probSettingRange = list(range(a, b)) + list(range(a+18, b+18))


# probSettingRange = list(range(0, 6)) + list(range(18,36))
probSettingRange = range(1,2)

#%%  load dataOptionDict_repeat_all file
# dataNameList = [name for name in os.listdir('./DataSet/')  if "agg_dataOptionDictsparseVIPLuce_repeat" in name]
dataNameList = [name for name in os.listdir('./DataSet/')  if "Customization" in name]
dataNameList = ['agg_dataOptionDictsparseVIPLuceCardiOff_repeat12_2024-09-22-04-20-19(for_compare_heuristics).pkl'] # the data is from the instance in table2
dataNameList = ['agg_dataOptionDictsparseVIPLuceCardiOff_repeat12_2025-06-11-23-38-46(small_size_for_compare_heuristics).pkl']
# dataNameList = ['agg_dataOptionDictsparseVIPLuceCardiOff_repeat12_2025-06-12-00-32-37.pkl']
filename = './DataSet/' +dataNameList[0]


modelReport = ['MC_Conv-mo-soc-aC', 'SO-enumerate_off', "SO-enumerate_off_enumerate_on"]
# modelReport = ["SO-enumerate_off", "SO-enumerate_off_enumerate_on"]
time_stamp_str = pd.Timestamp.now().strftime('%Y-%m-%d-%H-%M-%S')
tosavefolder = f"./output_compare_heuristics_SO/repeat_results_on_small/"



#%% run
dataOptionDict_repeat, probSettingSet, _repeatNum, _modelReport = tf.load(filename)
Table_repeat = cm.RUN_WITH_SETTING(tosavefolder,
                                   filename,
                                   modelReport,
                                   roundlimit=roundlimit, # no-negative integer
                                   timelimit=timelimit, # 3600
                                   repeatRange=range(repeatNum), # <=36
                                   probSettingRange=probSettingRange,
                                   ) # range(18)





