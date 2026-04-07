"""
This version currently only support to write the .pkl data set to txt file.
But does not support to read the data from txt file due to the complexity of 2SLM related parameters.

For the 2SLM constraint:
    The chain relationship are saved each customer segment individually.
    For each customer segment, the relationship are depicted by the adjacent matrix which corresponding to three elements:
        prodPerturb: the product set involved in the chain relationship
        (row col): depicts the adjacent matrix ADJ, where ADJ[row, col]=1 and other entries of ADJ is 0.
"""
import os, sys
import matplotlib.pyplot as plt
import pylab as pl
import itertools, time, copy
import pandas as pd
import numpy as np
import gc
import gurobipy as grb

import BuildModels as bm  # BuildModels
import ToolFunctions as tf
import CompareFunc as cm


#%% specify the .pkl file to transfer to .txt file
dataFolder = 'DataSet/'
dataNameList = os.listdir(dataFolder)
dataNameList = [name for name in dataNameList  if "dataOption" in name]
dataNameList = ['CustomizationCAP_dataOptionDictsparseCAPCardiOff_repeat36_2024-09-30-03-01-16.pkl']
dataNameList = ['agg_dataOptionDictsparseVIPLuce_repeat36_2024-09-22-04-20-19.pkl']
filename = dataFolder+dataNameList[0]
time_stamp_str = pd.Timestamp.now().strftime('%Y-%m-%d-%H-%M-%S')

#%% def function
def write_data_to_txt(data, filename):
    """
    write data to txt fle
    filename: the file name of .txt to be written
    BASIC PARAMETERS:
    DETAILED PARAMETERS: utilities vector, prices vector
    EXTRA CONSTRAINTS: graph's adjacency matrix for the 2SLM
    """
    with open(filename, 'w') as file:
        # Write probSetting_info
        file.write("BASIC PARAMETERS\n")
        file.write("numProd:\n" + str(data.numProd) + "\n")
        file.write("numCust:\n" + str(data.numCust) + "\n")
        file.write("arriveRatio_off:\n" + str(data.arriveRatio[0]) + "\n")
        file.write("v0_off:\n" + str(data.v0_off) + "\n")
        file.write("v0_on:\n" + str(data.v0_on) + "\n")
        file.write("luce:\n" + str(data.luce) + "\n")
        file.write("kappaOff:\n" + str(data.kappaOff) + "\n")
        file.write("kappaOn:\n" + str(data.kappaOn) + "\n")
        file.write("seprate_tol:\n" + str(data.separate_tol) + "\n")

        file.write("DETAILED PARAMETERS\n")
        file.write("V_off_0:\n" + str(data.v0_off) + "\n")
        file.write("V_off:\n" + " ".join(map(str, data.value_off_v)) + "\n")
        file.write("V_on_0:\n" + " ".join(map(str, data.value_on_0)) + "\n")
        file.write("V_on:\n")
        for row in data.value_on_v:
            file.write(" ".join(map(str, row)) + "\n")

        file.write("R_off:\n" + " ".join(map(str, data.r_off[:,0])) + "\n")
        file.write("R_on:\n")
        for row in data.r_on:
            file.write(" ".join(map(str, row)) + "\n")

        file.write("EXTRA CONSTRAINTS\n")
        for (key, v) in data.Ex_Cstr_Dict.items():
            if key == 'Luce':
                file.write(f"{key}:\n")
                v.to_csv(file, sep='\t', index=False, header=True, mode='a')
            if key == 'CardiOff':
                # for cardinality constraint, the only information is the cardinality ratio (data.kappaOff).
                file.write(f"{key}: cardinality ratio: {data.kappaOff}\n")
                pass
            if key == 'CardiOn':
                # for cardinality constraint, the only information is the cardinality ratio (data.kappaOn).
                file.write(f"{key}:  cardinality ratio: {data.kappaOn}\n")
                pass
            if key == 'KnapsackOff':
                pass
                # todo
#%%
repeatRange = range(1)
probSettingRange = range(1)

# filename = 'DataSet/' + ""

dataOptionDict_repeat, probSettingSet, repeatNum, _modelReport = tf.load(filename)
if len(repeatRange) == 0:
    repeatRange = range(len(dataOptionDict_repeat))
if len(probSettingRange) == 0:
    probSettingRange = range(len(probSettingSet))

tosavefolder = "DataSet/data_txt/" + filename[8:-4] + "/"
os.makedirs(tosavefolder, exist_ok=True)
for r in repeatRange:
    dataOptionDict = dataOptionDict_repeat[r]
    for s, probSetting_info in enumerate(probSettingSet):
        (numProd, numCust), arriveRatio_off, (v0_off, v0_on), luce, (kappaOff, kappaOn), (
            knapsack_off, knapsack_on) = probSetting_info
        probName, (data, option) = dataOptionDict[probSetting_info]

        filename = tosavefolder + f"n{numProd}_m{numCust}_arriveOff{arriveRatio_off}_v0Off{v0_off}_v0On{v0_on}_luce{luce}_kappaOff{kappaOff}_kappaOn{kappaOn}_r{r}.txt"
        write_data_to_txt(data, filename)
