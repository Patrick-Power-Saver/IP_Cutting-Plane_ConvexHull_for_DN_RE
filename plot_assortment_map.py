# -*- coding: utf-8 -*-
"""
Created on Wed Aug  2 23:38:19 2023

@author: wyl2020
"""


import os, sys

import matplotlib as mpl
# mpl.use('Agg')
import matplotlib.pyplot as plt
import seaborn as sns
import pylab as pl
import itertools, time, copy
import pandas as pd
import numpy as np
from statistics import median
pd.set_option("display.max_columns", 20)
pd.set_option("display.width", 150)

import BuildModels as bm
import ToolFunctions as tf
import CompareFunc as cm


opt_modelname = 'MC_Conv-mo-soc-aC'

#%% get result all
varying_type = sys.argv[1] # "varying_v0" or "varying_a0"

filename = "./output_assortment_map/SolutionDict_InfoDict_dataOptionDict_" + varying_type
InfoDict = tf.load(filename)[0]["InfoDict"]
SolutionDict = tf.load(filename)[0]["SolutionDict"]
dataOptionDict = tf.load(filename)[0]["dataOptionDict"]
probSettingSet = tf.load(filename)[0]["probSettingSet"]


time_stamp = pd.Timestamp.now()
time_stamp_str = str(time_stamp.date())+'-{:02}-{:02}-{:02}'.format(time_stamp.hour,time_stamp.minute,time_stamp.second)

    
#%% get probability
Solution_temp = pd.concat((SolutionDict[probSetting_info][1][opt_modelname]
                              for probSetting_info in probSettingSet),
                              axis=1, keys=probSettingSet)

data = dataOptionDict[probSettingSet[2]][1][0]
value_off_v = data.value_off_v
reven_off_r = data.r_off.reshape(data.numProd)
r_sort_ind = np.argsort(-reven_off_r)
r_sort_ind = r_sort_ind[:100]


