# -*- coding: utf-8 -*-
"""
Created on Sun Jul 30 22:49:12 2023

plot the box chart for:
    1) the benefit of the joint optimization compared with Sequential Optimization;
    2) the revenue loss of mis-specification.
@author: wyl2020
"""


import os, sys
import matplotlib as mpl
import matplotlib.pyplot as plt
import seaborn as sns
import pylab as pl
import itertools, time, copy
import pandas as pd
import numpy as np

import BuildModels as bm
import ToolFunctions as tf
import CompareFunc as cm


modelReport = ['MC_Conv-mo-soc-aC', 'SO_Opt']

opt_modelname = 'MC_Conv-mo-soc-aC'

model_list = tf.get_model_list(modelReport)

#%% get result all
varying_type = sys.argv[1] # "varying_v0" or "varying_a0"
# varying_type = "varying_v0"

folder = f"./output_joint_benefit_luce_loss/{varying_type}/"
dataNameList = [name for name in os.listdir(folder) if "SolutionDict" in name]
dataNameList = sorted(dataNameList, key = lambda x: int(x[-6:-4]) if x[-6:-4].isdigit() else int(x[-5:-4]))

ObjVal_dict = {}
ObjValLuce_dict = {}
for l in dataNameList:
    filename = folder + l
    InfoDict = tf.load(filename)[0]["InfoDict"]
    SolutionDict = tf.load(filename)[0]["SolutionDict"]
    dataOptionDict = tf.load(filename)[0]["dataOptionDict"]
    probSettingSet = tf.load(filename)[0]["probSettingSet"]

    repeat_timestamp = l[44:-4]
    ObjVal = pd.concat((InfoDict[probSetting_info][1]['ObjVal']
                                 for probSetting_info in probSettingSet),
                                axis=1,
                                keys=probSettingSet)
    ObjValLuce = pd.concat((InfoDict[probSetting_info][1]['ObjValLuce']
                        for probSetting_info in probSettingSet),
                       axis=1,
                       keys=probSettingSet)
    ObjVal_dict[repeat_timestamp] = copy.copy(ObjVal)
    ObjValLuce_dict[repeat_timestamp] = copy.copy(ObjValLuce)

#%% get ObjVal and ObjGain of SO (benefit of the joint optimization)
ObjValOpt_dict = {}
ObjValSO_dict = {}
ObjGain_dict = {}
for repeat_timestamp, ObjVal in ObjVal_dict.items():
    index = [col for col in ObjVal.columns if col[3] == 0] # do not consider the 2SLM case
    ObjValOpt_dict[repeat_timestamp] = ObjVal.loc["MC_Conv-mo-soc-aC", index]
    ObjValSO_dict[repeat_timestamp] = ObjVal.loc["SO-RO_off", index]
    # obj_gain = (ObjVal.loc["MC_Conv-mo-soc-aC", index] - ObjVal.loc["SO-RO_off", index]) / ObjVal.loc["SO-RO_off", index] * 100
    obj_gain = (ObjVal.loc["MC_Conv-mo-soc-aC", index] - ObjVal.loc["SO-RO_off", index]) / ObjVal.loc["MC_Conv-mo-soc-aC", index] * 100
    ObjGain_dict[repeat_timestamp] = obj_gain

ObjValOpt_all = pd.concat(ObjValOpt_dict.values(), axis=1, keys=ObjValOpt_dict.keys())
ObjGain_all = pd.concat(ObjGain_dict.values(), axis=1, keys=ObjGain_dict.keys())

#%% get ObjValLuce gap (revenue loss of model mis-specification)

ObjValLuce_dict = {}
LuceGap_dict = {}
for repeat_timestamp, ObjValLuce in ObjVal_dict.items():
    index_noluce = [col for col in ObjValLuce.columns if col[3] == 0]
    index_luce = [col for col in ObjValLuce.columns if col[3] == 1]
    ObjValLuce0 = ObjValLuce.loc['MC_Conv-mo-soc-aC', index_noluce]
    ObjValLuce1 = ObjValLuce.loc['MC_Conv-mo-soc-aC', index_luce]
    luce_gap = ((ObjValLuce1.values  - ObjValLuce0.values))/ObjValLuce0.values * 100
    luce_gap = pd.Series(luce_gap, index=ObjValLuce0.index)
    LuceGap_dict[repeat_timestamp] = luce_gap

LuceGap_all = pd.concat(LuceGap_dict.values(), axis=1, keys=LuceGap_dict.keys())



