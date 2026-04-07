# -*- coding: utf-8 -*-
"""
Created on Wed Jan 18 01:02:37 2023

compare functions

@author: wyl2020
@email:wylwork_sjtu@sjtu.edu.cn
"""
import os, sys
# cpy = os.path.abspath(__file__)
# cwd = os.path.abspath(os.path.join(cpy, "../"))
# os.chdir(cwd)
# sys.path.append(cwd)

import matplotlib.pyplot as plt
import time
import pandas as pd
import numpy as np
import gc
import networkx as nx
import gurobipy as grb


# import BuildModels as bm
from BuildModels import Instance as Instance
import ToolFunctions as tf


# from ToolFunctions import save, load, get_model_list, extract_report
# from BuildModels import Instance_rlx as Instance_rlx
# from ToolFunctions import get_model_location

# %% collect information of the result
def collect_info(InfoReport, inst):
    numProd = inst.numProd

    InfoReport.loc[inst.modelName, "NumConstrs"] = inst.model.NumConstrs
    InfoReport.loc[inst.modelName, "NodeCount"] = inst.model.NodeCount
    m_name_info = inst.modelName.split('-')
    if any('Conic' in m for m in m_name_info) and not 'B' in inst.modelName.split('-'):
        InfoReport.loc[inst.modelName, "ObjBound"] = inst.model.ObjVal
    else:
        InfoReport.loc[inst.modelName, "ObjBound"] = inst.model.ObjVal  # inst.model.ObjBound
    InfoReport.loc[inst.modelName, "Status"] = inst.model.status
    # if inst.model.status in [2,9, 13]: # 2 optimal , 9 time limit, 13 suboptimal
    if inst.model.SolCount >= 1:
        InfoReport.loc[inst.modelName, "ObjVal"] = inst.model.ObjVal
        InfoReport.loc[inst.modelName, "ObjVal_off"] = inst.model._revenue_off.getValue()
        InfoReport.loc[inst.modelName, "ObjVal_on"] = inst.model._revenue_on.getValue()
        solution = inst.get_sol_pd()
        InfoReport.loc[inst.modelName, "NumAssort"] = (solution.iloc[1:numProd + 1].abs() > 1e-6).sum()
        InfoReport.loc[inst.modelName, "NumAssort_onAvg"] = (solution.loc[[ind for ind in solution.index if
                                                                           'y_on_y' in ind]].abs() > 1e-3).sum() / inst.numCust


def compute_relax_gap(InfoReport, inst, approach=['nodeLimit', 'continuous'], time_limit=3600):
    InfoReport.loc[inst.modelName, "R_Status"] = 1

    if 'nodeLimit' in approach:
        print("\n***** computing LP Relaxation by setting nodeLimit=0\n")
        start_time = time.process_time()
        r = inst.model.copy()

        r.reset()
        if 'Conic' in inst.modelName:
            # r.setParam('FeasibilityTol', 1e-4)
            r.setParam("GURO_PAR_BARDENSETHRESH", 1000)
            r.setParam("BarOrder", 1)
        r.setParam("NodeLimit", 0)
        r.optimize()
        InfoReport.loc[inst.modelName, "ObjRoot"] = r.ObjBound  # use the objective bound of rootnode
        InfoReport.loc[inst.modelName, "R_Status"] = r.status
        InfoReport.loc[inst.modelName, "R_Runtime"] = time.process_time() - start_time

    if 'continuous' in approach:
        print("\n***** computing LP Relaxation by continuous relaxation\n")
        start_time = time.process_time()
        r = inst.model.copy()
        r_ctn = r.relax()
        if 'Conic' in inst.modelName:
            # r.setParam('FeasibilityTol', 1e-4)
            r_ctn.setParam('BarConvTol', 1e-8)  # default 1e-8
            r_ctn.setParam('BarQCPConvTol', 1e-6)  # default 1e-6
            r_ctn.setParam("GURO_PAR_BARDENSETHRESH", 1000)
        r_ctn.setParam("BarOrder", 1)
        r_ctn.setParam("TimeLimit", min(time_limit, 3600))
        r_ctn.optimize()
        InfoReport.loc[inst.modelName, "ObjCtn"] = r_ctn.ObjVal  # use the continuous relaxation objective
        InfoReport.loc[inst.modelName, "R_Status"] = r_ctn.status
        InfoReport.loc[inst.modelName, "R_Runtime"] = time.process_time() - start_time


