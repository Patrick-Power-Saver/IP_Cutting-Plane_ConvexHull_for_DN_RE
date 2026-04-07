# -*- coding: utf-8 -*-
"""
Created on Mon Jul  3 14:20:41 2023

@author: wyl2020
@email:wylwork_sjtu@sjtu.edu.cn
"""

import os, sys

from scipy.stats import pearsonr, spearmanr, kendalltau

import matplotlib as mpl
import matplotlib.pyplot as plt
import seaborn as sns
import pylab as pl
import itertools, time, copy
import pandas as pd
import numpy as np
pd.set_option("display.max_columns", 20)
pd.set_option("display.width", 150)
import gurobipy as grb

import BuildModels as bm
import ToolFunctions as tf
import CompareFunc as cm



modelReport = ['Conic_Conic-mo', 
                'MC_Conv-mo-soc-aC',
                'MILP']
modelReport = ['MC_Conv-mo-soc-aC']
modelReport = ['MC_Conv-mo-soc-aC', 'SO_Opt']
opt_modelname = 'MC_Conv-mo-soc-aC'

model_list = tf.get_model_list(modelReport)
#%%
option = bm.Option()
option.para_randomData = 1
option.attV_Type = 'sparse' # INT, CTN, sparse ''

option.revenue_Type = 'VIP' # INT, CTN, VIP, COR_P, COR_N''
option.revenue_vip_group_number = 2 # default 2, if 1, online=offline, if 0, automatically selete the numCust
option.revenue_disc_range = [0.8,1] # default [0.9,1]
option.revenue_range = [10,20] # defaule [10,20]
option.ExtraConstrList = ['Luce'] #['CardiOff', 'CardiOn', 'Prior', 'Luce']
option.kappaOff = 0.2 # default = 0.2
option.kappaOn = 0.2 # default = 0.2
option.luceType = 'Tree' # Tree, GroupPair,
option.luceTree_nodeRatio = 0.25 # default 0.25
option.luceGroup_nodeRatio = 1 # default 0.5
option.grb_para_timelimit = 3600 #3600  100
option.arrivRatio = [0.5, 0.5]

option.read_data = 0

if 'CardiOff' in option.ExtraConstrList or 'CardiOn' in option.ExtraConstrList:
    option.cardiMC = 1

option.plot_network = 0
option.para_plot = 0
option.para_plot_save = 0
option.para_logging = 1
option.para_write_lp = 1
option.gapApproach = ['continuous'] #  nodeLimit or continuous
option.compute_relax_gap = 0

option.modelReport = modelReport
option.model_list = model_list

option.savedata_toexcel = 1
option.savereport = 1
repeatNum = 1
option.cut_round_limit = 2

useOldDataOption = 0

#%%
# numProdnumust_list = [(150,75)]
# numProdnumust_list = [(50,25)]
numProdnumust_list = [(50,10)]

v0_off_v0_on_list  = [(1,5)]
usparse_off_on_list= [(1,1)]
v_s = pd.MultiIndex.from_product([v0_off_v0_on_list, usparse_off_on_list])

probSetingSet = pd.MultiIndex.from_product([numProdnumust_list, [*v_s]])

rootnodeGap = []
if 'nodeLimit' in option.gapApproach:
    rootnodeGap.append('r_gap')
    rootnodeGap.append('ObjRoot+')
if 'continuous' in option.gapApproach:
    rootnodeGap.append('c_gap')
    rootnodeGap.append('ObjCtn+')
option.variableNeed = ['Runtime', 'Separtime', 'addConstrTime', 'ObjVal', 'ObjVal_off', 'ObjVal_on','NumAssort','NumAssort_onAvg', 'gap', 'Status'] +rootnodeGap+ [ 'e_gap', 'NumConstrs', 'NodeCount', 'R_Status', 'R_Runtime', 'ObjRoot', 'ObjCtn', 'ObjBound', 'ObjValLuce']
option.variableReport = rootnodeGap+['ObjVal', 'gap', 'Runtime', 'NumConstrs','NumAssort_onAvg', 'NodeCount', 'NumAssort', 'NumSolved', 'ObjValLuce']