#%% plot a0
if varying_type == 'a0':
    #%% plot ObjVal by a0, box
    dataplot = ObjValOpt_all
    # dataplot = ObjVal.groupby(level=[1,2]).mean().unstack(level=1)

    fig = plt.figure()
    ax_obj_box = fig.add_subplot(1, 1, 1)
    ax_obj_box.boxplot(dataplot.T)
    xticks = [np.round(ind[1],2) for ind in dataplot.index]
    ax_obj_box.set_xlabel(r'$\alpha_0$')
    ax_obj_box.set_ylabel('objective value', fontsize=12)
    ax_obj_box.set_xticklabels(xticks, rotation=0, fontsize = 8, ha="center")
    # plt.legend(dataHist.keys(), loc='upper right', bbox_to_anchor=(1, 1), fontsize = 6, ncol=1)
    ax_obj_box.grid()
    revenue_Type = 'SparseVIP'
    # title_text  = revenue_Type #+ probSetting
    # plt.title('Objective Value Changes on {} instances'.format(dataplot.shape[0]*dataplot.shape[1]), fontsize=12)
    # plt.suptitle('Objective Value Changes on {} instances'.format(dataplot.shape[0]*dataplot.shape[1]), fontsize=12)
    plt.tight_layout()
    # plt.show()

    # revenue_Type = 'SparseVIP'
    # FileName = './Output/'+revenue_Type + time_stamp_str +'_revenue_changes_box_a0.png'
    # fig.savefig(FileName, dpi=600, bbox_inches = 'tight')
    # print("figure print to "+FileName)
    
    
    #%% SO gap by a0, box
    dataplot = ObjGain_all
    
    fig = plt.figure()
    ax_obj_box = fig.add_subplot(1, 1, 1)
    ax_obj_box.boxplot(dataplot.T)
    ax_obj_box.set_xlabel(r'$\alpha_0$')
    ax_obj_box.set_ylabel('Gain_Joint (%)', fontsize=12)
    xticks = [np.round(ind[1],2) for ind in dataplot.index]
    ax_obj_box.set_xticklabels(xticks, rotation=0, fontsize = 8, ha="center")
    # plt.legend(dataHist.keys(), loc='upper right', bbox_to_anchor=(1, 1), fontsize = 6, ncol=1)
    ax_obj_box.grid()
    
    revenue_Type = 'SparseVIP'
    title_text  = revenue_Type #+ probSetting
    # plt.title('Revenue Loss of Miss-Specification on {} instances'.format(cost_lose.shape[0]), fontsize=12)
    # plt.suptitle('Revenue Loss of Miss-Specification on {} instances'.format(cost_lose.shape[0]), fontsize=12)
    plt.tight_layout()
    # plt.show()
    
    FileName = './Output/'+ revenue_Type +'_revenue_joint_gain_SO_a0.png'
    fig.savefig(FileName, dpi=600, bbox_inches = 'tight')
    print("figure print to "+FileName)
    
    #%% luce gap by a0, box 
    dataplot = LuceGap_all
    
    fig = plt.figure()
    ax_luce_gap = fig.add_subplot(1, 1, 1)
    # ax_luce_gap.bar(data)
    ax_luce_gap.boxplot(dataplot.T)
    ax_luce_gap.set_xlabel(r'$\alpha_0$', fontsize = 12)
    ax_luce_gap.set_ylabel('Loss_mis (%)', fontsize=12)
    xticks = np.arange(stop=dataplot.shape[0],step=1, dtype=int)
    x_ticklabels = np.array([np.round(ind[1],2) for ind in dataplot.index])
    ax_luce_gap.set_xticklabels(x_ticklabels[xticks], rotation=0, fontsize = 8, ha="center")
    # plt.legend(dataHist.keys(), loc='upper right', bbox_to_anchor=(1, 1), fontsize = 6, ncol=1)
    ax_luce_gap.grid(zorder=0)
    
    revenue_Type = 'SparseVIP'
    title_text  = revenue_Type #+ probSetting
    # plt.suptitle('Two stage luce-gap on {} instances'.format(60), fontsize=12)
    # plt.suptitle('Two stage luce-gap on {} instances of "{}" '.format(rlx_gap.shape[1], title_text), fontsize=12)
    plt.tight_layout()
    # plt.show()
    
    FileName = './Output/'+revenue_Type +'_revenue_loss_Luce_a0.png'
    fig.savefig(FileName, dpi=600, bbox_inches = 'tight')
    print("figure print to "+FileName)
    
    