#%% plot probability
for LuceOrNot in [0,1]:
    # LuceOrNot = 1
    index = [col for col in Solution_temp.columns if col[3]==LuceOrNot]
    Solution = Solution_temp.loc[:, index].copy()
    

    if varying_type == 'varying_a0':
        
        
        fig = plt.figure(figsize=(9,12))
        high = 5
        width = 3
        gs = fig.add_gridspec(nrows=high, ncols=width*3)



        # y probability on offline
        ax_yoff = fig.add_subplot(gs[:high, :width])

        y_off_ind = [ind for ind in Solution.index if 'y_off_y' in ind]
        y_off_solution = Solution.loc[y_off_ind]
        dataplot = y_off_solution.mul(value_off_v, axis=0).iloc[r_sort_ind,:]
        dataplot[dataplot < 1e-8] = 0
        vmin = dataplot[dataplot > 1e-4].min().min()
        vmax = dataplot.max().max()
        norm = mpl.colors.LogNorm(vmin=vmin, vmax=vmax)
        im = sns.heatmap(dataplot,
                         ax=ax_yoff,
                         cmap="YlGnBu",  # crest， YlGnBu
                         norm=norm,
                         vmin=vmin,
                         vmax=vmax,
                         linewidths=0.005,
                         cbar=False,
                         clip_on=True,
                         xticklabels=False,
                         )

        x_ticklabels = dataplot.columns.get_level_values(1)
        y_ticklabels = np.arange(dataplot.shape[0]) + 1
        x_ticks = [min(x_ticklabels), median(x_ticklabels), max(x_ticklabels)]
        y_ticks = np.arange(stop=dataplot.shape[0], step=5, dtype=int)

        # im = plt.imshow(dataplot, cmap='YlGnBu', norm=norm)
        ax_yoff.set_xticks([0, len(x_ticklabels)//2, len(x_ticklabels)-1])
        ax_yoff.set_xticklabels(x_ticks, fontsize=16, rotation=0, ha='left')
        ax_yoff.set_yticks(y_ticks)
        ax_yoff.set_yticklabels(y_ticklabels[y_ticks], fontsize=16)
        ax_yoff.set_xlabel(r"$\alpha_0$", fontsize=20)
        ax_yoff.set_ylabel("products index (revenue-ordered)", fontsize=22)
        plt.title('offline', fontsize=22)
        for _, spine in ax_yoff.spines.items():
            spine.set_visible(True)
        # plt.show()
        
        
        
        
        # y probability on regularGroup
        ax_yon_r = fig.add_subplot(gs[:high, width:2 * width])

        value_on_v = data.value_on_v
        
        j = data.J[0]
        y_on_ind_j = [ind for ind in Solution.index if 'y_on_y' in ind and ',{}]'.format(j) in ind]
        y_on_solution_j = Solution.loc[y_on_ind_j]
        reven_off_r = data.r_off.reshape(data.numProd)
        reven_on_j = data.r_on[:,j]
        r_sort_ind = np.argsort(-reven_off_r)
        r_sort_ind = r_sort_ind[:100]
        
        # dataplot = y_on_solution_j.iloc[r_sort_ind,:]
        dataplot = y_on_solution_j.mul(value_on_v[:,j], axis=0).iloc[r_sort_ind,:]
        dataplot[dataplot < 1e-8] = 0
        vmin = dataplot[dataplot > 1e-4].min().min()
        vmax = dataplot.max().max()
        norm = mpl.colors.LogNorm(vmin=vmin, vmax=vmax)
        im = sns.heatmap(dataplot,
                         ax=ax_yon_r,
                         cmap="YlGnBu",  # crest， YlGnBu
                         norm=norm,
                         vmin=vmin,
                         vmax=vmax,
                         linewidths=0.005,
                         cbar=False,
                         xticklabels=False,
                         )
        ax_yon_r.set_xticks([0, len(x_ticklabels)//2, len(x_ticklabels)-1])
        ax_yon_r.set_xticklabels(x_ticks, fontsize=16, rotation=0, ha="left")
        ax_yon_r.set_yticks(y_ticks)
        ax_yon_r.set_yticklabels(y_ticklabels[y_ticks], fontsize=16)
        ax_yon_r.set_xlabel(r"$\alpha_0$", fontsize=20)
        # ax_yon_r.set_ylabel("products index (revenue-ordered)", fontsize=10)
        plt.title('regular', fontsize=22)
        for _, spine in ax_yon_r.spines.items():
            spine.set_visible(True)
        # plt.show()
        
        
        
        # y probability on VIPGroup
        ax_yon_V = fig.add_subplot(gs[:high, 2 * width:3 * width])

        j = data.J[-1]
        y_on_ind_j = [ind for ind in Solution.index if 'y_on_y' in ind and ',{}]'.format(j) in ind]
        y_on_solution_j = Solution.loc[y_on_ind_j]
        reven_off_r = data.r_off.reshape(data.numProd)
        reven_on_j = data.r_on[:,j]
        r_sort_ind = np.argsort(-reven_off_r)
        r_sort_ind = r_sort_ind[:100]

        dataplot = y_on_solution_j.mul(value_on_v[:,j], axis=0).iloc[r_sort_ind,:]
        dataplot[dataplot < 1e-8] = 0
        vmin = dataplot[dataplot > 1e-4].min().min()
        vmax = dataplot.max().max()
        norm = mpl.colors.LogNorm(vmin=vmin, vmax=vmax)
        im = sns.heatmap(dataplot,
                         ax=ax_yon_V,
                         cmap="YlGnBu",  # crest， YlGnBu
                         norm=norm,
                         vmin=vmin,
                         vmax=vmax,
                         linewidths=0.005,
                         cbar=False,
                         xticklabels=False,
                         )
        ax_yon_V.set_xticks([0, len(x_ticklabels)//2, len(x_ticklabels)-1])
        ax_yon_V.set_xticklabels(x_ticks, fontsize=16, rotation=0, ha='left')
        ax_yon_V.set_yticks(y_ticks)
        ax_yon_V.set_yticklabels(y_ticklabels[y_ticks], fontsize=16)
        ax_yon_V.set_xlabel(r"$\alpha_0$", fontsize=20)
        # ax_yon_V.set_ylabel("products index (revenue-ordered)", fontsize=10)
        # ax_yon_V.set_xlim(1,16)
        plt.title('VIP', fontsize=22)

        # fig.suptitle('Assortment map \nand purchase probability map for offline segment', x=0.5, y =0.99, fontsize=20)
        fig.tight_layout()
        for _, spine in ax_yon_V.spines.items():
            spine.set_visible(True)
        # plt.show()
        
        
        if LuceOrNot == 0:
            FileName = './Output/' + 'assortment_map_a0.png'
        if LuceOrNot == 1:
            FileName = './Output/' + 'assortment_map_a0_Luce.png'
        fig.savefig(FileName, dpi=600, bbox_inches = 'tight')
        plt.pause(2)
        plt.close()
        print("figure print to "+FileName)
    
    
    
    
    
    
    
    ##%% VARYING V0
    if varying_type == 'varying_v0':
        
        fig = plt.figure(figsize=(9,12))
        high = 5
        width = 3
        gs = fig.add_gridspec(nrows=high, ncols=width*3)

        
        
        
        
        # y probability on offline
        ax_yoff = fig.add_subplot(gs[:high, :width])

        y_off_ind = [ind for ind in Solution.index if 'y_off_y' in ind]
        y_off_solution = Solution.loc[y_off_ind]
        # dataplot = y_off_solution.iloc[r_sort_ind,:]
        dataplot = y_off_solution.mul(value_off_v, axis=0).iloc[r_sort_ind,:]
        dataplot[dataplot < 1e-8] = 0
        vmin = dataplot[dataplot > 1e-4].min().min()
        vmax = dataplot.max().max()
        norm = mpl.colors.LogNorm(vmin=vmin, vmax=vmax)
        im = sns.heatmap(dataplot,
                         ax=ax_yoff,
                         cmap="YlGnBu",  # crest， YlGnBu
                         norm=norm,
                         vmin=vmin,
                         vmax=vmax,
                         linewidths=0.005,
                         cbar=False,
                         )
        x_ticklabels = np.array([np.round(ind[1], 2) for ind in dataplot.columns.get_level_values(2)])
        y_ticklabels = np.arange(dataplot.shape[0]) + 1
        x_ticks = [min(x_ticklabels), median(x_ticklabels), max(x_ticklabels)]
        y_ticks = np.arange(stop=dataplot.shape[0], step=5, dtype=int)

        
        # im = plt.imshow(dataplot, cmap='YlGnBu', norm=norm)
        ax_yoff.set_xticks([0, len(x_ticklabels)//2, len(x_ticklabels)-1])
        ax_yoff.set_xticklabels(x_ticks, fontsize=16, rotation=0, ha='left')
        ax_yoff.set_yticks(y_ticks)
        ax_yoff.set_yticklabels(y_ticklabels[y_ticks], fontsize=16)
        ax_yoff.set_xlabel(r'$u^{on}_0$', fontsize=20)
        ax_yoff.set_ylabel("products index (revenue-ordered)", fontsize=22)
        plt.title('offline', fontsize=22)
        for _, spine in ax_yoff.spines.items():
            spine.set_visible(True)
        # plt.show()
        
        
        
        
        # y probability on regularGroup
        ax_yon_r = fig.add_subplot(gs[:high, width:2 * width])

        value_on_v = data.value_on_v
        j = data.J[0]
        y_on_ind_j = [ind for ind in Solution.index if 'y_on_y' in ind and ',{}]'.format(j) in ind]
        y_on_solution_j = Solution.loc[y_on_ind_j,:]
        reven_off_r = data.r_off.reshape(data.numProd)
        reven_on_j = data.r_on[:,j]
        r_sort_ind = np.argsort(-reven_off_r)
        r_sort_ind = r_sort_ind[:100]
        
        # dataplot = y_on_solution_j.iloc[r_sort_ind,:]
        dataplot = y_on_solution_j.mul(value_on_v[:,j], axis=0).iloc[r_sort_ind,:]
        dataplot[dataplot < 1e-8] = 0
        vmin = dataplot[dataplot > 1e-4].min().min()
        vmax = dataplot.max().max()
        norm = mpl.colors.LogNorm(vmin=vmin, vmax=vmax)
        im = sns.heatmap(dataplot,
                         ax=ax_yon_r,
                         cmap="YlGnBu",  # crest， YlGnBu
                         norm=norm,
                         vmin=vmin,
                         vmax=vmax,
                         linewidths=0.005,
                         cbar=False,
                         )
        ax_yon_r.set_xticks([0, len(x_ticklabels)//2, len(x_ticklabels)-1])
        ax_yon_r.set_xticklabels(x_ticks, fontsize=16, rotation=0, ha='left')
        ax_yon_r.set_yticks(y_ticks)
        ax_yon_r.set_yticklabels(y_ticklabels[y_ticks], fontsize=16)
        ax_yon_r.set_xlabel(r'$u^{on}_0$', fontsize=20)
        # ax_yon_r.set_ylabel("products index (revenue-ordered)", fontsize=10)
        plt.title('regular', fontsize=22)
        for _, spine in ax_yon_r.spines.items():
            spine.set_visible(True)
        # plt.show()
        
        
        
        
        # y probability on VIPGroup
        ax_yon_V = fig.add_subplot(gs[:high, 2 * width:3 * width])

        j = data.J[-1]
        y_on_ind_j = [ind for ind in Solution.index if 'y_on_y' in ind and ',{}]'.format(j) in ind]
        y_on_solution_j = Solution.loc[y_on_ind_j,:]
        reven_off_r = data.r_off.reshape(data.numProd)
        reven_on_j = data.r_on[:,j]
        r_sort_ind = np.argsort(-reven_off_r)
        r_sort_ind = r_sort_ind[:100]
        
        # dataplot = y_on_solution_j.iloc[r_sort_ind,:]
        dataplot = y_on_solution_j.mul(value_on_v[:,j], axis=0).iloc[r_sort_ind,:]
        dataplot[dataplot < 1e-8] = 0
        vmin = dataplot[dataplot > 1e-4].min().min()
        vmax = dataplot.max().max()
        norm = mpl.colors.LogNorm(vmin=vmin, vmax=vmax)
        im = sns.heatmap(dataplot,
                         ax=ax_yon_V,
                         cmap="YlGnBu",  # crest， YlGnBu
                         norm=norm,
                         vmin=vmin,
                         vmax=vmax,
                         linewidths=0.005,
                         cbar=False,
                         )
        ax_yon_V.set_xticks([0, len(x_ticklabels)//2, len(x_ticklabels)-1])
        ax_yon_V.set_xticklabels(x_ticks, fontsize=16, rotation=0, ha='left')
        ax_yon_V.set_yticks(y_ticks)
        ax_yon_V.set_yticklabels(y_ticklabels[y_ticks], fontsize=16)
        ax_yon_V.set_xlabel(r'$u^{on}_0$', fontsize=20)
        # ax_yon_V.set_ylabel("products index (revenue-ordered)", fontsize=10)
        # ax_yon_V.set_xlim(1,16)
        plt.title('VIP', fontsize=22)
        
        
        # fig.suptitle('Assortment map \nand purchase probability map for offline segment', x=0.5, y =0.99, fontsize=20)
        fig.tight_layout()
        for _, spine in ax_yon_V.spines.items():
            spine.set_visible(True)
        # plt.show()
        
        if LuceOrNot == 0:
            FileName = './Output/' + 'assortment_map_v0.png'
        if LuceOrNot == 1:
            FileName = './Output/' + 'assortment_map_v0_Luce.png'
        fig.savefig(FileName, dpi=600, bbox_inches = 'tight')
        plt.pause(2)
        plt.close()
        print("figure print to "+FileName)