#%% refined data and option, add Luce constraint
# add_Luce = 1
# if add_Luce == 1:
#     filepath = r'..'
#     a = r'\assortment_map_0721\dataOptionDict_all_sparseVIP_repeat_1_2023-07-20-23-12-51_alpha0' # revenue_disc_range 0.1
#     filename = filepath + a
#     dataOptionDict_repeat_all_old, probSetingSet, rho_list, repeatNum, modelReport= tf.load(filename)
#     dataOptionDict_repeat_all = {}
#     for r in range(repeatNum):
#         time_stamp = pd.Timestamp.now()
#         time_stamp_str = str(time_stamp.date())+'-{:02}-{:02}-{:02}'.format(time_stamp.hour,time_stamp.minute,time_stamp.second)
#         # dataOptionDict_all = {}
#         dataOptionDict_all = dataOptionDict_repeat_all_old[r]
#         for s in range(len(probSetingSet)):
#             probSetting_info = probSetingSet[s]
#             numProd, numCust = probSetting_info[0]
#             dataOptionDict = dataOptionDict_all[(numProd, numCust)]
#
#             rho_list_keys = list(dataOptionDict.keys())
#             for k in range(len(rho_list)):
#                 data, option = dataOptionDict[rho_list_keys[k]]
#                 option = tf.update_Folder(option)
#                 option.ExtraConstrList = ['Luce']
#                 data.ExtraConstrList = ['Luce']
#                 data.luceType = 'Tree'
#                 data.generate_extraCstr_data(numProd, numCust, ExtraConstrList=option.ExtraConstrList)
#
#                 dataOptionDict[rho_list_keys[k]] = [copy.copy(data), copy.copy(option)]
#
#             dataOptionDict_all[(numProd, numCust)] = dataOptionDict
#         dataOptionDict_repeat_all[r] = dataOptionDict_all
#
#
# # save dataOptionDict_repeat_all
# filename = './DataSet/dataOptionDict_all_'+data.probType + '_repeat_%d_'%repeatNum + time_stamp_str
# tf.save(filename, dataOptionDict_repeat_all, probSetingSet, rho_list, repeatNum, modelReport)
# print("\n" + "="*50+"\n dataOptionDict_repeat_all \nsave to "+filename+"\n"+"="*50 + "\n" )