# %% get ObjValLuce
def get_ObjValLuce(inst, data):
    solutions = inst.Sols
    s_y_off_y = solutions.loc[[ind for ind in solutions.index if 'y_off_y' in ind]]
    s_y_on_y = solutions.loc[[ind for ind in solutions.index if 'y_on_y' in ind]]

    value_off_0 = data.value_off_0
    value_off_v = data.value_off_v
    value_on_0 = data.value_on_0
    value_on_v = data.value_on_v
    r_off = data.r_off
    r_on = data.r_on
    I = data.I
    J = data.J
    arriveRatio_off = data.arriveRatio[0] / (data.arriveRatio[0] + data.arriveRatio[1])
    arriveRatio_on = data.arriveRatio[1] / (data.arriveRatio[0] + data.arriveRatio[1])
    arriveRatio_on = np.repeat(arriveRatio_on, data.numCust) / data.numCust

    # --------------------------- old approach for calculating the obj under 2SLM -------------------
    # ObjValLuce = pd.DataFrame(columns=['ObjValLuce'])
    # for m in solutions.columns:
    #     if 'Luce' not in data.Ex_Cstr_Dict:
    #         ObjValLuce.loc[m] = np.nan
    #         continue
    #     if all(np.isnan(s_y_off_y.loc[:, m].values)):
    #         s_x_off_x = solutions.loc[[ind for ind in solutions.index if 'x_off' in ind]]
    #         s_x_on_x = solutions.loc[[ind for ind in solutions.index if 'x_on' in ind]]
    #         s_x_off_x_m = s_x_off_x.loc[:, m].values
    #         s_y_off_y_m = s_x_off_x_m / (s_x_off_x_m.dot(value_off_v) + data.v0_off)
    #         s_x_on_x_m = s_x_on_x.loc[:, m].values.reshape(inst.numProd, inst.numCust)
    #         sum_v_m = [s_x_on_x_m[:, j].dot(value_on_v[:, j]) for j in data.J]
    #         s_y_on_y_m = s_x_on_x_m / (np.array(sum_v_m) + data.v0_on)
    #     else:
    #         s_y_off_y_m = s_y_off_y.loc[:, m].values
    #         s_y_on_y_m = s_y_on_y.loc[:, m].values.reshape(inst.numProd, inst.numCust)
    #     for j in data.J:
    #         row_ind = data.Ex_Cstr_Dict['Luce'].loc[:, ('on{}'.format(j), 'row')].dropna().astype('int')
    #         col_ind = data.Ex_Cstr_Dict['Luce'].loc[:, ('on{}'.format(j), 'col')].dropna().astype('int')
    #         adj_matrix = np.zeros((inst.numProd, inst.numProd), dtype='int')
    #         adj_matrix[row_ind, col_ind] = 1
    #         DG = nx.from_numpy_array(adj_matrix, create_using=nx.DiGraph)
    #         roots = [v for v, d in DG.in_degree() if d == 0]
    #         leaves = [v for v, d in DG.out_degree() if d == 0]
    #
    #         # roots  = np.where((adj_matrix.sum(0) == 0) & (adj_matrix.sum(1)>0))[0]
    #         # leaves = np.where((adj_matrix.sum(0) > 0) & (adj_matrix.sum(1)==0))[0]  # 入度>0 & 出度=0
    #         # chain constr
    #         all_paths = []
    #         for root in roots:
    #             paths = nx.all_simple_paths(DG, root, leaves)
    #             all_paths.extend(paths)
    #         for path_nodes in all_paths:
    #             path_nodes = np.array(path_nodes)
    #             nonzero = np.nonzero(s_y_on_y_m[path_nodes, j] > 1e-6)[0]
    #             if len(nonzero) <= 1:
    #                 pass
    #             else:
    #                 s_y_on_y_m[path_nodes[nonzero[1:]], j] = 0
    #     revenue_off = arriveRatio_off * sum(s_y_off_y_m[i] * r_off[i] * value_off_v[i] for i in I)
    #     revenue_on = sum(arriveRatio_on[j] * s_y_on_y_m[i, j] * r_on[i, j] * value_on_v[i, j] for i in I for j in J)
    #     ObjValLuce.loc[m] = revenue_off + revenue_on

    #--------------------------- new approach for calculating the obj under 2SLM -------------------
    def obtain_revenue_mnl(v0, v, r, S):
        numProd = len(v)
        p = np.zeros(numProd)
        p[S] = v[S] / (v0 + sum(v[S]))
        obj = sum(r[S] * p[S])
        return obj

    def obtain_revenue_luce(v0, v, r, S, j):
        row_ind = data.Ex_Cstr_Dict['Luce'].loc[:, ('on{}'.format(j), 'row')].dropna().astype('int')
        col_ind = data.Ex_Cstr_Dict['Luce'].loc[:, ('on{}'.format(j), 'col')].dropna().astype('int')
        adj_matrix = np.zeros((data.numProd, data.numProd), dtype='int')
        adj_matrix[row_ind, col_ind] = 1
        DG = nx.from_numpy_array(adj_matrix, create_using=nx.DiGraph)
        roots = [v for v, d in DG.in_degree() if d == 0]
        leaves = [v for v, d in DG.out_degree() if d == 0]

        # chain constr
        all_paths = []
        for root in roots:
            paths = nx.all_simple_paths(DG, root, leaves)
            all_paths.extend(paths)
        dominated = set()
        for path_nodes in all_paths:
            path_nodes = np.array(path_nodes)
            _intersection = [i for i in path_nodes if i in S]
            dominated.update(_intersection[1:])
        _S = np.setdiff1d(S, list(dominated))

        obj = obtain_revenue_mnl(v0, v, r, _S)
        return obj

    def obtain_revenue_by_applying_luce_to_assortment_on(S_on):
        obj_on = []
        for j in J:
            S = S_on[j]
            obj = obtain_revenue_luce(value_on_0[j], value_on_v[:, j], r_on[:, j], S, j)
            obj_on.append(obj)
        return obj_on

    # ----------------- debug -----------------
    sol_qap = solutions[['MC_Conv-mo-soc-aC']]
    qap_s_off = sol_qap.loc[[ind for ind in sol_qap.index if 'x_off' in ind]]
    qap_s_on_y = sol_qap.loc[[ind for ind in sol_qap.index if 'y_on_y' in ind]]
    qap_s_on_y = qap_s_on_y.values.reshape(inst.numProd, inst.numCust)
    S_off_qap = np.where(qap_s_off.values >0.95)[0]
    S_on_qap = [np.where(qap_s_on_y[:,j] >1e-8)[0] for j in inst.J]


    sol_2sro1 = solutions[['SO-enumerate_off']]
    s_off_2sro1 = sol_2sro1.loc[[ind for ind in sol_qap.index if 'x_off' in ind]]
    s_on_2sro1 = sol_2sro1.loc[[ind for ind in sol_qap.index if 'x_on' in ind]]
    s_on_2sro1 = s_on_2sro1.values.reshape(inst.numProd, inst.numCust)
    S_off_2sro1 = np.where(s_off_2sro1.values > 0.95)[0]
    S_on_2sro1 = [np.where(s_on_2sro1[:, j] > 0.95)[0] for j in inst.J]


    ObjValLuce = pd.DataFrame(columns=['ObjValLuce'])
    for m in solutions.columns:
        if 'Luce' not in data.Ex_Cstr_Dict:
            ObjValLuce.loc[m] = np.nan
            continue
        if all(np.isnan(s_y_off_y.loc[:, m].values)):
            s_x_off_x = solutions.loc[[ind for ind in solutions.index if 'x_off' in ind]]
            s_x_on_x = solutions.loc[[ind for ind in solutions.index if 'x_on' in ind]]
            s_x_off_x_m = s_x_off_x.loc[:, m].values
            s_y_off_y_m = s_x_off_x_m / (s_x_off_x_m.dot(value_off_v) + data.v0_off)
            s_x_on_x_m = s_x_on_x.loc[:, m].values.reshape(inst.numProd, inst.numCust)
            sum_v_m = [s_x_on_x_m[:, j].dot(value_on_v[:, j]) for j in data.J]
            s_y_on_y_m = s_x_on_x_m / (np.array(sum_v_m) + data.v0_on)
        else:
            s_y_off_y_m = s_y_off_y.loc[:, m].values
            s_y_on_y_m = s_y_on_y.loc[:, m].values.reshape(inst.numProd, inst.numCust)
        s_on = [np.nonzero(s_y_on_y_m[:, j] > 1e-6)[0] for j in J]
        obj_on = obtain_revenue_by_applying_luce_to_assortment_on(s_on)

        revenue_off = arriveRatio_off * sum(s_y_off_y_m[i] * r_off[i] * value_off_v[i] for i in I)
        revenue_on = sum(arriveRatio_on * obj_on)
        ObjValLuce.loc[m] = revenue_off + revenue_on
    return ObjValLuce


