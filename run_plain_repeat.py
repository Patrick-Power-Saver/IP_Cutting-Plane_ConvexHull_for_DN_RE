# -*- coding: utf-8 -*-
"""
Created on Sat Jul 20 02:01:46 2024

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
timelimit = float(sys.argv[1]) # sys.argv[1] #3600.0
roundlimit = sys.argv[2] # recommend to use 2.
repeatNum = sys.argv[3]  # should be less than 36.
# probRnage = sys.argv[4] # should be 6, 12, or 18. see RUN_WITH_SETTING

# timelimit = 100.0
# roundlimit = 2 #
# repeatNum = 12  # should be less than 36
# probRnage = 6 # should be 6, 12, or 18. see RUN_WITH_SETTING


#%%  load dataOptionDict_repeat_all file
dataNameList = [name for name in os.listdir('./DataSet/')  if "agg_dataOptionDictsparseVIPLuce_repeat" in name]
# dataNameList = ['agg_dataOptionDictsparseVIPLuce_repeat36_2024-09-22-04-20-19.pkl']
filename = './DataSet/' +dataNameList[0]

modelReport = ['Conic_Conic-mo',  'MC_Conv-mo-soc-aC', 'MILP']
time_stamp_str = pd.Timestamp.now().strftime('%Y-%m-%d-%H-%M-%S')
tosavefolder = f"./output_plain_repeat/plain_repeat_results/"

#%% run
Table_repeat = cm.RUN_WITH_SETTING(tosavefolder,
                                   filename,
                                   modelReport,
                                   roundlimit=roundlimit, # no-negative integer
                                   timelimit=timelimit, # 3600
                                   repeatRange=range(repeatNum), # <=36
                                   probSettingRange=range(0)) # range(18)

#%% ######## NEXT IS FOR GENERATING THE FINAL TABLE IN PAPER ##########
# filepath = "./output_plain_repeat/2025-04-08-15-09-13_plain_repeat/"
filepath = tosavefolder
dataNameList = [name for name in os.listdir(filepath)  if "InfoDict" in name]
InfoDict_repeat = {}
Runtime_dict = {}
Separtime_dict = {}
NodeCount_dict = {}
Status_dict = {}
c_gap_dict = {}
for l in dataNameList:
    SolutionDict  = tf.load(filepath+l)[0]['SolutionDict']
    InfoDict = tf.load(filepath+l)[0]['InfoDict']
    dataOptionDict= tf.load(filepath+l)[0]['dataOptionDict']
    probSettingSet = tf.load(filepath+l)[0]['probSettingSet']
    modelReport = tf.load(filepath+l)[0]['modelReport']
    InfoDict_repeat[l] = InfoDict
    repeat_timestamp = l[44:-4]
    Runtime_dict[repeat_timestamp] = pd.concat((InfoDict[probSetting_info][1]['Runtime']
                                 for probSetting_info in probSettingSet),
                                axis=1,
                                keys=probSettingSet)
    Separtime_dict[repeat_timestamp] = pd.concat((InfoDict[probSetting_info][1]['Separtime']
                                                for probSetting_info in probSettingSet),
                                               axis=1,
                                               keys=probSettingSet)
    NodeCount_dict[repeat_timestamp] = pd.concat((InfoDict[probSetting_info][1]['NodeCount']
                                                for probSetting_info in probSettingSet),
                                               axis=1,
                                               keys=probSettingSet)
    Status_dict[repeat_timestamp] = pd.concat((InfoDict[probSetting_info][1]['Status']
                                                  for probSetting_info in probSettingSet),
                                                 axis=1,
                                                 keys=probSettingSet)
    c_gap_dict[repeat_timestamp] = pd.concat((InfoDict[probSetting_info][1]['c_gap']
                                                  for probSetting_info in probSettingSet),
                                                 axis=1,
                                                 keys=probSettingSet)
Runtime_all = pd.concat(Runtime_dict.values(), axis=1,
                        keys=Runtime_dict.keys(),
                        names=['repeat', 'size', 'alpha', 'v0', 'luce', 'kappa', 'knapsack'])
Separtime_all = pd.concat(Separtime_dict.values(), axis=1,
                        keys=Separtime_dict.keys(),
                        names=['repeat', 'size', 'alpha', 'v0', 'luce', 'kappa', 'knapsack'])
NodeCount_all = pd.concat(NodeCount_dict.values(), axis=1,
                        keys=NodeCount_dict.keys(),
                        names=['repeat', 'size', 'alpha', 'v0', 'luce', 'kappa', 'knapsack'])
Status_all =  pd.concat(Status_dict.values(), axis=1,
                        keys=Status_dict.keys(),
                        names=['repeat', 'size', 'alpha', 'v0', 'luce', 'kappa', 'knapsack'])
c_gap_all =  pd.concat(c_gap_dict.values(), axis=1,
                        keys=c_gap_dict.keys(),
                        names=['repeat', 'size', 'alpha', 'v0', 'luce', 'kappa', 'knapsack'])

timeMean = Runtime_all.T.groupby(['size', 'v0', 'luce']).mean()
timeMin  = Runtime_all.T.groupby(['size', 'v0', 'luce']).min()
timeMax = Runtime_all.T.groupby(['size', 'v0', 'luce']).max()
timeStd = Runtime_all.T.groupby(['size', 'v0', 'luce']).std()
timeSem = Runtime_all.T.groupby(['size', 'v0', 'luce']).sem()
timeSepMean = Separtime_all.T.groupby(['size', 'v0', 'luce']).mean()
nodesMean = NodeCount_all.T.groupby(['size', 'v0', 'luce']).mean()
numSolved = (Status_all==2).T.groupby(['size', 'v0', 'luce']).sum()
c_gap_mean = c_gap_all.T.groupby(['size', 'v0', 'luce']).mean()

ResultTable = {"timeMean":timeMean,
               "timeMin":timeMin,
               "timeMax":timeMax,
               "timeStd":timeStd,
               "timeSem":timeSem,
               "timeSepMean":timeSepMean,
               "nodesMean":nodesMean,
               "numSolved":numSolved,
               "c_gap_mean":c_gap_mean,
               }

FileName = './Output/ResultTable_' + time_stamp_str +'_cmpt.xlsx'
tf.writeExcel(FileName, ResultTable)
print("\n" +"="*50+"\n AggTable \nsave to "+FileName+"\n"+"="*50+"\n" )

#%% generate the final table (table 2 in paper)
FinalTable_mean = pd.concat((timeMean['MC_Conv-mo-soc-aC'],
                                 timeMean['Conic_Conic-mo'],
                                 timeMean['MILP'],), axis=1)
FinalTable_min = pd.concat((timeMin['MC_Conv-mo-soc-aC'],
                                 timeMin['Conic_Conic-mo'],
                                 timeMin['MILP'],), axis=1)
FinalTable_max = pd.concat((timeMax['MC_Conv-mo-soc-aC'],
                                 timeMax['Conic_Conic-mo'],
                                 timeMax['MILP'],), axis=1)
FinalTable_std = pd.concat((timeStd['MC_Conv-mo-soc-aC'],
                                 timeStd['Conic_Conic-mo'],
                                 timeStd['MILP'],), axis=1)
FinalTable_ndsmean = pd.concat((nodesMean['MC_Conv-mo-soc-aC'],
                                 nodesMean['Conic_Conic-mo'],
                                 nodesMean['MILP'],), axis=1)
FinalTable_slvd = pd.concat((numSolved['MC_Conv-mo-soc-aC'],
                                 numSolved['Conic_Conic-mo'],
                                 numSolved['MILP'],), axis=1)
FinalTable_spe_mean = timeSepMean.sum(axis=1)
FinalTable = pd.concat((FinalTable_mean,
                       FinalTable_min,
                       FinalTable_max,
                       FinalTable_std,
                       FinalTable_ndsmean,
                       FinalTable_slvd,
                       FinalTable_spe_mean,),
                      axis=1,
                      keys=['Mean', 'Min', 'Max', 'Std', 'Nds', '#', 'SepTimeMean'])
FinalTable.sort_index(axis=1, level=1, inplace=True)
FinalTable.sort_index(axis=0, level=2, inplace=True)
FinalTable = FinalTable.swaplevel(0,1, axis=1)

FileName = './Output/ResultTable_' + time_stamp_str +'_final.xlsx'
FinalTable.to_excel(FileName)
print("\n" +"="*50+"\n FinalTable \nsave to "+FileName+"\n"+"="*50+"\n")



