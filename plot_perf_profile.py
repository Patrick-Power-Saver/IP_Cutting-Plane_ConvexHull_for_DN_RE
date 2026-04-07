# -*- coding: utf-8 -*-
"""
Created on Mon Jul 17 10:41:47 2023

- plot the performance profile.
- generate the .txt file which contains the performance profile data.
- should indicate the filepath to the folder that contains the solution results

@author: wyl2020
@email:wylwork_sjtu@sjtu.edu.cn
"""

import os
import matplotlib.pyplot as plt
import seaborn as sns
import pandas as pd
import numpy as np

import ToolFunctions as tf

#%% get results
filepath = "./output_plain_repeat/plain_repeat_results/"
dataNameList = [name for name in os.listdir(filepath)  if "InfoDict" in name]
S_I_DO_repeat_dict = {}
InfoDict_repeat = {}
Runtime_dict = {}
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

#%% plot Runtim, 6 lines,  split Luce and NoLuce
time_stamp = pd.Timestamp.now()
time_stamp_str = str(time_stamp.date())+'-{:02}-{:02}-{:02}'.format(time_stamp.hour,time_stamp.minute,time_stamp.second)

Runtime_all = pd.concat(Runtime_dict.values(), axis=1, keys=Runtime_dict.keys(),
                        names=['repeat', 'size', 'alpha', 'v0', 'luce', 'kappa', 'knapsack'])
allCarriedModels= [*Runtime_all.index]
cut_round_limit = 2
Runtime_all_temp = Runtime_all.copy()
for modelName in modelReport:
    if 'aC' not in modelName:
        continue
    loc_index = tf.get_model_location(modelName, allCarriedModels)
    index_set = range(loc_index - cut_round_limit-1, loc_index+1)
    Runtime_all_temp.loc[allCarriedModels[loc_index]] = Runtime_all_temp.iloc[index_set].sum()

modelReport = ['MC_Conv-mo-soc-aC', 'Conic_Conic-mo', 'MILP']
noluce_loc = [ind for ind in Runtime_all_temp.columns if ind[4]==0]
Runtime_plot_noLuce = Runtime_all_temp.loc[modelReport, noluce_loc]
luce_loc = [ind for ind in Runtime_all_temp.columns if ind[4]==1]
Runtime_plot_Luce = Runtime_all_temp.loc[modelReport, luce_loc]


# Runtime_plot = pd.concat([Runtime_plot_noLuce, Runtime_plot_Luce], axis=1, keys=[0,1], names=['Luce'])
Runtime_plot = np.vstack([Runtime_plot_noLuce, Runtime_plot_Luce])
# Runtime_plot = Runtime_plot[[0,3],:]


fig = plt.figure()
ax_perf = fig.add_subplot(1, 1, 1)
numSolver, numInstance = Runtime_plot.shape
xticks = np.unique(Runtime_plot)
xticks = np.arange(0,3700,step=1,dtype=int)
# plotdata = pd.concat([(Runtime_plot <= tau).sum(axis=1)/numInstance for tau in xticks], axis=1)
plotdata = np.vstack([(Runtime_plot <= tau).sum(axis=1)/numInstance for tau in xticks])


np.savetxt("./Output/perf_runtime_raw_data.txt",Runtime_plot.T, delimiter=",")
tosaveplot = np.insert(plotdata, 0, xticks, axis=1)
tosaveplot = np.round(tosaveplot, decimals=4)
with open("./Output/perf_plotdate_after_transformation.txt", 'w') as file:
    file.write("Xticks	CH	Conic	MILP	CH-Chain	Conic-Chain	MILP-Chain\n")
    for row in tosaveplot[:3600,:]:
        file.write(" ".join(map(str, row)) + "\n")

np.savetxt("./Output/perf_plotdate_after_transformation.txt",tosaveplot, delimiter=",")


label = ['CH', 'Conic', 'MILP', 'CH-Chain', 'Conic-Chain', 'MILP-Chain']
# label = ['MC_Conv-SPR', 'Conic_Conic']
ax_perf.step(xticks, plotdata, where='post', label=None)
markevery0 = np.array([0,500,1000,1500,2000,2500,3000])
markevery1 = markevery0 + 100
plt.setp(ax_perf.lines[0], 
         linewidth=1, 
         dashes=[10,0], 
         dash_capstyle='round', 
         color='cyan', 
         marker='s', 
         markevery=markevery0)
plt.setp(ax_perf.lines[1], 
          linewidth=1, 
          dashes=[10,0], 
          dash_capstyle='round',  
          color='darkorange', 
          marker='o', 
          markevery=markevery0)
plt.setp(ax_perf.lines[2], 
          linewidth=1, 
          dashes=[10,0], 
          dash_capstyle='round', 
          color='darkblue',
          marker='H', 
          markevery=markevery0)

plt.setp(ax_perf.lines[3], 
          linewidth=1, 
          dashes=[0.1,2], 
          dash_capstyle='round', 
          color='darkturquoise', #olive
          marker='s',
          mfc ='none', 
          markevery=markevery1)
plt.setp(ax_perf.lines[4], 
          linewidth=1, 
          dashes=[0.1,2], 
          dash_capstyle='round',  
          color='darkorange',
          marker='o',
          mfc ='none', 
          markevery=markevery1)
plt.setp(ax_perf.lines[5], 
          linewidth=1, 
          dashes=[0.1,2], 
          dash_capstyle='round', 
          color='darkblue',
          marker='H',
          mfc ='none', 
          markevery=markevery1)

y_level = np.mean(plotdata,axis=0)[0]
plt.plot([0, 3500], [y_level, y_level], ls='-', lw=0.1)
# ax_perf.set_xscale('symlog', base=2)
ax_perf.set_xlabel(r'$\tau$')
ax_perf.set_ylabel(r'$\pi(\tau)$', fontsize=12)
ax_perf.set_xlim([xticks.min(), 3600])
# ax_perf.set_xlim([xticks.min(), 200])
plt.legend(ax_perf.lines, label, loc='lower right', bbox_to_anchor=(1, 0.1), fontsize = 6, ncol=1, handlelength=4)
# plt.title('Performance Profile on {} instances of "{}"'.format(numInstance, data.probType))
# plt.title('Performance Profile on {} instances'.format(30))
plt.tight_layout()
plt.show()

revenue_Type = 'SparseVIP'
FileName = './Output/'+revenue_Type + time_stamp_str +'_time_perf.png'
fig.savefig(FileName, dpi=600, bbox_inches = 'tight')
print("figure print to "+FileName)



