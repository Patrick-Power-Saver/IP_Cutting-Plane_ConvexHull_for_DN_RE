import os
import numpy as np
import pandas as pd

import ToolFunctions as tf
import copy

#%% load data
filename = "DataSet/agg_dataOptionDictsparseVIPLuce_repeat36_2024-09-16-22-09-36.pkl"
filename = "DataSet/CAP_largeV0_dataOptionDictsparseCAPCardiOff_repeat36_2024-09-20-15-20-31.pkl"

dataOptionDict_repeat, probSettingSet, repeatNum, modelReport = tf.load(filename)

for r in range(len(dataOptionDict_repeat)):
    for s in range(len(probSettingSet)):
        dataOptionDict_repeat[r][probSettingSet[s]][1][0].arriveRatio = copy.deepcopy(dataOptionDict_repeat[r][probSettingSet[s]][1][0].arrivRatio)
        del dataOptionDict_repeat[r][probSettingSet[s]][1][0].arrivRatio


tf.save(filename, dataOptionDict_repeat, probSettingSet, repeatNum, modelReport)
print("\n" + "="*50+"\n dataOptionDict_repeat \nsave to "+filename+"\n"+"="*50 + "\n" )
