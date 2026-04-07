# -*- coding: utf-8 -*-
"""
Created on Sat Jul 20 02:01:46 2024

@author: wyl2020
"""


import os, sys
import pandas as pd

# import BuildModels as bm # BuildModels
import ToolFunctions as tf
import CompareFunc as cm

#%% obtain the parameter
timelimit = float(sys.argv[1]) # sys.argv[1] #3600.0

#%%  load dataOptionDict_repeat_all file
dataFolder = './DataSet/'
dataNameList = [name for name in os.listdir(dataFolder)  if "agg_dataOptionDictsparseVIPLuce_repeat" in name]
# dataNameList = ['agg_dataOptionDictsparseVIPLuce_repeat36_2024-09-22-04-20-19.pkl']
filename = dataFolder+dataNameList[0]
modelReport = ['MC_Conv-mo-soc-aC']
time_stamp_str = pd.Timestamp.now().strftime('%Y-%m-%d-%H-%M-%S')
tosavefolder = f"./output_different_K/{time_stamp_str}_compare_different_K/"
os.makedirs(tosavefolder, exist_ok=True)

#%%
dataOptionDict_repeat, probSettingSet, repeatNum, _modelReport = tf.load(filename)
repeatRange = range(len(dataOptionDict_repeat))
probSettingRange = range(len(probSettingSet))
# repeatRange = range(3)# range(len(dataOptionDict_repeat))
# probSettingRange = range(6,12)#  range(0,6) or or range(6,12) # range(6,12) corresponds to (n,m)=(150,70)
#%% loop k

roundlimit_list = [0, 1, 2, 3, 4, 5]

for roundlimit in roundlimit_list:
    tosavefolder_K = f"{tosavefolder}/roundlimit_{roundlimit}/"
    cm.RUN_WITH_SETTING(tosavefolder_K,
                        filename,
                        modelReport,
                        roundlimit=roundlimit,
                        timelimit=timelimit, # 3600.0
                        repeatRange=repeatRange,
                        probSettingRange=probSettingRange)