#%% generate data
dataOptionDict_repeat_all = {}
for r in range(repeatNum):
    if useOldDataOption == 1:
        break
    time_stamp = pd.Timestamp.now()
    time_stamp_str = str(time_stamp.date())+'-{:02}-{:02}-{:02}'.format(time_stamp.hour,time_stamp.minute,time_stamp.second)
    
    dataOptionDict_all = {}
    for s in range(len(probSetingSet)):
        probSetting_info = probSetingSet[s]
        numProd, numCust = probSetting_info[0]
        option.v0_off, option.v0_on = probSetting_info[1][0]
        option.utilitySparsity_off, option.utilitySparsity_on = probSetting_info[1][1]
        
        print('\n\n==============================================\n')
        print('======{}th prob with setting:'.format(s)+str(probSetting_info))
        print('\n==============================================\n\n')
        
        dataOptionDict = {}
        
        # rho_list = [0]
        
        # arrive ratio
        rho_list = [(0.01, 0.99), (0.1, 0.9), (0.3, 0.7), (0.5, 0.5), (0.7, 0.3), (0.9, 0.1), (0.99, 0.01)]
        
        rho_list_noluce = [(np.round(p,2), np.round(1-p, 2), 0 ) for p in np.arange(0.05,1.0,0.05)]
        rho_list_noluce.insert(0, (0.01, 0.99, 0))
        rho_list_noluce.append((0.99, 0.01, 0))
        
        rho_list_luce   = [(np.round(p,2), np.round(1-p, 2), 1 ) for p in np.arange(0.05,1.0,0.05)]
        rho_list_luce.insert(0, (0.01, 0.99, 1))
        rho_list_luce.append((0.99, 0.01, 1))
        
        rho_list = rho_list_noluce + rho_list_luce
        varyon = 'alpha0'
        # rho_list = [(0.01, 0.99), (0.5, 0.5), (0.99, 0.01)]
        
        # cardi
        # rho_list=[0.1, 0.25, 0.5]
        # rho_list = [0.1]
        # rho_list = [0.2]
        
        # v0
        rho_list = [(1,2), (1,5), (1,10), (1,20), (5,2), (5,5), (5,10), (5,20), (10,2), (10,5), (10,10), (10,20),(20,2), (20,5), (20,10), (20,20)] # V0
        rho_list = [(1,2,0), (1,5,0), (1,10,0), (1,2,1), (1,5,1), (1,10,1)] # V0
        rho_list_noluce = [(1, v, 0) for v in np.arange(1,21,1)] # V0
        rho_list_luce   = [(1, v, 1) for v in np.arange(1,21,1)] # V0
        rho_list = rho_list_noluce + rho_list_luce
        varyon = 'v0'
        
        # discount
        # rho_list = [(1,2), (1,5), (1,10), (1,20), (5,2), (5,5), (5,10), (5,20), (10,2), (10,5), (10,10), (10,20),(20,2), (20,5), (20,10), (20,20)] # V0
        # rho_list = [(1,2,0), (1,5,0), (1,10,0), (1,2,1), (1,5,1), (1,10,1)] # V0
        # rho_list = [(1,v,0) for v in np.arange(1,21,1)] # V0
        # varyon = 'discount'
        
        
        data = bm.Data(option, problemScale=(numProd, numCust))
            
        for k in range(len(rho_list)):
            
            # arrive ratio
            if varyon == 'alpha0':
                data.arrivRatio = rho_list[k]
                
            # v0
            if varyon == 'v0':
                v0 =  rho_list[k][:2]#(1,2) # (1,1) 
                option.v0_off, option.v0_on = v0
                data.value_off_0 = option.v0_off
                data.value_on_0 = np.ones(data.numCust) * option.v0_on
                
            if rho_list[k][2] > 0:
                data.ExtraConstrList = ['Luce']
            else:
                data.ExtraConstrList = ['']
                
            probSetting = 'Sz{}_{}_v{}_{}_s{:.1f}_{:.1f}_c{:.1f}_{:.1f}_luce{:d}'.format(data.numProd, data.numCust, 
                                                                int(data.value_off_0), int(data.value_on_0[0]),
                                                                data.utilitySparsity_off, data.utilitySparsity_on,
                                                                data.kappaOff, data.kappaOn, rho_list[k][2])
            data.probName = data.probType+ '_r%d_'%(r) + probSetting + '_%d_'%(k)+ time_stamp_str
            # if option.savedata_toexcel == 1 :
            #     tf.saveData_toExcel(data)
            dataOptionDict[data.probName] = [copy.copy(data), copy.copy(option)]
        dataOptionDict_all[(numProd, numCust)] = dataOptionDict
    dataOptionDict_repeat_all[r] = dataOptionDict_all
        

# save dataOptionDict_repeat_all
filename = './DataSet/dataOptionDict_all_'+data.probType + '_repeat_%d_'%repeatNum + time_stamp_str
tf.save(filename, dataOptionDict_repeat_all, probSetingSet, rho_list, repeatNum, modelReport)   
print("\n" + "="*50+"\n dataOptionDict_repeat_all \nsave to "+filename+"\n"+"="*50 + "\n" )

