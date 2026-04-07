
import os, sys

import pandas as pd
import numpy as np

import BuildModels as bm # BuildModels
import ToolFunctions as tf
import CompareFunc as cm

#%% obtain the parameter
# timelimit = float(sys.argv[1]) # sys.argv[1] #3600.0
timelimit = 600.0 # sys.argv[1] #3600.0

#%% get the data file
dataFolder = './output_customization/dataset/'
dataNameList = os.listdir(dataFolder)
dataNameList = [name for name in dataNameList  if "CustomizationCAP_dataOptionDictsparseCAPCardiOff_repeat" in name]
# dataNameList = ['CustomizationCAP_dataOptionDictsparseCAPCardiOff_repeat36_2024-09-30-03-01-16.pkl']
filename = dataFolder+dataNameList[0]
modelReport = ['MC_Conv-mo-soc-aC']
time_stamp_str = pd.Timestamp.now().strftime('%Y-%m-%d-%H-%M-%S')
tosavefolder = f"output_customization/{time_stamp_str}_compare_with_customization/"
os.makedirs(tosavefolder, exist_ok=True)

#%% run
dataOptionDict_repeat, probSettingSet, repeatNum, _modelReport = tf.load(filename)
repeatRange = range(len(dataOptionDict_repeat))
probSettingRange = range(len(probSettingSet))
# repeatRange = range(3)# range(len(dataOptionDict_repeat))
# probSettingRange = range(6)# range(len(probSettingSet))
Table_repeat = cm.RUN_WITH_SETTING(tosavefolder,
                                   filename,
                                   modelReport,
                                   roundlimit=2,
                                   timelimit=timelimit, # 3600
                                   repeatRange=repeatRange,
                                   probSettingRange=probSettingRange)

#%% get the tables
outputfolder = tosavefolder

filename_list = [outputfolder+l for l in os.listdir(outputfolder) if ".pkl" in l]
filename_list = sorted(filename_list, key = lambda x: int(x[-6:-4]) if x[-6:-4].isdigit() else int(x[-5:-4]))

probSettingSet = tf.load(filename_list[0])[0]["probSettingSet"]
S_I_D_repeat = [tf.load(l)[0] for l in filename_list]
InfoDict_repeat = [S_I_D["InfoDict"] for S_I_D in S_I_D_repeat]
data, option = S_I_D_repeat[0]["dataOptionDict"][probSettingSet[0]][1]
Table_repeat = {}
for r, InfoDict in  enumerate(InfoDict_repeat):
    CompleteTable1 = tf.extract_report(option,
                                       modelReport,
                                       probSettingSet,
                                       InfoDict,
                                       "",
                                       savereporttable=0)
    Table_repeat[r] = CompleteTable1['AggTable']

#%% statistic of runtime
RunTime_df = pd.concat([Table_repeat[r].loc[("MC_Conv-mo-soc-aC", "Runtime"),:] for r in Table_repeat.keys()], axis=1, keys=Table_repeat.keys())
RunTime_df_sta = pd.DataFrame({"time_ave": RunTime_df.mean(axis=1),
                               "time_max": RunTime_df.max(axis=1),
                               "time_min": RunTime_df.min(axis=1),
                               "time_95q": RunTime_df.quantile(0.95,axis=1),
                              "time_05q": RunTime_df.quantile(0.55,axis=1)})
n_m_k_v0on_a_luce = RunTime_df.index.to_series().apply(lambda x: pd.Series([x[0][0], x[0][1], x[0][0]*x[4][0], x[2][1], x[1], x[3]]))
n_m_k_v0on_a_luce.columns = ["n", "m", "k", "v0_on", "arrive_off", "luce"]
RunTime_df = pd.concat([n_m_k_v0on_a_luce, RunTime_df_sta, RunTime_df], axis=1)

FileName = outputfolder + 'Tables_ReportTable1_' + f'_runtime_stat{len(S_I_D_repeat)}.xlsx'
RunTime_df.to_excel(FileName, index=False)
print("\n" +"="*50+"\n runtime_statistic \nsave to "+FileName+"\n"+"="*50+"\n" )
