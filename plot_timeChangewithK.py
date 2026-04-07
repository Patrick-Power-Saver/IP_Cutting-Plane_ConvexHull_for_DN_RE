# -*- coding: utf-8 -*-
"""
Created on Tue Jul 30 09:18:59 2024

@author: wyl2020
"""

import os, sys
import matplotlib.pyplot as plt
import seaborn as sns
import pandas as pd
import numpy as np

import BuildModels as bmß
import ToolFunctions as tf
import CompareFunc as cm

#%% prepare data, load from the .pkl file
solution_folder = "output_different_K/2025-04-08-21-34-39_compare_different_K"
folder_list_diff_K = sorted([os.path.join(solution_folder,l) for l in os.listdir(solution_folder) if "DS_Store" not in l])
filename_dict = {}
for folder in folder_list_diff_K:
    k = int(folder[-2:]) if folder[-2:].isdigit() else int(folder[-1:])
    filename_dict[k] = sorted([os.path.join(folder,l) for l in os.listdir(folder) if ".pkl" in l])


columnsName = ['K', 'repeat', 'size',  'voff', 'von', 'choice','model', 'runtime', "c_gap", "gap"]
runtime_df = pd.DataFrame(columns = columnsName)
for k, filename_list in filename_dict.items():
    for r, filename in enumerate(filename_list):
        if r == 13 or r==18:
            print(filename_dict[k][r])
        # filename_dict[k][r]
        SolutionDict_InfoDict_dataOptionDict = tf.load(filename_dict[k][r])[0]
        InfoDict = SolutionDict_InfoDict_dataOptionDict["InfoDict"]
        for probSetingSet_info, (probNmae, tb) in (InfoDict.items()):
            size = probSetingSet_info[0]
            voff = probSetingSet_info[2][0]
            von = probSetingSet_info[2][1]
            luce = probSetingSet_info[3]
            choice = luce*'2SLM' + (1-luce) *'MNL'
            for modelName in tb["Runtime"].index:
                runtime = tb["Runtime"].loc[modelName]
                c_gap = tb["c_gap"].loc[modelName]
                gap = tb["gap"].loc[modelName]
                if runtime_df.empty:
                    runtime_df.loc[0] = [k, r, size, voff, von, choice, modelName, runtime, c_gap, gap]
                else:
                    runtime_df.loc[len(runtime_df)] = [k, r, size, voff, von, choice, modelName, runtime, c_gap, gap]

#%% prepare data
# only IP time
IP_loc = (runtime_df['model']=='MC_Conv-mo-soc-aC') | (runtime_df['model']=='MC_Conv-soc-aC')
Runtime_IP = runtime_df.loc[IP_loc]
# total time
runtime_group = runtime_df.groupby(['K', 'repeat', 'size', 'voff', 'von', 'choice'])
# Runtime_sum = runtime_group['runtime'].sum()
Runtime_sum = runtime_group['runtime'].apply(lambda x: sum(x) - x.iloc[-2])
Runtime_sum = Runtime_sum.reset_index()


ss = Runtime_sum.loc[(Runtime_sum["K"]==2)].groupby(['choice','repeat'])["runtime"].mean()
ss = runtime_df.loc[(runtime_df["K"]==2)].groupby(['repeat', 'model', 'choice'])["runtime"].mean()
ss = ss.reset_index()
print(ss.to_string())
#%% plot box chart, varying K
K_list = sorted(runtime_df["K"].unique())
size_list = sorted(runtime_df["size"].unique())


#%% plot SUM time (Cut + IP)
fig, axes = plt.subplots(1, len(size_list), figsize=(10, 6), sharey=True)
Runtime = Runtime_sum
for i, size in enumerate(size_list):
    dataplot = Runtime.loc[Runtime['size'] == size]
    dataplot = dataplot.astype({'runtime': float})
    ax = axes
    sns.boxplot(ax=ax,
                x=dataplot['K'],
                y=dataplot['runtime'],
                hue=dataplot['von'],
                hue_order=[2, 5, 10],
                palette=sns.color_palette()[:3],
                )
    ax.grid(zorder=20)
    ax.set_title('size = {}'.format(size), fontsize=18)

sns.move_legend(ax, loc = 'upper right', title=None,fontsize=16)
ax.tick_params(labelsize=14)
ax.set_ylabel("time (s)",fontsize=18)
ax.set_xlabel(r"K",fontsize=18)
ax.set_ylim([-50, 4000])
fig.suptitle(r'Time used by CH-K (Cut+IP)', fontsize=20)
fig.tight_layout()
plt.show()

fig.savefig('./Output/timeChangeWithK_compareK_SUM_by_v0.png', dpi=600)


#%% plot pure IP time
# fig, axes = plt.subplots(1, len(size_list), figsize=(10, 6), sharey=True)
# Runtime = Runtime_IP
# for i, size in enumerate(size_list):
#     dataplot = Runtime.loc[Runtime['size'] == size]
#     dataplot = dataplot.astype({'runtime': float})
#     ax = axes
#     sns.boxplot(ax=ax,
#                 x=dataplot['K'],
#                 y=dataplot['runtime'],
#                 # hue=dataplot['choice'],
#                 # hue_order=['MNL', '2SLM'],
#                 hue=dataplot['von'],
#                 hue_order=[2, 5, 10],
#                 palette=sns.color_palette()[:3],
#                 )
#     ax.grid(zorder=20)
#     ax.set_title('size = {}'.format(size), fontsize=18)
#
# sns.move_legend(ax, loc = 'upper right', title=None,fontsize=16)
# ax.tick_params(labelsize=14)
# ax.set_ylabel("time (s)",fontsize=18)
# ax.set_xlabel(r"K",fontsize=18)
# ax.set_ylim([-50, 4000])
# fig.suptitle(r'Time used by  CH-K (IP)', fontsize=20)
# fig.tight_layout()
# plt.show()
#
# # fig.savefig('./Output/timeChangeWithK_compareK_IP.png', dpi=600)
# fig.savefig('./Output/timeChangeWithK_compareK_IP_by_v0.png', dpi=600)




