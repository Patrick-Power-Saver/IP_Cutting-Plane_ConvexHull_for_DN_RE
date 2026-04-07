
import os, sys
# cpy  = os.path.abspath(__file__)
# cwd = os.path.abspath(os.path.join(cpy, "../"))
# os.chdir(cwd)
# if cwd not in sys.path:
#     sys.path.append(cwd)

from scipy.stats import pearsonr, spearmanr, kendalltau

import matplotlib.pyplot as plt
import pylab as pl
import itertools, time, copy
import pandas as pd
import numpy as np
import gc

import gurobipy as grb

import BuildModels as bm # BuildModels
import ToolFunctions as tf
import CompareFunc as cm



#%% def functions

def my_callback_fun(model, where):
    def check_convexHull(model):
        numProd = model._numProd
        numCust = model._numCust
        I = range(numProd)
        J = range(numCust)
        sol_x_off = model.cbGetNodeRel([model.getVarByName('x_off[{}]'.format(i)) for i in I])
        sol_y_off_0 = model.cbGetNodeRel(model.getVarByName('y_off_0'))
        sol_y_off_y = model.cbGetNodeRel([model.getVarByName('y_off_y[{}]'.format(i)) for i in I])
        sol_y_on_0 = model.cbGetNodeRel([model.getVarByName('y_on_0[{}]'.format(j)) for j in J])
        sol_y_on_y = np.zeros((numProd, numCust))
        # sol_x_off = [model.getVarByName('x_off[{}]'.format(i)).getAttr('x') for i in I]
        # sol_y_off_0 = model.getVarByName('y_off_0').getAttr('x')
        # sol_y_off_y = [model.getVarByName('y_off_y[{}]'.format(i)).getAttr('x') for i in I]
        # sol_y_on_0 = [model.getVarByName('y_on_0[{}]'.format(j)).getAttr('x') for j in J]
        # sol_y_on_y = np.zeros((numProd, numCust))
        for i in I:
            for j in J:
                sol_y_on_y[i, j] = model.cbGetNodeRel(model.getVarByName('y_on_y[{},{}]'.format(i, j)))

        # obj_value =.cbGet(grb.GRB.MIPNODE_OBJBST)

        s_x_off = np.array(sol_x_off).reshape(numProd, 1)
        s_y_off_0 = np.array(sol_y_off_0)
        s_y_off_y = np.array(sol_y_off_y)  # .reshape(numProd, 1)
        s_y_on_0 = np.array(sol_y_on_0)  # .reshape(1, numCust)
        s_y_on_y = np.array(sol_y_on_y).reshape(numProd, numCust)
        # obj_value = obj_value

        separate_tol = 1e-9
        # check offline customer
        y0 = np.array(s_y_off_0)
        y = np.array(s_y_off_y)
        u0 = model._value_off_0
        u = model._value_off_v
        Infeasi_flag_off = {}
        coeDict_off = {}
        for i in I:
            if u[i] == 0:
                continue
            xi = s_x_off[i]
            infeasi_flag, [coe_xi, coe_y0, coe_y] = tf.separate(i, xi, y0, y, u0, u, separate_tol)
            if infeasi_flag > 0:
                Infeasi_flag_off[i] = infeasi_flag
                coeDict_off[i] = [coe_xi, coe_y0, coe_y]

        Infeasi_flag_on = {}
        coeDict_on = {}
        for j in range(numCust):
            y0 = np.array(s_y_on_0[j])
            y = s_y_on_y[:, j]
            u0 = model._value_on_0[j]
            u = model._value_on_v[:, j]
            for i in I:
                if u[i] == 0:
                    continue
                xi = s_x_off[i]
                infeasi_flag, [coe_xi, coe_y0, coe_y] = tf.separate(i, xi, y0, y, u0, u, separate_tol)
                if infeasi_flag == 2:
                    Infeasi_flag_on[i, j] = infeasi_flag;
                    coeDict_on[i, j] = [coe_xi, coe_y0, coe_y]
                if option.MMNL == 1 and infeasi_flag == 1:
                    Infeasi_flag_on[i, j] = infeasi_flag;
                    coeDict_on[i, j] = [coe_xi, coe_y0, coe_y]

        Infeasi_flag = [Infeasi_flag_off, Infeasi_flag_on]
        coeDict = [coeDict_off, coeDict_on]
        return Infeasi_flag, coeDict


    global cut_number_off, cut_number_on
    if where == grb.GRB.Callback.MIPNODE:  # When an integer feasible solution is found
        status = model.cbGet(grb.GRB.Callback.MIPNODE_STATUS)
        if not (status == grb.GRB.OPTIMAL):
            return
        # Get the solution values
        Infeasi_flag, coeDict = check_convexHull(model)
        if any(Infeasi_flag[0]) | any(Infeasi_flag[1]):
            index_set = [list(Infeasi_flag[0].keys()), list(Infeasi_flag[1].keys())]
            [index_set_off, index_set_on] = index_set
            [coeDict_off, coeDict_on] = coeDict
            # offline cuts
            for i in index_set_off:
                model.cbCut(coeDict_off[i][0] * model._x_off[i] + coeDict_off[i][1] * model._y_off_0
                     + coeDict_off[i][2] @ model._y_off_y.select('*') >= 0 )
            print("*********add {} offline cuts ".format(len(index_set_off)))
            cut_number_off += len(index_set_off)
            # online cuts
            for i_j in index_set_on:
                model.cbCut(coeDict_on[i_j][0] * model._x_off[i_j[0]] + coeDict_on[i_j][1] * model._y_on_0[i_j[1]]
                     + coeDict_on[i_j][2] @ model._y_on_y.select('*', i_j[1]) >= 0 )
            numCut_on = [sum([1 for ind in index_set[1] if ind[1] == j]) for j in range(model._numCust)]
            print("*********add {} online cuts (total {}) ".format(numCut_on, sum(numCut_on)))
            cut_number_on += sum(numCut_on)

