# -*- coding: utf-8 -*-
"""
Created on Mon Jul  3 14:20:41 2023

@author: wyl2020
@email:wylwork_sjtu@sjtu.edu.cn
"""

import os, sys
import BuildModels as bm  # BuildModels
import ToolFunctions as tf
import CompareFunc as cm




#%% obtain the parameter
timelimit = float(sys.argv[1]) # sys.argv[1] #3600.0
varying_type = sys.argv[2] # sys.argv[2] #  # "varying_v0" or "varying_a0"
# timelimit = 100.0 # sys.argv[1] #3600.0
# varying_type = "varying_v0" # sys.argv[2] #  # "v0" or "a0"


dataFolder = 'output_joint_benefit_luce_loss/dataset/'
dataNameList = [name for name in os.listdir(dataFolder)  if varying_type in name]
filename = dataFolder + dataNameList[0]


modelReport = ['MC_Conv-mo-soc-aC', 'SO-RO_off']
tosavefolder = f"./output_joint_benefit_luce_loss/{varying_type}/"

# dataOptionDict_repeat, probSettingSet, repeatNum, _modelReport = tf.load(filename)
#%% run for given data and option
Table_repeat = cm.RUN_WITH_SETTING(tosavefolder,
                                   filename,
                                   modelReport,
                                   roundlimit=2, # no-negative integer
                                   timelimit=timelimit, # 3600
                                   repeatRange=range(0), # 36
                                   probSettingRange=range(0)) # range(18)