# %% load dataOptionDict_repeat_all file
if useOldDataOption == 1:
    dataFolder = './DataSet/'
    dataNameList = os.listdir(dataFolder)
    dataNameList = [name for name in dataNameList  if "dataOption" in name]
    dataNameList = ['dataOptionDict_allsparseVIP_repeat2_2023-07-03-19-29-51']
    filename = dataFolder+dataNameList[0]
    dataOptionDict_repeat_all, probSetingSet, rho_list, repeatNum, modelReport =  tf.load(filename)
    print("\n" + "*"*50+"\n dataOptionDict_repeat_all \nloaded from "+filename+"\n"+"*"*50 + "\n" )
    
    modelReport =  ['MC_Conv-soc-aC', 'SO_Opt']

#%% run for given data and option

Table_repeat = {}
SolutionDict_InfoDict_dataOptionDict_repeat = {}
luce_info = {}
# repeatNum = 1
for r in range(repeatNum):
    time_stamp = pd.Timestamp.now()
    time_stamp_str = str(time_stamp.date())+'-{:02}-{:02}-{:02}'.format(time_stamp.hour,time_stamp.minute,time_stamp.second)
    
    SolutionDict_all = {}
    InfoDict_all = {}
    dataOptionDict_all = dataOptionDict_repeat_all[r]
    for s in range(len(probSetingSet)):
        probSetting_info = probSetingSet[s]
        numProd, numCust = probSetting_info[0]
        dataOptionDict = dataOptionDict_all[(numProd, numCust)]
        
        print('\n\n==============================================\n')
        print('======{}th prob with setting:'.format(s)+str(probSetting_info))
        print('\n==============================================\n\n')
        
        SolutionDict = {}
        InfoDict = {}
        
        # rho_list = [0]
        
        # arrive ratio
        # rho_list = [(0.01, 0.99), (0.1, 0.9), (0.3, 0.7), (0.9, 0.1), (0.99, 0.01)]
        
        # cardi
        # rho_list=[0.1, 0.25, 0.5]
        # rho_list = [0.1]
        # rho_list = [0.2]
        
        # v0
        # rho_list = [(1,2), (1,5), (1,10), (1,20), (5,2), (5,5), (5,10), (5,20), (10,2), (10,5), (10,10), (10,20),(20,2), (20,5), (20,10), (20,20)] # V0
        # rho_list = [(1,2,0), (1,5,0), (1,10,0), (1,2,1), (1,5,1), (1,10,1)] # V0
        # luce_info['{}_r{}'.format(probSetting_info, r)] = data.luce_info.mean()
        
        rho_list_keys = list(dataOptionDict.keys())
        for k in range(len(rho_list)):
            # get data and option
            data, option = dataOptionDict[rho_list_keys[k]]
            # reset data
            # data.ExtraConstrList = ['Luce']
            # luceconstr = 1
            
            # reset option
            
            probSetting = 'Sz{}_{}_v{}_{}_s{:.1f}_{:.1f}_c{:.1f}_{:.1f}_luce{:d}'.format(data.numProd, data.numCust, 
                                                                int(data.value_off_0), int(data.value_on_0[0]),
                                                                data.utilitySparsity_off, data.utilitySparsity_on,
                                                                data.kappaOff, data.kappaOn, rho_list[k][2])
            data.probName = data.probType+ '_r%d_'%(r) + probSetting + '_%d_'%(k)+ time_stamp_str
            # if option.savedata_toexcel == 1 :
            #     tf.saveData_toExcel(data)
            InfoReport, inst = cm.compareModels(data,
                                                option,
                                                variableNeed=option.variableNeed,
                                                model_list=model_list)
            
            SolutionDict[data.probName] = copy.copy(inst.Sols)
            InfoDict[data.probName] = copy.copy(InfoReport)
        
        SolutionDict_all[probSetting_info] = SolutionDict
        InfoDict_all[probSetting_info] = InfoDict
    
    # save the results and dataOption
    SolutionDict_InfoDict_dataOptionDict_repeat[r] = SolutionDict_all, InfoDict_all, dataOptionDict_all
    filename = './DataSet/InfoDict_dataOptionDict_repeat_'+data.probType + '_%d_'%r + time_stamp_str
    tf.save(filename, SolutionDict_InfoDict_dataOptionDict_repeat, probSetingSet, rho_list, repeatNum, modelReport)   
    print("\n" + "="*50+"\n SolutionDict_InfoDict_dataOptionDict_repeat \nsave to "+filename+"\n"+"="*50 + "\n" )
    
    if option.read_data == 1:
        FileName = dataFolder+data.probType + time_stamp_str  + '_%d_'%r + ''.join(option.ExtraConstrList) +'.xlsx'
    else:
        FileName = './Output/Tables_ReportTable1_'+data.probType + time_stamp_str  + '_%d_'%r + ''.join(option.ExtraConstrList) +'.xlsx'
    
    CompleteTable1 = tf.extract_report(option, 
                                       option.variableNeed, 
                                       option.variableReport, 
                                       modelReport, 
                                       probSetingSet, 
                                       rho_list, 
                                       InfoDict_all, 
                                       FileName, 
                                       savereporttable=option.savereport)
    Table_repeat[r] = CompleteTable1['AggTable']