# %% compareModels
def compareModels(data, option, variableNeed='', model_list='', enumerate_off_save=False):
    if len(model_list) < 1:
        model_list = ['MC_Conv-B',
                      'MC_Conv-B-mo',
                      'Conic_Conv',
                      'Conic_Conic',
                      'MC_Conv-C',
                      'MC_Conv-C-cut',
                      'MC_Conv-B-aC',
                      'MC_Conv-mo-C',
                      'MC_Conv-mo-C-cut',
                      'MC_Conv-mo-B-aC']

    if len(variableNeed) > 1:
        columns = variableNeed
    else:
        columns = ["ObjVal", "ObjRoot", "Runtime", "NumConstrs", "NodeCount", "ObjBound", "gap"]
    InfoReport = pd.DataFrame(columns=columns)

    inst = Instance(data, option)

    for m_name in model_list:
        m_name_info = m_name.split('-')
        print("\n================={}================\n".format(m_name))
        print("====numProd:{}    numCust:{} \n".format(data.numProd, data.numCust))

        # continuous or IP
        if 'C' in m_name_info:
            xType = 'C'
        else:
            xType = 'B'

        # modified MC or pure MC
        if 'mo' in m_name_info:
            mMC = 'mo'
        else:
            mMC = ''

        if 'soc' in m_name_info:
            soc = 'soc'
        else:
            soc = ''

        # creat base models
        if 'cut' in m_name_info or 'aC' in m_name_info:
            pass
        else:
            if "MC_MC" in m_name.split('-'):
                inst.MC_MC(xType, mMC, soc)
            elif "MC_Conv" in m_name.split('-'):
                inst.MC_Conv(xType, mMC, soc)
            elif "MC_Conic" in m_name.split('-'):
                inst.MC_Conic(xType, mMC, soc)
            elif "Conic_MC" in m_name.split('-'):
                inst.Conic_MC(xType, mMC)
            elif "Conic_Conv" in m_name.split('-'):
                inst.Conic_Conv(xType, mMC)
            elif "Conic_Conic" in m_name.split('-'):
                inst.Conic_Conic(xType, mMC)
            elif "MILP" in m_name.split('-'):
                inst.MILP(xType, mMC)
            elif "FPTAS" in m_name.split('-'):
                inst.FPTAS(sigma=1e-2)
            inst.modelName = m_name

        # add cuts or solve the model with cuts or solve base models
        # add cuts
        if 'cut' in m_name_info:  # add cuts
            cut_round_limit = option.cut_round_limit
            cut_round = 0
            sol_cut = pd.DataFrame()
            while cut_round < cut_round_limit:
                start_time = time.process_time()

                cut_round += 1
                modelName = '{}{}'.format(m_name, cut_round)
                Infeasi_flag, coeDict = inst.check_convexHull()
                InfoReport.loc[modelName, "Separtime"] = time.process_time() - start_time
                if any(Infeasi_flag[0]) | any(Infeasi_flag[1]):
                    index_set = [list(Infeasi_flag[0].keys()), list(Infeasi_flag[1].keys())]
                    inst.add_cut(index_set, coeDict, cut_round)
                    inst.modelName = modelName
                    InfoReport.loc[modelName, 'addConstrTime'] = time.process_time() - start_time - InfoReport.loc[
                        modelName, "Separtime"]

                    # inst.model.setParam('BarConvTol', option.BarConvTol)  # default 1e-8
                    # inst.model.setParam('BarQCPConvTol', option.BarQCPConvTol)  # default 1e-6
                    # inst.model.setParam("GURO_PAR_BARDENSETHRESH", 1000)
                    # inst.model.setParam("BarOrder", 1)
                    # inst.model.setParam("crossover", 1)
                    # inst.model.setParam("BarHomogeneous", 1)

                    # for the instance with numerical issue
                    # see https://docs.gurobi.com/projects/optimizer/en/current/concepts/numericguide/numeric_parameters.html#secnumericparameters
                    # inst.model.Params.BarHomogeneous = 1
                    # inst.model.Params.crossover = 1
                    inst.model.setParam("GURO_PAR_BARDENSETHRESH", 10000) # !This is a non-announced parameter of Gurobi!
                    inst.model.Params.BarOrder = 1
                    # inst.model.Params.Presolve = 0
                    # inst.model.Params.Aggregate = 0
                    # inst.model.Params.NumericFocus = 3 # NumericFocus >0 will make everything much slower, but more robust.
                    inst.model.Params.ScaleFlag = 1
                    inst.model.Params.BarConvTol = 1e-4
                    inst.model.Params.BarQCPConvTol = 1e-4

                    inst.modelOptimize()
                    # ------------------- only for the numerical issue
                    if inst.model.status not in [ grb.GRB.status.OPTIMAL, grb.GRB.status.TIME_LIMIT, grb.GRB.status.SUBOPTIMAL]:
                        inst.model.Params.ScaleFlag = 2
                        # inst.model.Params.NumericFocus = 3  # NumericFocus >0 will make everything much slower, but more robust.
                        inst.modelOptimize()
                    if inst.model.status not in [ grb.GRB.status.OPTIMAL, grb.GRB.status.TIME_LIMIT, grb.GRB.status.SUBOPTIMAL]:
                        inst.model.Params.ScaleFlag = 3
                        # inst.model.Params.NumericFocus = 3  # NumericFocus >0 will make everything much slower, but more robust.
                        inst.modelOptimize()
                    if inst.model.status not in [ grb.GRB.status.OPTIMAL, grb.GRB.status.TIME_LIMIT, grb.GRB.status.SUBOPTIMAL]:
                        inst.model.Params.ScaleFlag = 1
                        inst.model.Params.NumericFocus = 3  # NumericFocus >0 will make everything much slower, but more robust.
                        inst.modelOptimize()
                    if inst.model.status not in [ grb.GRB.status.OPTIMAL, grb.GRB.status.TIME_LIMIT, grb.GRB.status.SUBOPTIMAL]:
                        inst.model.Params.ScaleFlag = 2
                        inst.model.Params.NumericFocus = 3  # NumericFocus >0 will make everything much slower, but more robust.
                        inst.modelOptimize()
                    # -------------------------------------------------------
                    InfoReport.loc[modelName, "Runtime"] = inst.model.Runtime + InfoReport.loc[modelName, "Separtime"]
                    # InfoReport.loc[modelName, "Runtime"] = time.process_time() - start_time
                    collect_info(InfoReport, inst)
                else:
                    print("**** no cuts identified and added in round{}".format(cut_round))
                    InfoReport.loc[modelName, "Runtime"] = np.nan
                    continue

        # solve the model with cuts or solve base models
        elif 'aC' in m_name_info:  # solve the model with cuts
            print("\n*=================after cuts===================*\n")
            xType = 'B'
            inst.model.setAttr('VType', inst.model._x_off, xType)
            inst.model.setParam('Presolve', 1)
            inst.modelName = m_name

            # inst.model.setParam('DegenMoves', 2) # -1, 0, 1 2
            inst.model.setParam('BarOrder', 1)  # -1, 0, 1 2
            inst.model.update()
            inst.modelOptimize()
            InfoReport.loc[inst.modelName, "Runtime"] = inst.model.Runtime
            collect_info(InfoReport, inst)
        # solve base models
        elif ('SO' not in m_name_info):  # solve base models
            inst.model.update()
            inst.modelOptimize()
            InfoReport.loc[inst.modelName, "Runtime"] = inst.model.Runtime
            collect_info(InfoReport, inst)

        if ('B' in xType) & ('SO' not in m_name_info):
            InfoReport.loc[inst.modelName, "gap"] = inst.model.MIPGap
            print("\n*================= LP Relaxation ===================*\n")
            if option.compute_relax_gap == 1:
                compute_relax_gap(InfoReport, inst, approach=option.gapApproach, time_limit=option.grb_para_timelimit)

        if 'RO_off' in m_name_info:
            start_time = time.process_time()
            S_opt_off, S_opt_on, revenue_off, revenue_on, x_off, x_on = inst.SO_RO_off()
            InfoReport.loc[inst.modelName, "Runtime"] = time.process_time() - start_time
            InfoReport.loc[inst.modelName, "ObjVal"] = revenue_off + revenue_on
            InfoReport.loc[inst.modelName, "ObjVal_off"] = revenue_off
            InfoReport.loc[inst.modelName, "ObjVal_on"] = revenue_on
            InfoReport.loc[inst.modelName, "NumAssort"] = len(S_opt_off)
            InfoReport.loc[inst.modelName, "NumAssort_onAvg"] = sum(len(S_opt_on[j]) for j in data.J) / data.numCust

        if 'enumerate_off' in m_name_info:
            start_time = time.process_time()
            S_opt_off, S_opt_on, revenue_off, revenue_on, x_off, x_on, revenue_off_list, revenue_on_list = inst.SO_enumerate_off()
            InfoReport.loc[inst.modelName, "Runtime"] = time.process_time() - start_time
            InfoReport.loc[inst.modelName, "ObjVal"] = revenue_off + revenue_on
            InfoReport.loc[inst.modelName, "ObjVal_off"] = revenue_off
            InfoReport.loc[inst.modelName, "ObjVal_on"] = revenue_on
            InfoReport.loc[inst.modelName, "NumAssort"] = len(S_opt_off)
            InfoReport.loc[inst.modelName, "NumAssort_onAvg"] = sum(len(S_opt_on[j]) for j in data.J) / data.numCust

            if enumerate_off_save == True:
                os.makedirs("output_compare_heuristics_SO/", exist_ok=True)
                filename = "output_compare_heuristics_SO/revenue_of_enumerate_off-" + data.probName
                tf.save(filename, data, revenue_off_list, revenue_on_list, InfoReport)


        if "enumerate_off_enumerate_on" in m_name_info:
            start_time = time.process_time()
            S_opt_off, S_opt_on, revenue_off, revenue_on, x_off, x_on, revenue_off_list, revenue_on_list = inst.SO_enumerate_off_enumerate_on()
            InfoReport.loc[inst.modelName, "Runtime"] = time.process_time() - start_time
            InfoReport.loc[inst.modelName, "ObjVal"] = revenue_off + revenue_on
            InfoReport.loc[inst.modelName, "ObjVal_off"] = revenue_off
            InfoReport.loc[inst.modelName, "ObjVal_on"] = revenue_on
            InfoReport.loc[inst.modelName, "NumAssort"] = len(S_opt_off)
            InfoReport.loc[inst.modelName, "NumAssort_onAvg"] = sum(len(S_opt_on[j]) for j in data.J) / data.numCust

            if enumerate_off_save == True:
                os.makedirs("output_compare_heuristics_SO/", exist_ok=True)
                filename = "output_compare_heuristics_SO/revenue_of_enumerate_off_enumerate_on-" + data.probName
                tf.save(filename, data, revenue_off_list, revenue_on_list, InfoReport)
        # if 'FPTAS' in m_name_info:
        #     

    acountableModels = [s for s in model_list
                        if 'cut' not in s.split('-')
                        and 'C' not in s.split('-')
                        and 'SO' not in s.split('-')]
    acountable_ObjVal = InfoReport.loc[acountableModels, 'ObjVal']
    acountable_Status = InfoReport.loc[acountableModels, 'Status']
    BestObj = acountable_ObjVal[((s in [2, 8]) for s in acountable_Status.values)].max()
    InfoReport['e_gap'] = (InfoReport['ObjVal'] - BestObj) / BestObj * 100
    if 'nodeLimit' in option.gapApproach:
        # ObjRoot = InfoReport['ObjRoot'].infer_objects(copy=False).fillna(InfoReport['ObjVal'])
        ObjRoot = InfoReport['ObjRoot'].combine_first(InfoReport['ObjVal'])
        InfoReport['ObjRoot+'] = ObjRoot
        InfoReport['r_gap'] = (ObjRoot - BestObj) / BestObj * 100
    if 'continuous' in option.gapApproach:
        # ObjCtn = InfoReport['ObjCtn'].infer_objects(copy=False).fillna(InfoReport['ObjVal'])
        ObjCtn = InfoReport['ObjCtn'].combine_first(InfoReport['ObjVal'])
        InfoReport['ObjCtn+'] = ObjCtn
        InfoReport['c_gap'] = (ObjCtn - BestObj) / BestObj * 100
    InfoReport['gap'] = InfoReport['gap'] * 100
    InfoReport['ObjValLuce'] = get_ObjValLuce(inst, data)

    return InfoReport, inst.Sols


