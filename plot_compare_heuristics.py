#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Created on Mon Aug 26 21:27:55 2024

@author: ylw

plot figures for comparing the revenue-ordered policies: 
    SO-RO_off: Sequential Optimization that first get the Revenue-Ordered assortment fot the offline, 
        and then get the Revenue-Ordered assortment under the offline assortment.
    SO-enumerate_off: Sequential Optimization but different from SO-RO_off. 
        This policy enumerates the revenue-ordered assortment for offline, as well as gets the corresponding revennue-ordered online assortments for each revenue-ordered offline assortment.
    
"""


import os, sys
from scipy.stats import pearsonr, spearmanr, kendalltau

import matplotlib.pyplot as plt
import seaborn as sns
import pylab as pl
import itertools, time, copy
import pandas as pd
import numpy as np
pd.set_option("display.max_columns", 20)
pd.set_option("display.width", 150)

import BuildModels as bm
import ToolFunctions as tf
import CompareFunc as cm

#%% On single instance
# get data by loading .jk file
datafolder = "output_compare_heuristics_SO/"
filename_list = [filename for filename in os.listdir(datafolder) if "revenue_of_enumerate_off_enumerate_on" in filename]
numInst = len(filename_list)
for fileid in range(numInst):
    # fileid =  1
    filename = datafolder + filename_list[fileid]
    # filename = datafolder+"revenue_of_enumerate_offsparseVIPLuce_r0_Sz100_50_v1_2_s1.0_1.0_c1.0_1.0_luce0_0_2024-09-09-00-14-20.pkl"
    data, revenue_off_list, revenue_on_list, InfoReport = tf.load(filename)
    revenue_total_list = np.array(revenue_off_list) + np.array(revenue_on_list)
    optimal_obj = InfoReport.loc["MC_Conv-mo-soc-aC", "ObjVal"]
    max_total_loc = np.argmax(revenue_total_list)
    max_off_loc = np.argmax(revenue_off_list)
    max_on_loc = np.argmax(revenue_on_list)


    fig = plt.figure()
    ax = fig.add_subplot(1, 1, 1)
    plt.axhline(y=optimal_obj, label = "optimal", ls=":")
    sns.lineplot(revenue_total_list, label = "total", ls = "-")
    sns.lineplot(revenue_off_list, label = "offline", ls = "-.")
    sns.lineplot(revenue_on_list, label = "online", ls = "--")
    ax.annotate('offline maximum', xy=(max_off_loc, revenue_off_list[max_off_loc]),
                xytext = (max_off_loc, revenue_off_list[max_off_loc]+1), arrowprops=dict(arrowstyle="->", color="black"), fontsize=12)
    ax.scatter(max_off_loc, revenue_off_list[max_off_loc],
               color='blue', marker="*", s = 50, zorder=10,
               label = "# = {}".format(max_off_loc))


    plt.legend(loc='lower right', bbox_to_anchor=(1, 0.1))
    ax.set_xlabel("k")
    ax.set_ylabel("expected revenue")
    plt.title('Revenue changes under the Enum-2SRO policy without 2SLM.', fontsize="12")
    plt.show()
#%%
# fig.savefig('./Output/enum_2SRO_line_singleinstance', dpi=600, bbox_inches = 'tight')

#%% plot on single, with zoom

datafolder = "output_compare_heuristics_SO/"
filename_list = sorted([filename for filename in os.listdir(datafolder)
                 if "revenue_of_enumerate_off-" in filename
                        and "luce0" in filename])
numInst = len(filename_list)
# for fileid in range(numInst):
fileid =  0
filename0 = datafolder + filename_list[fileid]

from mpl_toolkits.axes_grid1.inset_locator import zoomed_inset_axes, mark_inset
fig, axes = plt.subplots(1, 1, figsize=(12, 6))

# ----------------- 2SRO-1 without 2SLM ----------------
filename = filename0
data, revenue_off_list, revenue_on_list, InfoReport = tf.load(filename)
revenue_total_list = np.array(revenue_off_list) + np.array(revenue_on_list)
optimal_obj = InfoReport.loc["MC_Conv-mo-soc-aC", "ObjVal"]
max_total_loc = np.argmax(revenue_total_list)
max_off_loc = np.argmax(revenue_off_list)
max_on_loc = np.argmax(revenue_on_list)

ax = axes[0]
ax.axhline(y=optimal_obj, label = "optimal", ls=":")
sns.lineplot(ax=ax, y=revenue_total_list, x=range(len(revenue_total_list)), label = "total", ls = "-")
sns.lineplot(ax=ax, y=revenue_off_list, x=range(len(revenue_total_list)), label = "offline", ls = "-.")
sns.lineplot(ax=ax, y=revenue_on_list, x=range(len(revenue_total_list)), label = "online", ls = "--")
ax.annotate(f'offline maximum k={max_off_loc}', xy=(max_off_loc, revenue_off_list[max_off_loc]),
            xytext = (max_off_loc, revenue_off_list[max_off_loc]+1), arrowprops=dict(arrowstyle="->", color="black"), fontsize=12)
ax.scatter(max_off_loc, revenue_off_list[max_off_loc],
           color='blue', marker="*", s = 50, zorder=10,
           # label = "# = {}".format(max_off_loc),
            )
ax.legend(loc='lower right', bbox_to_anchor=(1, 0.1))
ax.set_xlabel("k", fontsize=14)
ax.set_ylabel("Revenue", fontsize=14)
ax.set_title('2SRO-1 without 2SLM', fontsize=14)
ax.tick_params(axis='x', labelsize=12)
ax.tick_params(axis='y', labelsize=12)

axins1 = zoomed_inset_axes(ax,
                    zoom=4,
                    # width="40%", height="40%",
                    bbox_to_anchor=(0.5, 0.3),
                    # bbox_transform=fig.transFigure,
                    bbox_transform=ax.transAxes,
                    loc='upper center',
                           )

axins1.axhline(y=optimal_obj, label = "optimal", ls=":")
axins1.plot(revenue_total_list, label = "total", ls = "-")
axins1.set_xlim(max_total_loc-5, max_total_loc+3)
axins1.set_ylim(optimal_obj-0.3, optimal_obj+0.1)
axins1.set_xticks([])
axins1.set_yticks([])

mark_inset(ax, axins1, loc1=2, loc2=4, fc="none", ec="0.5")



# # ----------------- 2SRO-1 with 2SLM ----------------
# parts = filename0.split("_")
# # parts[-11] = "off_enumerate_on-sparseVIPLuceSz100"
# parts[-3] = "luce1"
# parts[-2] = str(int(parts[-2]) +3)
# filename = "_".join(parts)
#
# data, revenue_off_list, revenue_on_list, InfoReport = tf.load(filename)
# revenue_total_list = np.array(revenue_off_list) + np.array(revenue_on_list)
# optimal_obj = InfoReport.loc["MC_Conv-mo-soc-aC", "ObjVal"]
# max_total_loc = np.argmax(revenue_total_list)
# max_off_loc = np.argmax(revenue_off_list)
# max_on_loc = np.argmax(revenue_on_list)
#
# ax = axes[1]
# ax.axhline(y=optimal_obj, label = "optimal", ls=":")
# sns.lineplot(ax=ax, y=revenue_total_list, x=range(len(revenue_total_list)), label = "total", ls = "-")
# sns.lineplot(ax=ax, y=revenue_off_list, x=range(len(revenue_total_list)), label = "offline", ls = "-.")
# sns.lineplot(ax=ax, y=revenue_on_list, x=range(len(revenue_total_list)), label = "online", ls = "--")
# ax.annotate(f'offline maximum k={max_off_loc}', xy=(max_off_loc, revenue_off_list[max_off_loc]),
#             xytext = (max_off_loc, revenue_off_list[max_off_loc]+1), arrowprops=dict(arrowstyle="->", color="black"), fontsize=12)
# ax.scatter(max_off_loc, revenue_off_list[max_off_loc],
#            color='blue', marker="*", s = 50, zorder=10,
#            # label = "# = {}".format(max_off_loc),
#             )
# ax.legend(loc='lower right', bbox_to_anchor=(1, 0.1))
# ax.set_xlabel("k", fontsize=14)
# ax.set_ylabel("Revenue", fontsize=14)
# ax.set_title('2SRO-1 with 2SLM', fontsize=14)
# ax.tick_params(axis='x', labelsize=12)
# ax.tick_params(axis='y', labelsize=12)
#
# axins1 = zoomed_inset_axes(ax,
#                     zoom=4,
#                     # width="40%", height="40%",
#                     bbox_to_anchor=(0.5, 0.3),
#                     # bbox_transform=fig.transFigure,
#                     bbox_transform=ax.transAxes,
#                     loc='upper center',
#                            )
#
# axins1.axhline(y=optimal_obj, label = "optimal", ls=":")
# axins1.plot(revenue_total_list, label = "total", ls = "-")
# axins1.set_xlim(max_total_loc-5, max_total_loc+3)
# axins1.set_ylim(optimal_obj-0.3, optimal_obj+0.1)
# axins1.set_xticks([])
# axins1.set_yticks([])
#
# mark_inset(ax, axins1, loc1=2, loc2=4, fc="none", ec="0.5")


# ----------------- 2SRO-2 with 2SLM ----------------
parts = filename0.split("_")
parts[-11] = "off_enumerate_on-sparseVIPLuceSz100"
parts[-3] = "luce1"
parts[-2] = str(int(parts[-2]) +3)
filename = "_".join(parts)

data, revenue_off_list, revenue_on_list, InfoReport = tf.load(filename)
revenue_total_list = np.array(revenue_off_list) + np.array(revenue_on_list)
optimal_obj = InfoReport.loc["MC_Conv-mo-soc-aC", "ObjVal"]
max_total_loc = np.argmax(revenue_total_list)
max_off_loc = np.argmax(revenue_off_list)
max_on_loc = np.argmax(revenue_on_list)

ax = axes[-1]
ax.axhline(y=optimal_obj, label = "optimal", ls=":")
sns.lineplot(ax=ax, y=revenue_total_list, x=range(len(revenue_total_list)), label = "total", ls = "-")
sns.lineplot(ax=ax, y=revenue_off_list, x=range(len(revenue_total_list)), label = "offline", ls = "-.")
sns.lineplot(ax=ax, y=revenue_on_list, x=range(len(revenue_total_list)), label = "online", ls = "--")
ax.annotate(f'offline maximum k={max_off_loc}', xy=(max_off_loc, revenue_off_list[max_off_loc]),
            xytext = (max_off_loc, revenue_off_list[max_off_loc]+1), arrowprops=dict(arrowstyle="->", color="black"), fontsize=12)
ax.scatter(max_off_loc, revenue_off_list[max_off_loc],
           color='blue', marker="*", s = 50, zorder=10,
           # label = "# = {}".format(max_off_loc),
            )
ax.legend(loc='lower right', bbox_to_anchor=(1, 0.1))
ax.set_xlabel("k", fontsize=14)
ax.set_ylabel("Revenue", fontsize=14)
ax.set_title('2SRO-2 with 2SLM', fontsize=14)
ax.tick_params(axis='x', labelsize=12)
ax.tick_params(axis='y', labelsize=12)

axins1 = zoomed_inset_axes(ax,
                    zoom=4,
                    # width="40%", height="40%",
                    bbox_to_anchor=(0.5, 0.3),
                    # bbox_transform=fig.transFigure,
                    bbox_transform=ax.transAxes,
                    loc='upper center',
                           )

axins1.axhline(y=optimal_obj, label = "optimal", ls=":")
axins1.plot(revenue_total_list, label = "total", ls = "-")
axins1.set_xlim(max_total_loc-5, max_total_loc+3)
axins1.set_ylim(optimal_obj-0.3, optimal_obj+0.1)
axins1.set_xticks([])
axins1.set_yticks([])

mark_inset(ax, axins1, loc1=2, loc2=4, fc="none", ec="0.5")


# plt.title('Revenue changes under the Enum-2SRO policy without 2SLM.', fontsize="12")
# plt.tight_layout()
plt.show()

#%%  save to local disk
fig.savefig('./Output/objChange_zoom_single_instance.png', dpi=600)

#%% On multi instances, plot lines and errorbar
def obtain_revenue_data(size_list=[100], v0_on_list=[10], luce_list=[0]):
    datafolder = "output_compare_heuristics_SO/"
    filename_list = [filename for filename in os.listdir(datafolder) if "revenue_of_enumerate_off" in filename]
    revenue_off_df = pd.DataFrame()
    revenue_on_df = pd.DataFrame()
    optimal_obj_df = pd.DataFrame()

    numInst = len(filename_list)
    for fileid in range(numInst) :
        filename = datafolder + filename_list[fileid]
        # if "revenue_of_enumerate_off_enumerate_on" not in filename:
        if "revenue_of_enumerate_off" not in filename:
            continue
        data, revenue_off_list, revenue_on_list, InfoReport = tf.load(filename)
        if (data.numProd not in size_list) | (int(filename[-52:-50].split("_")[-1]) not in v0_on_list) | (int(filename[-27:-26]) not in luce_list):
            continue
        revenue_off_df[fileid] = revenue_off_list
        revenue_on_df[fileid] = revenue_on_list
        optimal_obj_df[fileid] = [InfoReport.loc["MC_Conv-mo-soc-aC", "ObjVal"]] * len(revenue_off_list)

    revenue_total_df = revenue_off_df + revenue_on_df
    revenue_total_df = revenue_total_df.stack().reset_index()
    revenue_total_df.columns = ["k", "FileID", "Revenue"]

    revenue_off_df = revenue_off_df.stack().reset_index()
    revenue_off_df.columns = ["k", "FileID", "Revenue"]

    revenue_on_df = revenue_on_df.stack().reset_index()
    revenue_on_df.columns = ["k", "FileID", "Revenue"]

    optimal_obj_df = optimal_obj_df.stack().reset_index()
    optimal_obj_df.columns = ["k", "FileID", "Revenue"]
    return revenue_total_df, revenue_off_df, revenue_on_df, optimal_obj_df


# size_list = [(100,50), (150,75), (200,100)]
size_list = [(100,50)]
# fig, axes = plt.subplots(1, 3, figsize=(15, 5), sharey=True)
fig, axes = plt.subplots(1, len(size_list), figsize=(7*len(size_list), 5), sharey=True)
# fig = plt.figure()
# axes = fig.add_subplot(1, 3, 1, sharey=True)
for i, (numProd, numCust) in enumerate(size_list):
    revenue_total_df, revenue_off_df, revenue_on_df, optimal_obj_df = obtain_revenue_data(size_list=[numProd],
                                                                                          v0_on_list=[1, 5, 10],
                                                                                          luce_list=[0])
    ax = axes if len(size_list) == 1 else axes[i]
    sns.lineplot(ax=ax, data=optimal_obj_df, x="k", y="Revenue", errorbar="sd", label="optimal")
    sns.lineplot(ax=ax, data=revenue_total_df, x="k", y="Revenue", errorbar='sd', label="total")
    sns.lineplot(ax=ax, data=revenue_off_df, x="k", y="Revenue", errorbar='sd', label="offline")
    sns.lineplot(ax=ax, data=revenue_on_df, x="k", y="Revenue", errorbar='sd', label="online")
    # plt.xlim([0, len(revenue_total_df["k"].unique())])
    ax.set_title('size = {}'.format((numProd, numCust)))
    ax.get_legend().remove()
ax.legend(bbox_to_anchor=(1, 0.2), loc='right', ncol=1)
fig.suptitle("Revenue changes under the 2SRO-1 policy without 2SLM." , fontsize=16)
fig.tight_layout()
plt.show()
#%% save to local disk
# fig.savefig('./Output/enum_2SRO_line_multiinstances.png', dpi=600, bbox_inches = 'tight')


#%% obtain the Objective from the result
def obtain_ObjVal(dataNameList, foldername):
    InfoDict_repeat = {}
    ObjVal_dict = {}
    Runtime_dict = {}
    Separtime_dict = {}
    NodeCount_dict = {}
    Status_dict = {}
    c_gap_dict = {}
    for l in dataNameList:
        SolutionDict = tf.load(foldername + l)[0]['SolutionDict']
        InfoDict = tf.load(foldername + l)[0]['InfoDict']
        dataOptionDict = tf.load(foldername + l)[0]['dataOptionDict']
        probSettingSet = tf.load(foldername + l)[0]['probSettingSet']
        modelReport = tf.load(foldername + l)[0]['modelReport']
        InfoDict_repeat[l] = InfoDict
        repeat_timestamp = l[44:-4]
        ObjVal_dict[repeat_timestamp] = pd.concat((InfoDict[probSetting_info][1]['ObjVal']
                                                    for probSetting_info in probSettingSet),
                                                   axis=1,
                                                   keys=probSettingSet)
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
    ObjVal_all = pd.concat(ObjVal_dict.values(), axis=1,
                            keys=Runtime_dict.keys(),
                            names=['repeat', 'size', 'alpha', 'v0', 'luce', 'kappa', 'knapsack'])
    Runtime_all = pd.concat(Runtime_dict.values(), axis=1,
                            keys=Runtime_dict.keys(),
                            names=['repeat', 'size', 'alpha', 'v0', 'luce', 'kappa', 'knapsack'])
    Separtime_all = pd.concat(Separtime_dict.values(), axis=1,
                              keys=Separtime_dict.keys(),
                              names=['repeat', 'size', 'alpha', 'v0', 'luce', 'kappa', 'knapsack'])
    NodeCount_all = pd.concat(NodeCount_dict.values(), axis=1,
                              keys=NodeCount_dict.keys(),
                              names=['repeat', 'size', 'alpha', 'v0', 'luce', 'kappa', 'knapsack'])
    Status_all = pd.concat(Status_dict.values(), axis=1,
                           keys=Status_dict.keys(),
                           names=['repeat', 'size', 'alpha', 'v0', 'luce', 'kappa', 'knapsack'])
    c_gap_all = pd.concat(c_gap_dict.values(), axis=1,
                          keys=c_gap_dict.keys(),
                          names=['repeat', 'size', 'alpha', 'v0', 'luce', 'kappa', 'knapsack'])
    return ObjVal_all, Runtime_all

# foldername = "output_compare_heuristics_SO/repeat_results_on_100_50/"
foldername = "output_compare_heuristics_SO/repeat_results_on_small/"
dataNameList = [name for name in os.listdir(foldername)  if "InfoDict" in name]

ObjVal_all_raw, Runtime_all_raw = obtain_ObjVal(dataNameList, foldername)

#%% prepare revenue data for plot
ObjVal_all_unstack_raw = ObjVal_all_raw.unstack().reset_index()
ObjVal_all_unstack_raw.rename(columns={'level_7':'model', 0: 'Revenue'}, inplace=True)
ObjVal_all_unstack_raw['von'] = [v0[1] for v0 in ObjVal_all_unstack_raw['v0']]
ObjVal_all_unstack_raw['cardiOff'] = [kappa[0] for kappa in ObjVal_all_unstack_raw['kappa']]
modelReport = ["MC_Conv-mo-soc-aC", "SO-enumerate_off", "SO-enumerate_off_enumerate_on"]
ObjVal_all_unstack_raw = ObjVal_all_unstack_raw[ObjVal_all_unstack_raw['model'].isin(modelReport)]
ObjVal_all_unstack_raw.loc[ObjVal_all_unstack_raw['model'] == 'MC_Conv-mo-soc-aC', 'model'] = 'QAP'
ObjVal_all_unstack_raw.loc[ObjVal_all_unstack_raw['model'] == 'SO-enumerate_off', 'model'] = '2SRO-1'
ObjVal_all_unstack_raw.loc[ObjVal_all_unstack_raw['model'] == 'SO-enumerate_off_enumerate_on', 'model'] = '2SRO-2'

# ObjVal_all_unstack_raw = ObjVal_all_unstack_raw.loc[ObjVal_all_unstack_raw['alpha']==0.1]
# ObjVal_all_unstack_raw = ObjVal_all_unstack_raw.loc[ObjVal_all_unstack_raw['alpha']==0.5]
# ObjVal_all_unstack_raw = ObjVal_all_unstack_raw.loc[ObjVal_all_unstack_raw['cardiOff']==0.1]
# ObjVal_all_unstack_raw = ObjVal_all_unstack_raw.loc[ObjVal_all_unstack_raw['cardiOff']==1]


ObjVal_all_luce0 = ObjVal_all_unstack_raw[ObjVal_all_unstack_raw['luce'] == 0]
ObjVal_all_luce1 = ObjVal_all_unstack_raw[ObjVal_all_unstack_raw['luce'] == 1]
# plot

size_list = [(100,50)]
cardi_list = sorted(float(v) for v in ObjVal_all_unstack_raw["cardiOff"].unique())
fig, axes = plt.subplots(2, 2, figsize=(8, 8), sharey=True)
for row in [0,1]:
    if row == 0:
        df = ObjVal_all_luce0[ObjVal_all_luce0['model'].isin(['QAP', '2SRO-1'])]
    else:
        df = ObjVal_all_luce1
    for i, k in enumerate(cardi_list):
        dataplot = df.loc[df['cardiOff']==k]
        dataplot = dataplot.astype({'Revenue':float})
        # dataplot = dataplot[dataplot['model'].isin(['QAP', '2SRO-1'])]
        ax = axes[row] if axes.ndim == 1 else axes[row, i]
        sns.boxplot(ax=ax,
                    data=dataplot,
                    x='von',
                    y='Revenue',
                    hue='model',
                    # hue_order = ['QAP', '2-Step-RO', 'Enum-2SRO']
                    width=0.5,
                    )
        ax.set_xlabel(r'$v_o^{on}$', fontsize=14)
        ax.set_ylabel(r'Revenue', fontsize=14)
        ax.tick_params(axis='x', labelsize=12)
        ax.tick_params(axis='y', labelsize=12)
        # sns.move_legend(ax, loc = 'upper left', title=None, bbox_to_anchor=(1, 1.01))
        ax.grid(zorder=20)
        ax.set_title('cardi. = {:.1f}'.format(k), fontsize=14)
        # ax.get_legend().remove()
        ax.legend(bbox_to_anchor=(0.99, 1.0), loc='upper right', ncol=1, fontsize=10, handletextpad=0.2)
# fig.suptitle('Box chart for revenue comparison between heuristic algorithms and QAP. \nTop row: with 2SLM; Bottom row: without 2SLM', fontsize=16)
plt.suptitle('Comparison with Heuristics. \nTop row: without 2SLM; Bottom row: with 2SLM', fontsize=16)
plt.tight_layout()
plt.show()

# size_list = [(100,50)]
# fig, axes = plt.subplots(2, len(size_list), figsize=(7*len(size_list), 7), sharey=True)
# for row in [0,1]:
#     if row == 0:
#         dataplot = ObjVal_all_luce0[ObjVal_all_luce0['model'].isin(['QAP', '2SRO-1'])]
#     else:
#         dataplot = ObjVal_all_luce1
#     for i, size in enumerate(size_list):
#         dataplot = dataplot.loc[dataplot['size']==size]
#         dataplot = dataplot.astype({'Revenue':float})
#         # dataplot = dataplot[dataplot['model'].isin(['QAP', '2SRO-1'])]
#         ax = axes[row] if axes.ndim ==1 else axes[row, i]
#         sns.boxplot(ax=ax,
#                     # data=dataplot,
#                     x=dataplot['von'],
#                     y=dataplot['Revenue'],
#                     hue=dataplot['model'],
#                     # hue_order = ['QAP', '2-Step-RO', 'Enum-2SRO']
#                     width=0.5,
#                     )
#         ax.set_xlabel(r'$v_o^{on}$')
#         # sns.move_legend(ax, loc = 'upper left', title=None)
#         ax.grid(zorder=20)
#         # ax.set_title('size = {}'.format(size))
#         # ax.get_legend().remove()
#     ax.legend(bbox_to_anchor=(1, 1.01), loc='upper left', ncol=1)
# # fig.suptitle('Box chart for revenue comparison between heuristic algorithms and QAP. \nTop row: with 2SLM; Bottom row: without 2SLM', fontsize=16)
# plt.suptitle('Comparison with Heuristics. \nTop row: without 2SLM; Bottom row: with 2SLM', fontsize=16)
# plt.tight_layout()
# plt.show()


#%%  save to local disk
# fig.savefig('./Output/objChange_QAP_2SRO_box_cardi.png', dpi=600)

#%% get the table
# foldername = "output_compare_heuristics_SO/repeat_results_on_100_50/"
# foldername = "output_compare_heuristics_SO/repeat_results_on_smaller/"
foldername = "output_compare_heuristics_SO/repeat_results/"
dataNameList = [name for name in os.listdir(foldername)  if "InfoDict" in name]

ObjVal_all_raw, Runtime_all_raw = obtain_ObjVal(dataNameList, foldername)

ObjVal_all_unstack_raw = ObjVal_all_raw.unstack().reset_index()
ObjVal_all_unstack_raw.rename(columns={'level_7':'model', 0: 'Revenue'}, inplace=True)
ObjVal_all_unstack_raw['von'] = [v0[1] for v0 in ObjVal_all_unstack_raw['v0']]
ObjVal_all_unstack_raw['cardiOff'] = [kappa[0] for kappa in ObjVal_all_unstack_raw['kappa']]
modelReport = ["MC_Conv-mo-soc-aC", "SO-enumerate_off", "SO-enumerate_off_enumerate_on"]
ObjVal_all_unstack_raw = ObjVal_all_unstack_raw[ObjVal_all_unstack_raw['model'].isin(modelReport)]
ObjVal_all_unstack_raw.loc[ObjVal_all_unstack_raw['model'] == 'MC_Conv-mo-soc-aC', 'model'] = 'QAP'
ObjVal_all_unstack_raw.loc[ObjVal_all_unstack_raw['model'] == 'SO-enumerate_off', 'model'] = '2SRO-1'
ObjVal_all_unstack_raw.loc[ObjVal_all_unstack_raw['model'] == 'SO-enumerate_off_enumerate_on', 'model'] = '2SRO-2'

# df = ObjVal_all_unstack_raw.groupby(['size', 'alpha', 'von', 'luce', 'cardiOff', 'model'])['Revenue'].agg(["mean", 'max'])
# df.reset_index()

df = ObjVal_all_unstack_raw.set_index(['repeat', 'size', 'alpha', 'von', 'luce', 'cardiOff', 'model'])['Revenue'].unstack(level=-1)
df['gap-2SRO-1'] = (df['QAP'] - df['2SRO-1']).div(df['QAP'])*100
df['gap-2SRO-2'] = (df['QAP'] - df['2SRO-2']).div(df['QAP'])*100

df = df.groupby(['size', 'alpha', 'von', 'luce', 'cardiOff']).agg({'gap-2SRO-1': ['mean', 'max'], 'gap-2SRO-2': ['mean', 'max']})

df = df.unstack(level=-2).swaplevel(0,2,axis=1).swaplevel(1,2,axis=1).sort_index(axis=1)
df_gap = df.drop(columns=[(0, 'gap-2SRO-2', 'mean'), (0, 'gap-2SRO-2', 'max')])



# run time table
Runtime_all_unstack_raw = Runtime_all_raw.unstack().reset_index()
Runtime_all_unstack_raw.rename(columns={'level_7':'model', 0: 'Revenue'}, inplace=True)
Runtime_all_unstack_raw['von'] = [v0[1] for v0 in Runtime_all_unstack_raw['v0']]
Runtime_all_unstack_raw['cardiOff'] = [kappa[0] for kappa in Runtime_all_unstack_raw['kappa']]
modelReport = ["MC_Conv-mo-soc-aC", "SO-enumerate_off", "SO-enumerate_off_enumerate_on"]
Runtime_all_unstack_raw = Runtime_all_unstack_raw[Runtime_all_unstack_raw['model'].isin(modelReport)]
Runtime_all_unstack_raw.loc[Runtime_all_unstack_raw['model'] == 'MC_Conv-mo-soc-aC', 'model'] = 'QAP'
Runtime_all_unstack_raw.loc[Runtime_all_unstack_raw['model'] == 'SO-enumerate_off', 'model'] = '2SRO-1'
Runtime_all_unstack_raw.loc[Runtime_all_unstack_raw['model'] == 'SO-enumerate_off_enumerate_on', 'model'] = '2SRO-2'

# df = Runtime_all_unstack_raw.groupby(['size', 'alpha', 'von', 'luce', 'cardiOff', 'model'])['Revenue'].agg(["mean", 'max'])
# df.reset_index()

df = Runtime_all_unstack_raw.set_index(['repeat', 'size', 'alpha', 'von', 'luce', 'cardiOff', 'model'])['Revenue'].unstack(level=-1)
# df['gap-2SRO-1'] = (df['QAP'] - df['2SRO-1']).div(df['QAP'])*100
# df['gap-2SRO-2'] = (df['QAP'] - df['2SRO-2']).div(df['QAP'])*100

df = df.groupby(['size', 'alpha', 'von', 'luce', 'cardiOff']).agg(['mean', 'max'])

df = df.unstack(level=-2).swaplevel(0,2,axis=1).swaplevel(1,2,axis=1).sort_index(axis=1)
df_time = df.drop(columns=[(0, '2SRO-2', 'mean'), (0, '2SRO-2', 'max')])

heuristics_df = {"raw_gap": ObjVal_all_unstack_raw,
                 'gap': df_gap,
                 "raw_time": ObjVal_all_unstack_raw,
                 "time": df_time,}

filename = "output_compare_heuristics_SO/heuristic_comparison_results_small_gap_time"
tf.writeExcel(filename + ".xlsx", heuristics_df)
print(f"\n========================\n =save to {filename} \n==========================")



#%% prepare runtime data for plot, varying size
Runtime_all_unstack_raw = Runtime_all_raw.unstack().reset_index()
Runtime_all_unstack_raw.rename(columns={'level_7':'model', 0: 'Time'}, inplace=True)
Runtime_all_unstack_raw['von'] = [v0[1] for v0 in Runtime_all_unstack_raw['v0']]
modelReport = ["MC_Conv-mo-soc-aC", "SO-enumerate_off", "SO-enumerate_off_enumerate_on"]
Runtime_all_unstack_raw = Runtime_all_unstack_raw[Runtime_all_unstack_raw['model'].isin(modelReport)]
Runtime_all_unstack_raw.loc[Runtime_all_unstack_raw['model'] == 'MC_Conv-mo-soc-aC', 'model'] = 'QAP'
ObjVal_all_unstack_raw.loc[Runtime_all_unstack_raw['model'] == 'SO-enumerate_off', 'model'] = '2SRO-1'
Runtime_all_unstack_raw.loc[Runtime_all_unstack_raw['model'] == 'SO-enumerate_off_enumerate_on', 'model'] = '2SRO-2'

Runtime_all_luce0 = Runtime_all_unstack_raw[Runtime_all_unstack_raw['luce'] == 0]
Runtime_all_luce1 = Runtime_all_unstack_raw[Runtime_all_unstack_raw['luce'] == 1]
#
# modelReport = ["MC_Conv-mo-soc-aC", "SO-enumerate_off", "SO-enumerate_off_enumerate_on"]
# Runtime_all_luce0 = Runtime_all_luce0[Runtime_all_luce0['model'].isin(modelReport)]
# Runtime_all_luce0.loc[Runtime_all_luce0['model'] == 'MC_Conv-mo-soc-aC', 'model'] = 'QAP'
# Runtime_all_luce0.loc[Runtime_all_luce0['model'] == 'SO-enumerate_off', 'model'] = '2SRO-1'
# Runtime_all_luce0.loc[Runtime_all_luce0['model'] == 'SO-enumerate_off_enumerate_on', 'model'] = '2SRO-2'
#
# modelReport = ["MC_Conv-mo-soc-aC", "SO-enumerate_off", "SO-enumerate_off_enumerate_on"]
# Runtime_all_luce1 = Runtime_all_luce1[Runtime_all_luce1['model'].isin(modelReport)]
# Runtime_all_luce1.loc[Runtime_all_luce1['model'] == 'MC_Conv-mo-soc-aC', 'model'] = 'QAP'
# Runtime_all_luce1.loc[Runtime_all_luce1['model'] == 'SO-enumerate_off', 'model'] = '2SRO-1'
# Runtime_all_luce1.loc[Runtime_all_luce1['model'] == 'SO-enumerate_off_enumerate_on', 'model'] = '2SRO-2'

# plot
size_list = [(100,50)]
fig, axes = plt.subplots(2, len(size_list), figsize=(7*len(size_list), 7), sharey=True)
for row in [0,1]:
    if row == 0:
        dataplot = Runtime_all_luce0[Runtime_all_luce0['model'].isin(['QAP', '2SRO-1'])]
    else:
        dataplot = Runtime_all_luce1
    for i, size in enumerate(size_list):
        dataplot = dataplot.loc[dataplot['size']==size]
        dataplot = dataplot.astype({'Time':float})
        # dataplot = dataplot[dataplot['model'].isin(['QAP', '2SRO-1'])]
        ax = axes[row] if axes.ndim ==1 else axes[row, i]
        sns.boxplot(ax=ax,
                    # data=dataplot,
                    x=dataplot['von'],
                    y=dataplot['Time'],
                    hue=dataplot['model'],
                    # hue_order = ['QAP', '2-Step-RO', 'Enum-2SRO']
                    width=0.5,
                    )
        ax.set_xlabel(r'$v_o^{on}$')
        # sns.move_legend(ax, loc = 2, bbox_to_anchor=(1, 1))
        # ax.legend(loc="right", labels = dataplot['model'].unique(), bbox_to_anchor=(0.5, 0.5))
        # plt.legend(bbox_to_anchor=(1.05, 1), loc=2, borderaxespad=0., labels = list(dataplot['model'].unique()) )
        ax.grid(zorder=20)
        # ax.set_title('size = {}'.format(size))
        ax.get_legend().remove()
    ax.legend(bbox_to_anchor=(1, 1.01), loc='upper left', ncol=1,)
# fig.suptitle('Box chart for revenue comparison between heuristic algorithms and QAP. \nTop row: with 2SLM; Bottom row: without 2SLM', fontsize=16)
plt.suptitle('Comparison with Heuristics. \nTop row: without 2SLM; Bottom row: with 2SLM', fontsize=16)
plt.tight_layout()
plt.show()


#%%  save to local disk
# fig.savefig('./Output/timeChange_QAP_2SRO_box2.png', dpi=600)