#%% plot v0
if varying_type == 'v0':
    #%% plot ObjVal by v0, box
    dataplot = ObjValOpt_all
    # dataplot = ObjVal.groupby(level=[1,2]).mean().unstack(level=1)
    
    fig = plt.figure()
    ax_obj_box = fig.add_subplot(1, 1, 1)
    ax_obj_box.boxplot(dataplot.T)
    xticks = [ind[1] for ind in dataplot.index]
    ax_obj_box.set_xlabel(r'$u^{on}_0$')
    ax_obj_box.set_ylabel('objective value', fontsize=12)
    ax_obj_box.set_xticklabels(xticks, rotation=0, fontsize = 8, ha="center")
    # plt.legend(dataHist.keys(), loc='upper right', bbox_to_anchor=(1, 1), fontsize = 6, ncol=1)
    ax_obj_box.grid()
    revenue_Type = 'SparseVIP'
    title_text  = revenue_Type #+ probSetting
    # plt.title('Objective Value Changes on {} instances'.format(dataplot.shape[0]*dataplot.shape[1]), fontsize=12)
    # plt.suptitle('Objective Value Changes on {} instances'.format(dataplot.shape[0]*dataplot.shape[1]), fontsize=12)
    plt.tight_layout()
    plt.show()
    
    # FileName = './Output/'+revenue_Type + time_stamp_str +'_revenue_changes_box_v0.png'
    # fig.savefig(FileName, dpi=600, bbox_inches = 'tight')
    # print("figure print to "+FileName)
    
    
    #%% SO gap by v0, box
    dataplot = ObjGain_all
    
    fig = plt.figure()
    ax_obj_box = fig.add_subplot(1, 1, 1)
    ax_obj_box.boxplot(dataplot.T)
    ax_obj_box.set_xlabel(r'$u^{on}_0$')
    ax_obj_box.set_ylabel('Gain_Joint (%)', fontsize=12)
    xticks = [ind[1] for ind in dataplot.index]
    ax_obj_box.set_xticklabels(xticks, rotation=0, fontsize = 8, ha="center")
    # plt.legend(dataHist.keys(), loc='upper right', bbox_to_anchor=(1, 1), fontsize = 6, ncol=1)
    ax_obj_box.grid()
    
    revenue_Type = 'SparseVIP'
    title_text  = revenue_Type #+ probSetting
    # plt.title('Revenue Loss of Miss-Specification on {} instances'.format(cost_lose.shape[0]), fontsize=12)
    # plt.suptitle('Revenue Loss of Miss-Specification on {} instances'.format(cost_lose.shape[0]), fontsize=12)
    plt.tight_layout()
    plt.show()
    
    FileName = './Output/'+ revenue_Type +'_revenue_joint_gain_SO_v0.png'
    fig.savefig(FileName, dpi=600, bbox_inches = 'tight')
    print("figure print to "+FileName)
    
    #%% luce gap by v0, box 
    dataplot = LuceGap_all
    
    fig = plt.figure()
    ax_luce_gap = fig.add_subplot(1, 1, 1)
    # ax_luce_gap.bar(data)
    ax_luce_gap.boxplot(dataplot.T)
    ax_luce_gap.set_xlabel(r'$u^{on}_0$', fontsize = 12)
    ax_luce_gap.set_ylabel('Loss_mis (%)', fontsize=12)
    xticks = np.arange(stop=dataplot.shape[0],step=1, dtype=int)
    x_ticklabels = np.array([np.round(ind[1],2) for ind in dataplot.index])
    ax_luce_gap.set_xticklabels(x_ticklabels[xticks], rotation=0, fontsize = 8, ha="center")
    # plt.legend(dataHist.keys(), loc='upper right', bbox_to_anchor=(1, 1), fontsize = 6, ncol=1)
    ax_luce_gap.grid(zorder=0)
    
    revenue_Type = 'SparseVIP'
    title_text  = revenue_Type #+ probSetting
    # plt.suptitle('Two stage luce-gap on {} instances'.format(60), fontsize=12)
    # plt.suptitle('Two stage luce-gap on {} instances of "{}" '.format(rlx_gap.shape[1], title_text), fontsize=12)
    plt.tight_layout()
    plt.show()
    
    FileName = './Output/'+revenue_Type +'_revenue_loss_Luce_v0.png'
    fig.savefig(FileName, dpi=600, bbox_inches = 'tight')
    print("figure print to "+FileName)
    
    