#%% get the data file
dataFolder = 'DataSet/'
dataNameList = [name for name in os.listdir(dataFolder)  if "agg_dataOptionDictsparseVIPLuce_repeat" in name]
# dataNameList = ['agg_dataOptionDictsparseVIPLuce_repeat36_2024-09-22-04-20-19.pkl']
filename = dataFolder+dataNameList[0]
modelReport = ['MC_Conv-mo-soc-aC']
time_stamp_str = pd.Timestamp.now().strftime('%Y-%m-%d-%H-%M-%S')
tosavefolder = f"output_callback/{time_stamp_str}_callback/"
os.makedirs(tosavefolder, exist_ok=True)
timelimit = 3.0 # 3600

#%%
dataOptionDict_repeat, probSettingSet, repeatNum, _modelReport = tf.load(filename)
# repeatRange = range(len(dataOptionDict_repeat))
# probSettingRange = range(len(probSettingSet))
repeatRange = range(3) # range(len(dataOptionDict_repeat))
probSettingRange = range(6) # range(len(probSettingSet))

obj_cb_df = pd.DataFrame(index = probSettingSet, columns=repeatRange)
runtime_cb_df = pd.DataFrame(index = probSettingSet, columns=repeatRange)
bestbd_cb_df = pd.DataFrame(index = probSettingSet, columns=repeatRange)
gap_cb_df = pd.DataFrame(index = probSettingSet, columns=repeatRange)
userCut_num_off_cb_df = pd.DataFrame(index = probSettingSet, columns=repeatRange)
userCut_num_on_cb_df = pd.DataFrame(index = probSettingSet, columns=repeatRange)
SolutionDict_repeat = {}
for r in repeatRange:
    SolutionDict = {}
    for s in probSettingRange:
        probName, (data, option) = dataOptionDict_repeat[r][probSettingSet[s]]
        print("\n" + "="*30 + f"(S{data.numProd, data.numCust}, a0({data.arriveRatio[0]}), v0({data.v0_off, data.v0_on}))" + "\n")

        inst = bm.Instance(data, option)
        inst.MC_Conv(xType="B", mMC='mo', soc='soc')
        inst.model._numProd = inst.numProd
        inst.model._numCust = inst.numCust
        model = inst.model
        model._value_off_0 = data.value_off_0
        model._value_on_0 = data.value_on_0
        model._value_off_v = data.value_off_v
        model._value_on_v = data.value_on_v
        model._r_off = data.r_off
        model._r_on = data.r_on
        model.setParam("TimeLimit", timelimit)
        # inst.modelOptimize()

        cut_number_off = 0
        cut_number_on = 0
        inst.modelOptimize(my_callback_fun)

        runtime, obj, bestbd, gap = model.runtime, model.ObjVal, model.ObjBound, model.MIPGap
        obj_cb_df.at[probSettingSet[s], r] = obj
        runtime_cb_df.at[probSettingSet[s], r] = runtime
        bestbd_cb_df.at[probSettingSet[s], r] = bestbd
        gap_cb_df.at[probSettingSet[s], r] = gap
        userCut_num_off_cb_df.at[probSettingSet[s], r] = cut_number_off
        userCut_num_on_cb_df.at[probSettingSet[s], r] = cut_number_on

        SolutionDict[probSettingSet[s]] = {"Sols": inst.Sols, "runtime": runtime, "obj":obj, "bestbd":bestbd, "e_gap":gap, "cutNum_off":userCut_num_off_cb_df, "cutNum_on":userCut_num_on_cb_df}
    filename = tosavefolder + 'SolutionDict_repeat_' + time_stamp_str + '_%d' % r
    tf.save(filename, SolutionDict)

#%%%
def cancat_table(df):
    n_m_k_v0on_a_luce = df.index.to_series().apply(
        lambda x: pd.Series([x[0][0], x[0][1], x[0][0] * x[4][0], x[2][1], x[1], x[3]]))
    df_sta = pd.DataFrame({"ave": df.mean(axis=1),
                           "max": df.max(axis=1),
                           "min": df.min(axis=1),
                           "95q": df.quantile(0.95, axis=1),
                           "05q": df.quantile(0.55, axis=1)})
    n_m_k_v0on_a_luce.columns = ["n", "m", "k", "v0_on", "arrive_off", "luce"]
    df_sta_cancat = pd.concat([n_m_k_v0on_a_luce, df_sta, df], axis=1)
    return df_sta_cancat
#%%

runtime_cb_df = cancat_table(runtime_cb_df)
gap_cb_df     = cancat_table(gap_cb_df)
userCut_num_off_cb_df = cancat_table(userCut_num_off_cb_df)
userCut_num_on_cb_df = cancat_table(userCut_num_on_cb_df)

cb_table_dict = {"RunTime": runtime_cb_df,
                 "ObjVal": obj_cb_df,
                 "BestBd": bestbd_cb_df,
                 "e_gap":gap_cb_df,
                 "cutNum_off":userCut_num_off_cb_df,
                 "cutNum_on":userCut_num_on_cb_df}


FileName = tosavefolder + 'Tables_ReportTable1_' + '_callback.xlsx'
tf.writeExcel(FileName, cb_table_dict)
print("\n" +"="*50+"\n CALLBACK_Runtime \nsave to "+FileName+"\n"+"="*50+"\n" )