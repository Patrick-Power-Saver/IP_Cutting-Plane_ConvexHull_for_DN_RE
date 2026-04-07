# -*- coding: utf-8 -*-
"""
Created on Wed Jul 17 10:35:30 2024

@author: wyl2020
"""

# -*- coding: utf-8 -*-
"""
Created on Wed Mar  8 18:45:51 2023

plot for batch instnces
to illustrate the objective value of relaxed model and that after adding cutting planes


@author: wyl2020
@email:wylwork_sjtu@sjtu.edu.cn
"""

import os, sys
# cpy  = os.path.abspath(__file__)
# cwd = os.path.abspath(os.path.join(cpy, "../"))
# os.chdir(cwd)
# sys.path.append(cwd)

from scipy.stats import pearsonr, spearmanr, kendalltau

import matplotlib.pyplot as plt
import seaborn as sns
import pandas as pd
import numpy as np
pd.set_option("display.max_columns", 20)
pd.set_option("display.width", 150)
import gurobipy as grb

import BuildModels as bm
import ToolFunctions as tf
import CompareFunc as cm


#%% get plotting data from the result
solution_folder = "output_different_K/2025-04-08-21-34-39_compare_different_K/roundlimit_5"
filename_list = [os.path.join(solution_folder,l) for l in os.listdir(solution_folder)  if ".pkl" in l]


columnsName = ['K', 'repeat', 'size',  'voff', 'von', 'choice','round', 'obj', 'runtime']
obj_df = pd.DataFrame(columns = columnsName)
K=5
for r, filename in enumerate(filename_list):
    SolutionDict_InfoDict_dataOptionDict = tf.load(filename)[0]
    InfoDict = SolutionDict_InfoDict_dataOptionDict["InfoDict"]
    for probSetingSet_info, (probNmae, tb) in (InfoDict.items()):
        size = probSetingSet_info[0]
        voff = probSetingSet_info[2][0]
        von = probSetingSet_info[2][1]
        luce = probSetingSet_info[3]
        choice = luce * '2SLM' + (1 - luce) * 'MNL'
        for ind in range(len(tb)):
            objVal =  tb["ObjVal"].iloc[ind]
            runtime = tb["Runtime"].iloc[ind]

            if ind == K+1:
                ch_k = f"CH-{K}(IP)"
            else:
                ch_k = f"CH-{ind}"
            if obj_df.empty:
                obj_df.loc[0] = [K, r, size, voff, von, choice, ch_k, objVal, runtime]
            else:
                obj_df.loc[len(obj_df)] = [K, r, size, voff, von, choice, ch_k, objVal, runtime]
# xticks = ['CH-{:}'.format(cut_number) for cut_number in range(cut_round_limit+1)]
#%%
obj_df_gr = obj_df.groupby(['K', 'repeat', 'size',  'voff', 'von', 'choice'])

obj_df["obj_first"] = obj_df_gr["obj"].transform("first")
obj_df["obj_last"] = obj_df_gr["obj"].transform("last")
obj_df["gap"] =  (obj_df["obj_first"] - obj_df["obj"]) / (obj_df["obj_first"] - obj_df["obj_last"]) * 100
obj_df.loc[obj_df["gap"]>100, "gap"] =  100



#%% plot
fig, axes = plt.subplots(1, 1, figsize=(10, 7), sharey=True)
obj_cuts_df = obj_df.loc[(obj_df["round"] !="CH-0") &
                        (obj_df["round"] !="CH-6") &
                        (obj_df["round"] !="CH-7") &
                        (obj_df["round"] !="CH-8") &
                        (obj_df["round"] !="CH-9") &
                        (obj_df["round"] !="CH-10") &
                        (obj_df["round"] !=f"CH-{K}(IP)")  ]
# obj_cuts_df = obj_df

dataplot = obj_cuts_df
ax = axes
sns.boxplot(ax=ax,
                # data=dataplot,
                x=dataplot['round'],
                y=dataplot['gap'],
                # hue=dataplot['choice'],
                # hue_order = ['MNL', '2SLM'],
                hue=dataplot['von'],
                hue_order=[2, 5, 10],
                palette=sns.color_palette()[:3],
                )
ax.tick_params(labelsize=14)
ax.set_ylim([75, 100])

# Customize the x-ticks
plt.xticks(ticks=[0, 1, 2, 3, 4], labels=[1, 2, 3, 4, 5], rotation=0)

sns.move_legend(ax, loc = 'center right', title=None,fontsize=18, title_fontsize=18)
ax.grid(zorder=20,alpha=0.3)
ax.set_ylabel(r"$gap_{\text{reduced}}\ (\%)$",fontsize=18)
ax.set_xlabel("round number",fontsize=18)
# ax.set_ylim([80, 100])
fig.suptitle('Gap reduced by number of cutting rounds in Algo. 2.', fontsize=24)
fig.tight_layout()
plt.show()


# fig.savefig('./Output/gapReducedChangeWithK_compareK_1-5.png', dpi=600)
fig.savefig('./Output/gapReducedChangeWithK_compareK_1-5_by_v0.png', dpi=600)