if repeatNum > 1:
    AGGTABLE = sum(Table_repeat.values())/repeatNum  # take average
    idx = pd.IndexSlice
    AGGTABLE.loc[idx[:, 'NumSolved'],:] =  sum(Table_repeat.values()).loc[idx[:, 'NumSolved'],:]
    Table_repeat['AGGTABLE'] = AGGTABLE
    if option.read_data == 1:
        FileName = dataFolder+data.probType + time_stamp_str +'_cmpt.xlsx'
    else:
        FileName = './Output/Tables_ReportTable1_'+data.probType + time_stamp_str +'_cmpt.xlsx'
    tf.writeExcel(FileName, Table_repeat)
    print("\n" +"="*50+"\n AggTable \nsave to "+FileName+"\n"+"="*50+"\n" )


#%%
time_stamp = pd.Timestamp.now()
time_stamp_str = str(time_stamp.date())+'-{:02}-{:02}-{:02}'.format(time_stamp.hour,time_stamp.minute,time_stamp.second)


# filepath = r'.\DataSet'
# # # a = r'\InfoDict_dataOptionDict_repeat_sparseVIP_1_2023-07-04-02-09-35'
# # a = r'\InfoDict_dataOptionDict_repeat_sparseVIP_0_2023-07-07-01-53-49' # 
# # a = r'\InfoDict_dataOptionDict_repeat_sparseVIP_0_2023-07-07-16-11-09' #

# a = r'\assortment_map_0721\InfoDict_dataOptionDict_repeat_sparseVIP_0_2023-07-20-23-12-51_alpha0' # 
# a = r'\assortment_map_0721\InfoDict_dataOptionDict_repeat_sparseVIP_0_2023-07-21-12-01-34_alpha0Luce' # 
# varyon = 'arrivalratio'

# a = r'\assortment_map_0721\InfoDict_dataOptionDict_repeat_sparseVIP_0_2023-07-21-00-30-29_v0' # 
# varyon = 'v0'

# filename = filepath+a
# SolutionDict_InfoDict_dataOptionDict_repeat_1, probSetingSet, rho_list, repeatNum, modelReport = tf.load(filename)
# print("\n" + "*"*50+"\n SolutionDict_InfoDict_dataOptionDict_repeat \nloaded from "+filename+"\n"+"*"*50 + "\n" )
# S_I_DO_repeat = SolutionDict_InfoDict_dataOptionDict_repeat_1
# numProdnumust_list = probSetingSet.get_level_values(0)

S_I_DO_repeat = SolutionDict_InfoDict_dataOptionDict_repeat



#%%