# %%
def RUN_WITH_SETTING(tosavefolder, filename, modelReport=None, roundlimit=2, timelimit=3600, repeatRange=range(0),
                     probSettingRange=range(0)):
    """
    Run the problems with specific setting options.

    Args:
        tosavefolder: the folder to save to.
        filename: the filename to load data. Should be .pkl file.
        modelReport: the models that need to be reported, (list)
        roundlimit: the number of rounds K for the separation algorithm.
        timelimit: the timelimit for solving each model.
        repeatRange: the repeat range for each model, default: range(0,36).
        probSettingRange: the prob setting range for each model, default: range(0,18).
            Each in `probSettingRange` corresponds to a combination of the problems,
                    (n, m),  (alpha0), (v0_off, v0_on), (luce), (kappa_on, kappa_off), (knapsack_off, knapsack_on),
            with the form like:
            MultiIndex([( (100, 50), 0.5,  (1, 2), 0, (1, 1), (0, 0)),
                        ( (100, 50), 0.5,  (1, 5), 0, (1, 1), (0, 0)),
                        ( (100, 50), 0.5, (1, 10), 0, (1, 1), (0, 0)),
                        ( (100, 50), 0.5,  (1, 2), 1, (1, 1), (0, 0)),
                        ( (100, 50), 0.5,  (1, 5), 1, (1, 1), (0, 0)),
                        ( (100, 50), 0.5, (1, 10), 1, (1, 1), (0, 0)),
                        ( (150, 75), 0.5,  (1, 2), 0, (1, 1), (0, 0)),
                        ( (150, 75), 0.5,  (1, 5), 0, (1, 1), (0, 0)),
                        ( (150, 75), 0.5, (1, 10), 0, (1, 1), (0, 0)),
                        ( (150, 75), 0.5,  (1, 2), 1, (1, 1), (0, 0)),
                        ( (150, 75), 0.5,  (1, 5), 1, (1, 1), (0, 0)),
                        ( (150, 75), 0.5, (1, 10), 1, (1, 1), (0, 0)),
                        ((200, 100), 0.5,  (1, 2), 0, (1, 1), (0, 0)),
                        ((200, 100), 0.5,  (1, 5), 0, (1, 1), (0, 0)),
                        ((200, 100), 0.5, (1, 10), 0, (1, 1), (0, 0)),
                        ((200, 100), 0.5,  (1, 2), 1, (1, 1), (0, 0)),
                        ((200, 100), 0.5,  (1, 5), 1, (1, 1), (0, 0)),
                        ((200, 100), 0.5, (1, 10), 1, (1, 1), (0, 0))].
            where
                alpha0 is the arrival ratio of offline customer segment;
                v0_off and v0_on are the non-purchase option's utility of the offline and online segments, respectively;
                luce indicates whether it is 2-Stage-Luce-Model (luce=1) or not;
                kappa_on and kappa_off is the right hand side of the capacity constraints for offline and online segments, respectively;
                knapsack_off, knapsack_on is the right hand side of the capacity constraints for offline and online segments, respectively; Along with this the coefficients should be provided.
    Return:
        Table_repeat: record all the necessary details about the results.
        Note:
            Each single table will be automatically saved to "tosavefolder" .
            The raw results including the solutions and other detailed results are automatically saved to "tosavefolder".
    """

    os.makedirs(tosavefolder, exist_ok=True)

    dataOptionDict_repeat, probSettingSet, repeatNum, _modelReport = tf.load(filename)
    if len(repeatRange) == 0:
        repeatRange = range(len(dataOptionDict_repeat))
    if len(probSettingRange) == 0:
        probSettingRange = range(len(probSettingSet))
    if modelReport == None:
        modelReport = _modelReport
    print("\n" + "*" * 50 + "\n dataOptionDict_repeat_all \nloaded from " + filename + "\n" + "*" * 50 + "\n")
    print(probSettingSet)

    def enumerating_in_dataOptionDict(dataOptionDict, probSettingSet):
        """
        enumerate in the dataOption Dict, run the problems in probSettingSet
        """
        time_stamp_str = pd.Timestamp.now().strftime('%Y-%m-%d-%H-%M-%S')
        SolutionDict = {}
        InfoDict = {}
        for s, probSetting_info in enumerate(probSettingSet):
            (numProd, numCust), arriveRation_off, (v0_off, v0_on), luce, (kappaOff, kappaOn), (
                knapsack_off, knapsack_on) = probSetting_info

            probName, (data, option) = dataOptionDict[probSetting_info]
            print('\n\n==============================================\n')
            print('======{}th prob with setting:'.format(s) + str(probSetting_info))
            print('\n==============================================\n\n')

            ################### specify any parameter here to contol the testing framework
            option.compute_relax_gap = 1
            option.cut_round_limit = roundlimit
            option.model_list = tf.get_model_list(modelReport)
            option.grb_para_timelimit = timelimit

            option.MMNL = 0
            option.para_logging = 0
            option.para_write_lp = 0

            ################### specify the parameters above.

            # reset data

            # reset option

            probSetting = 'Sz{}_{}_v{}_{}_s{:.1f}_{:.1f}_c{:.1f}_{:.1f}_luce{:d}'.format(data.numProd, data.numCust,
                                                                                         int(data.value_off_0),
                                                                                         int(data.value_on_0[0]),
                                                                                         data.utilitySparsity_off,
                                                                                         data.utilitySparsity_on,
                                                                                         data.kappaOff, data.kappaOn,
                                                                                         luce)
            data.probName = data.probType + probSetting + '_%d_' % (s) + time_stamp_str

            InfoReport, Sols = compareModels(data,
                                             option,
                                             variableNeed=option.variableNeed,
                                             model_list=option.model_list,
                                             enumerate_off_save=True)

            SolutionDict[probSetting_info] = data.probName, Sols
            InfoDict[probSetting_info] = data.probName, InfoReport

        return SolutionDict, InfoDict
        # return InfoDict

    def enumerating_on_dataOptionDict_warp(dataOptionDict, r, probSettingSet, modelReport, tosavefolder):
        """
        wrap the process for enumerating in dataOptionDict
        save the result to .pkl file for each dataOptionDict
        """
        time_stamp_str = pd.Timestamp.now().strftime('%Y-%m-%d-%H-%M-%S')
        option = dataOptionDict_repeat[0][probSettingSet[0]][1][1]
        option.savereport = 1

        SolutionDict, InfoDict = enumerating_in_dataOptionDict(dataOptionDict, probSettingSet)

        # save the results and dataOption
        SolutionDict_InfoDict_r = {}
        SolutionDict_InfoDict_r["InfoDict"] = InfoDict
        SolutionDict_InfoDict_r["SolutionDict"] = SolutionDict
        SolutionDict_InfoDict_r["dataOptionDict"] = dataOptionDict
        SolutionDict_InfoDict_r["probSettingSet"] = probSettingSet
        SolutionDict_InfoDict_r["modelReport"] = modelReport
        # filename = './DataSet/SolutionDict_InfoDict_dataOptionDict_repeat_' + data.probType + '_%d_' % r + time_stamp_str
        # tosavefolder = f"./Output/compare_with_customization_{time_stamp_str}/"
        filename = tosavefolder + 'SolutionDict_InfoDict_dataOptionDict_repeat_' + time_stamp_str + '_%d' % r
        tf.save(filename, SolutionDict_InfoDict_r)

        print(
            "\n" + "=" * 50 + "\n SolutionDict_InfoDict_dataOptionDict_repeat \nsave to " + filename + "\n" + "=" * 50 + "\n")

        FileName = tosavefolder + 'Tables_ReportTable1_' + time_stamp_str + '_%d' % r + '.xlsx'

        option = dataOptionDict_repeat[0][probSettingSet[0]][1][1]
        # option.savereport = 1
        CompleteTable1 = tf.extract_report(option,
                                           modelReport,
                                           probSettingSet,
                                           InfoDict,
                                           FileName,
                                           savereporttable=1)
        del InfoDict, SolutionDict_InfoDict_r
        gc.collect()
        return CompleteTable1

    Table_repeat = {}
    luce_info = {}
    for r in repeatRange:
        gc.collect()
        dataOptionDict = dataOptionDict_repeat[r]
        CompleteTable1 = enumerating_on_dataOptionDict_warp(dataOptionDict, r, probSettingSet[probSettingRange],
                                                            modelReport, tosavefolder)
        Table_repeat[r] = CompleteTable1['AggTable']
        # del SolutionDict_InfoDict_r, SolutionDict, InfoDict, dataOptionDict, data, option
        del dataOptionDict
        gc.collect()
    return Table_repeat
