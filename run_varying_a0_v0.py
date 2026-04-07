
import os, sys
import pandas as pd

import BuildModels as bm  # BuildModels
import ToolFunctions as tf
import CompareFunc as cm

modelReport = ['MC_Conv-mo-soc-aC']

#%% obtain the parameter
timelimit = float(sys.argv[1]) # sys.argv[1] #3600.0
varying_type = sys.argv[2] # sys.argv[2] #  # "varying_v0" or "varying_a0"
# timelimit = 360.0 # sys.argv[1] #3600.0
# varying_type = "varying_v0" # sys.argv[2] #  # "v0" or "a0"


dataFolder = 'output_assortment_map/dataset/'
dataNameList = [name for name in os.listdir(dataFolder)  if varying_type in name]
filename = dataFolder + dataNameList[0]

#%% run on dataOptionDict

dataOptionDict, probSettingSet = tf.load(filename)

time_stamp_str = pd.Timestamp.now().strftime('%Y-%m-%d-%H-%M-%S')
SolutionDict = {}
InfoDict = {}
for s in range(len(dataOptionDict)):
    probSetting_info = probSettingSet[s]
    (numProd, numCust), arriveRation_off, (v0_off, v0_on), luce, (kappaOff, kappaOn), (
        knapsack_off, knapsack_on) = probSetting_info

    probName, (data, option) = dataOptionDict[probSetting_info]
    print('\n\n==============================================\n')
    print('======{}th prob with setting:'.format(s) + str(probSetting_info))
    print('\n==============================================\n\n')

    ################### specify any parameter here to contol the testing framework
    option.compute_relax_gap = 1
    option.cut_round_limit = 2
    option.model_list = tf.get_model_list(modelReport)
    option.grb_para_timelimit = timelimit

    option.MMNL = 0
    option.para_logging = 0
    option.para_write_lp = 0

    ################### specify the parameters above.

    probSetting = 'Sz{}_{}_v{}_{}_s{:.1f}_{:.1f}_c{:.1f}_{:.1f}_luce{:d}'.format(data.numProd, data.numCust,
                                                                                 int(data.value_off_0),
                                                                                 int(data.value_on_0[0]),
                                                                                 data.utilitySparsity_off,
                                                                                 data.utilitySparsity_on,
                                                                                 data.kappaOff, data.kappaOn,
                                                                                 luce)
    data.probName = data.probType + probSetting + '_%d_' % (s) + time_stamp_str

    InfoReport, Sols = cm.compareModels(data,
                                        option,
                                        variableNeed=option.variableNeed,
                                        model_list=option.model_list,
                                        enumerate_off_save=True)

    SolutionDict[probSetting_info] = data.probName, Sols
    InfoDict[probSetting_info] = data.probName, InfoReport

#%% generate the table for comparison
tosavefolder = "output_assortment_map/"
os.makedirs(tosavefolder, exist_ok=True)
SolutionDict_InfoDict = {}
SolutionDict_InfoDict["InfoDict"] = InfoDict
SolutionDict_InfoDict["SolutionDict"] = SolutionDict
SolutionDict_InfoDict["dataOptionDict"] = dataOptionDict
SolutionDict_InfoDict["probSettingSet"] = probSettingSet
SolutionDict_InfoDict["modelReport"] = modelReport
filename = tosavefolder + 'SolutionDict_InfoDict_dataOptionDict_' + varying_type
tf.save(filename, SolutionDict_InfoDict)

# tf.save(filename, dataOptionDict, probSettingSet, SolutionDict, InfoDict)
print("\n" + "="*50+"\n dataOptionDict_varying_a0 \nsave to "+filename+"\n"+"="*50 + "\n" )

# FileName = tosavefolder + 'Tables_ReportTable1_varying_a0' + time_stamp_str + '.xlsx'
# CompleteTable1 = tf.extract_report(option,
#                                    modelReport,
#                                    probSettingSet,
#                                    InfoDict,
#                                    FileName,
#                                    savereporttable=1)