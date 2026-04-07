# -*- coding: utf-8 -*-
"""
Created on Tue Dec 20 22:25:48 2022
Exact_model: MC+LP+Binary
@author: wyl2020
@email:wylwork_sjtu@sjtu.edu.cn
"""

"a demo problem"
import os, sys
import random, itertools, copy
import pandas as pd
import networkx as nx
from openpyxl import load_workbook

import gurobipy as grb
import numpy as np
import ToolFunctions as tf

#%% creat and verfy the folder paths
cpy  = os.path.abspath(__file__)
cwd = os.path.abspath(os.path.join(cpy, "../"))
folder = os.path.abspath(os.path.join(cwd, "lpFolder"))
if not os.path.exists(folder):
    os.makedirs(folder)
lpFolder = folder
#%%
class Option():
    """problem control parameters"""
    def __init__(self, para_randomData=0, para_relaxModel=0, para_print_checkProcess=0):
        grb_para_OutputFlag = 1
        grb_para_timelimit = 100
        para_printResult = 0
        para_print_checkProcess = 0
        # probType = 'CTN' # INT: integer random problem,; CTN: continuous random problem
        ExtraConstrListList = ['CardiOff', 'CardiOn', 'Luce']
        self.BarConvTol = 1e-5 # default 1e-8
        self.BarQCPConvTol = 1e-5 # default 1e-6
        self.grb_para_OutputFlag = grb_para_OutputFlag
        self.grb_para_timelimit = grb_para_timelimit
        self.para_randomData = para_randomData
        self.ExtraConstrList = ExtraConstrListList
        self.luceType = 'GroupPair'
        self.luceTree_nodeRatio = 0.25
        self.luceGroup_nodeRatio = 0.5
        self.cardiMC = 0 # default 0, not use the cardinality modified MC relaxation
        self.gapApproach = ['nodeLimit'] # nodeLimit or continuous
        # self.kappaOff = 0.2    #调整offline cardinality约束的右侧数值占比
        # self.kappaOn = 0.2    #online cardinality约束的右侧数值占比
        # self.prior_r = 0.01 # 调整优先顺序的约束占比
        self.delta = 0.1   # 调整线上线下 的 revenue的 相关性
        self.para_relaxModel = para_relaxModel
        self.para_print_checkProcess = para_print_checkProcess
        self.para_printResult = para_printResult
        self.para_logging = 0
        self.para_write_lp = 0
        self.para_plot = 0
        self.para_plot_save = 0
        self.plot_network = 0
        self.compute_relax_gap = 1
        # self.v0_off = 1
        # self.v0_on = 5
        self.utilitySparsity_off = 1
        self.utilitySparsity_on = 1
        
        self.read_data = 0
        
        self.revenue_vip_group_number = 2
        self.revenue_disc_range = [0.9,1]
        self.revenue_range = [10,20]
        
        self.arriveRatio = [0.5, 0.5]
        
        self.cut_round_limit = 2
        self.MMNL = 0 # modefied for MMNL model
        folder = os.path.abspath(os.path.join(cwd, "lpFolder"))
        if not os.path.exists(folder):
            os.makedirs(folder)
        self.lpFolder = folder
        
        
#%%
class Data():
    def __init__(self, option, probSetting_info):
        """problemScale = (numProd,numCust)"""
        ####### control parameters
        (numProd, numCust), arriveRatio_off, (v0_off, v0_on), luce, (kappaOff, kappaOn), (knapsack_off, knapsack_on) = probSetting_info

        # self.arriveRatio = option.arriveRatio
        # self.para_randomData = option.para_randomData
        # self.para_relaxModel = option.para_relaxModel
        # self.probType = option.attV_Type + option.revenue_Type + ''.join(option.ExtraConstrList)
        # self.ExtraConstrList = option.ExtraConstrList
        # self.luceType = option.luceType
        # self.luceTree_nodeRatio  = option.luceTree_nodeRatio
        # self.luceGroup_nodeRatio = option.luceGroup_nodeRatio
        # self.kappaOff = option.kappaOff
        # self.kappaOn = option.kappaOn
        # self.prior_r = option.prior_r
        # self.delta = option.delta
        # self.probName = ''
        # self.luce_info = np.array(0)
        # self.v0_off = option.v0_off
        # self.v0_on = option.v0_on
        # self.utilitySparsity_off = option.utilitySparsity_off
        # self.utilitySparsity_on = option.utilitySparsity_on
        # self.lpFolder = option.lpFolder
        # self.separate_tol = 1e-10
        # self.option = option
        #
        # if option.read_data == 0:
        #     self.generate_attractive_value(numProd, numCust, option.attV_Type)
        #     self.generate_revenue_data(numProd,
        #                                numCust,
        #                                option.revenue_Type,
        #                                vip_group_number=option.revenue_vip_group_number,
        #                                revenue_range=option.revenue_range,
        #                                disc_range=option.revenue_disc_range)
        #     self.generate_extraCstr_data(numProd, numCust, ExtraConstrList=option.ExtraConstrList)

        self.arriveRatio = [arriveRatio_off, 1 - arriveRatio_off]
        self.kappaOff = kappaOff
        self.kappaOn = kappaOn
        self.luce = luce
        self.knapsackOff = knapsack_off
        self.knapsackOn = knapsack_on
        self.probName = ''
        self.luce_info = np.array(0)
        self.v0_off = v0_off
        self.v0_on = v0_on
        self.ExtraConstrList = []
        self.Ex_Cstr_Dict = dict()

        self.utilitySparsity_off = option.utilitySparsity_off
        self.utilitySparsity_on = option.utilitySparsity_on
        self.ExtraConstrList = option.ExtraConstrList
        self.luceType = option.luceType
        self.luceTree_nodeRatio  = option.luceTree_nodeRatio
        self.luceGroup_nodeRatio = option.luceGroup_nodeRatio
        self.attV_Type = option.attV_Type
        self.revenue_Type = option.revenue_Type

        self.generate_attractive_value(numProd, numCust, option.attV_Type)
        self.generate_revenue_data(numProd,
                                   numCust,
                                   option.revenue_Type,
                                   vip_group_number=option.revenue_vip_group_number,
                                   revenue_range=option.revenue_range,
                                   disc_range=option.revenue_disc_range)
        self.generate_extraCstr_data(numProd, numCust)
        self.separate_tol = 1e-10


    def generate_attractive_value(self, numProd, numCust, attV_Type):
        """generate attractive value """
        if attV_Type.lower() == 'int':
            value_off_0 = self.v0_off
            value_off_v = np.random.randint(1, 10, size=numProd) # uniform(1,10)
            value_on_0 = np.ones(numCust) * self.v0_on
            value_on_v = np.random.randint(1, 10, size=(numProd, numCust)) # uniform(1,10)
            
        elif attV_Type.lower() == 'ctn':
            value_off_0 = self.v0_off # np.random.rand() * self.v0_off
            value_off_v = np.random.rand(numProd) * 9 + 1 # uniform(1,10)
            value_on_0 = np.ones(numCust) * self.v0_on
            value_on_v = np.random.rand(numProd, numCust) * 9 + 1  # uniform(1,10)
        
        elif attV_Type.lower() == 'sparse':
            k_off = int(self.utilitySparsity_off * numProd)
            k_on = int(self.utilitySparsity_on * numProd)
            value_off_0 = self.v0_off # np.random.rand() * self.v0_off
            value_off_v = np.zeros(numProd)
            loc = list(np.random.permutation(numProd))
            value_off_v[loc[:k_off]] = np.random.rand(k_off)
            value_on_0 =  np.ones(numCust)* self.v0_on
            value_on_v = np.zeros((numProd, numCust)) + np.eye(numProd, numCust)
            for col in range(numCust):
                loc = list(np.random.permutation(numProd))
                if (col < numProd) :
                    loc.remove(col)
                    if ( k_on == numProd):
                        k_on = k_on-1
                value_on_v[loc[:k_on], col] = np.random.rand(1, k_on)
             
        elif attV_Type == 'COR_N':
            r_off = self.r_off
            r_on = self.r_on
            a_off = np.random.uniform()

        elif attV_Type.lower() == 'cap':
            # CAP: CustomizedAssortment Problem;
            # El Housni O, Topaloglu H. Joint assortment optimization and customization under a mixture of multinomial logit models: On the value of personalized assortments[J]. Operations Research, 2023, 71(4): 1197-1215.
            value_off_0 = 1.0
            value_off_v = abs(np.random.normal(size=(numProd)))
            B = np.random.rand(numProd, numCust) >=0.5
            X = abs(np.random.normal(size=(numProd, numCust)))
            value_on_0 = np.ones(numCust)* self.v0_on
            value_on_v = B * X
            
        else:
            value_off_0 = 1
            value_off_v = np.array([1, 3, 7])
            value_on_0 = np.array([1])
            value_on_v = np.array([[1],
                                   [3],
                                   [5]])

            (numProd, numCust) = value_on_v.shape  # numProd: number of products; numCust number of kinds of online-customer
        
        # rounding input
        value_off_0 = value_off_0
        value_off_v = value_off_v.round(3)
        value_on_0  = value_on_0.round(3)
        value_on_v  = value_on_v.round(3)
        
        self.value_off_0 = value_off_0
        self.value_off_v = value_off_v
        self.value_on_0 = value_on_0
        self.value_on_v = value_on_v
        self.numProd = numProd
        self.numCust = numCust
        self.I = list(range(numProd))  # index set of products
        self.J = list(range(numCust))  # index set of online-customer type
        self.prod_cust = list(itertools.product(self.I, self.J))
        
    def generate_revenue_data(self, 
                              numProd, 
                              numCust, 
                              revenue_Type, 
                              vip_group_number = 2,
                              revenue_range = [10,20],
                              disc_range = [0.9,1]):
        """generate revenue data"""
        if revenue_Type.lower() == 'int':
            r_off = np.random.randint(1, 10, size=(numProd, 1)) # uniform(1,10)
            r_on_temp = np.random.randint(1, 10, size=(numProd, 1)) # uniform(1,10)
            r_on = np.repeat(r_on_temp, numCust, axis=1) # online segments have the same revenue
        elif revenue_Type.lower() == 'ctn':
            r_off = np.random.rand(numProd,1) * 9 + 1 # uniform(1,10)
            r_on_temp = np.random.rand(numProd,1)*9 + 1   # uniform(1,10) 
            r_on = np.repeat(r_on_temp, numCust, axis=1) # online segments have the same revenue
        elif revenue_Type.lower() == 'vip':
            r_off = np.random.uniform(revenue_range[0], revenue_range[1], size=(numProd,1))
            
            if vip_group_number <= 0 or vip_group_number >= numCust:
                vip_group_number = numCust
                r_on_VipGroup = r_off * np.random.uniform(disc_range[0], disc_range[1],size=(numProd,vip_group_number))
                r_on = r_on_VipGroup
            elif vip_group_number == 1:
                r_on = np.repeat(r_off, numCust, axis=1)
            else:
                numEachGroup = numCust // vip_group_number
                r_on_VipGroup = r_off * np.random.uniform(disc_range[0], disc_range[1],size=(numProd,vip_group_number-1))
                r_on_regularGroup = np.repeat(r_off, numCust-r_on_VipGroup.shape[1], axis=1)
                r_on = np.hstack([r_on_regularGroup, r_on_VipGroup])
        elif revenue_Type.lower() == 'cor_p':
            value_off_0 = self.value_off_0
            value_off_v = self.value_off_v
            value_on_0 = self.value_on_0
            value_on_v = self.value_on_v
            r_off = value_off_v * (np.random.uniform(10, 15, size=value_off_v.shape))
            r_on  = value_on_v * (np.random.uniform(10, 15, size=value_on_v.shape))
        elif revenue_Type.lower() == 'cor_n':
            value_off_0 = self.value_off_0
            value_off_v = self.value_off_v
            value_on_0 = self.value_on_0
            value_on_v = self.value_on_v
            r_off = 1/(value_off_v + 0.1) * (np.random.uniform(10, 15, size=value_off_v.shape))
            r_on  = 1/(value_on_v + 0.1) * (np.random.uniform(10, 15, size=value_on_v.shape))
            
        elif revenue_Type.lower() == 'cap':
            r_off = np.random.exponential(1, size=(numProd,1))
            r_on = np.repeat(r_off, numCust, axis=1)
            # r_on  = np.random.exponential(1, size=(numProd, numCust))
            
        else:
            r_off = np.array([6,4,3])
            r_on = np.array([[4],
                             [6],
                             [5]])
        
        # rounding input
        r_off = r_off.round(3)
        r_on  = r_on.round(3)
        
        self.r_off = r_off
        self.r_on = r_on

    def generate_extraCstr_data(self, numProd, numCust, exist=False):
        """generate data with control parameters"""
        # self.ExtraConstrList = []
        if self.luce == 1:
            self.ExtraConstrList.append("Luce")
        if self.kappaOff < 1:
            self.ExtraConstrList.append("CardiOff")
        if self.kappaOn < 1:
            self.ExtraConstrList.append("CardiOn")
        if self.knapsackOff > 0:
            self.ExtraConstrList.append("KnapsackOff")
        if self.knapsackOn > 0:
            self.ExtraConstrList.append("KnapsackOn")
        self.ExtraConstrList = list(set(self.ExtraConstrList))
        self.probType = self.attV_Type + self.revenue_Type + ''.join(self.ExtraConstrList)

        if exist == True:
            Ex_Cstr_Dict = copy.deepcopy(self.Ex_Cstr_Dict)
        else:
            Ex_Cstr_Dict = dict()
        for ex_c_name in self.ExtraConstrList:
            cstr_temp=''
            if ex_c_name.lower() == 'cardioff':
                columns = pd.MultiIndex.from_arrays([['CardiOff'], ['capacity']])
                cstr_temp = pd.DataFrame([int(self.kappaOff * numProd)], columns=columns)
                # cstr_temp = pd.Series([int(self.kappaOff * numProd)], name='CardiOff')
            if ex_c_name.lower() == 'cardion':
                columns = pd.MultiIndex.from_arrays([['CardiOn'], ['capacity']])
                k_online= np.array([int(self.kappaOn * numProd)]*self.numCust)
                cstr_temp = pd.DataFrame(k_online, index=['on{}'.format(j) for j in self.J], columns=columns)
                # cstr_temp = pd.Series(k_online, index=['on{}'.format(j) for j in self.J], name='CardiOn')
            if ex_c_name.lower() == 'knapsackoff':
                columns_weight = pd.MultiIndex.from_product([['KnapsackOff'], ['weight{}'.format(i) for i in range(numProd)]])
                columns_space = pd.MultiIndex.from_arrays([['KnapsackOff'], ['space']])
                columns = columns_weight.append(columns_space)
                weight = np.random.randint(1,10, size=(1, numProd))
                space_ratio = 0.2 
                cstr_temp = pd.DataFrame(columns=columns)
                cstr_temp.loc[:, columns_weight] = weight
                cstr_temp.loc[:, columns_space] = space_ratio
            if 'luce' in ex_c_name.lower():
                luceType = self.luceType
                if luceType == 'Tree':
                    # at lest 2 nodes were involved in each segements for 'luce' constraints
                    ratio = self.luceTree_nodeRatio # 0.25, 0.75
                    involved_nodes_num = int(ratio * self.utilitySparsity_on * numProd)+1
                    involved_nodes_num = max(2, involved_nodes_num)
                    
                    nonzeros = np.nonzero(self.value_on_v)
                    loc = []
                    for i in range(np.count_nonzero(self.value_on_v)):
                        loc.append((nonzeros[0][i], nonzeros[1][i]) )
                    nonzeros = grb.tuplelist(loc)
                    
                    columns = pd.MultiIndex.from_product([['on{}'.format(j) for j in range(numCust)], ['prodPerturb', 'row', 'col']])
                    ADJ_matrix = pd.DataFrame(columns=columns)
                    for j in range(numCust):
                        nonzeroProd = nonzeros.select('*',j)
                        nonzeroProd = [t[0] for t in nonzeroProd]
                        n1 = len(nonzeroProd)//3
                        v_r = self.value_on_v[:,j]/self.r_on[:,j]
                        # perturb_prod = np.argsort(-v_r)[:involved_nodes_num]  # descend order, first k large
                        perturb_prod = np.argsort(v_r)[:involved_nodes_num]   # ascend order, first k small
                        if len(perturb_prod) <= numProd:
                            pass
                        adj_matrix = tf.generate_random_trees(involved_nodes_num)
                        row, col = np.where(adj_matrix)
                        row = perturb_prod[row]
                        col = perturb_prod[col]
                        
                        adj_on_j = pd.concat([pd.Series(perturb_prod), pd.Series(row), pd.Series(col)], 
                                             axis=1, keys=['prodPerturb','row','col'])
                        ADJ_matrix['on{}'.format(j)] = adj_on_j
                        # ADJ_matrix[('on{}'.format(j), 'prodPerturb')] = pd.Series(perturb_prod)
                        # ADJ_matrix[('on{}'.format(j), 'row')] = pd.Series(row)
                        # ADJ_matrix[('on{}'.format(j), 'col')] = pd.Series(col)

                    cstr_temp = ADJ_matrix
                    self.luce_info = tf.get_luceInfo(ADJ_matrix)

                
                if luceType == 'GroupPair':                    
                    nonzeros = np.nonzero(self.value_on_v)
                    loc = []
                    for i in range(np.count_nonzero(self.value_on_v)):
                        loc.append((nonzeros[0][i], nonzeros[1][i]) )
                    nonzeros = grb.tuplelist(loc)
                    
                    columns = pd.MultiIndex.from_product([['on{}'.format(j) for j in range(numCust)], ['prodPerturb', 'row', 'col']])
                    ADJ_matrix = pd.DataFrame(columns=columns)
                    for j in range(numCust):
                        nonzeroProd = nonzeros.select('*',j)
                        nonzeroProd = [t[0] for t in nonzeroProd]
                        n1 = len(nonzeroProd)//3
                        v_r = self.value_on_v[:,j]/self.r_on[:,j]
                        perturb_prod = np.argsort(-v_r)  # descend order, first k large
                        # perturb_prod = np.argsort(v_r)   # ascend order, first k small
                        perturb_prod = np.random.choice(nonzeroProd, len(nonzeroProd), replace=False).astype(int)
                        if len(perturb_prod) <= numProd:
                            pass
                        
                        k12=k23=k13 = self.luceGroup_nodeRatio
                        p12_1 = np.random.choice(perturb_prod[:n1], int(n1*k12) )
                        p12_2 = np.random.choice(perturb_prod[n1:-n1], int(n1*k12) )
                        p23_2 = np.random.choice(perturb_prod[n1:-n1], int(n1*k23) )
                        p23_3 = np.random.choice(perturb_prod[-n1:], int(n1*k23) )
                        p13_1 = np.random.choice(perturb_prod[:n1], int(n1*k13) )
                        p13_3 = np.random.choice(perturb_prod[-n1:], int(n1*k13) )
                        row = np.hstack([p12_1, p23_2, p13_1])
                        col = np.hstack([p12_2, p23_3, p13_3])
                        
                        adj_on_j = pd.concat([pd.Series(perturb_prod), pd.Series(row), pd.Series(col)], 
                                             axis=1, keys=['prodPerturb','row','col'])
                        ADJ_matrix['on{}'.format(j)] = adj_on_j

                    cstr_temp = ADJ_matrix
                    self.luce_info = tf.get_luceInfo(ADJ_matrix)
                
            Ex_Cstr_Dict[ex_c_name] = cstr_temp
        
        self.Ex_Cstr_Dict = Ex_Cstr_Dict
        
    def update(self):
        self.value_on_0 = np.ones(self.numCust) * self.v0_on

    def write_data_to_txt(self, filename):
        """
        write data to txt fle
        filename: the file name of .txt to be written
        BASIC PARAMETERS:
        DETAILED PARAMETERS: utilities vector, prices vector
        EXTRA CONSTRAINTS: graph's adjacency matrix for the 2SLM
        """
        with open(filename, 'w') as file:
            # Write probSetting_info
            file.write("BASIC PARAMETERS\n")
            file.write("numProd:\n" + str(self.numProd) + "\n")
            file.write("numCust:\n" + str(self.numCust) + "\n")
            file.write("arriveRatio_off:\n" + str(self.arriveRatio_off) + "\n")
            file.write("v0_off:\n" + str(self.v0_off) + "\n")
            file.write("v0_on:\n" + str(self.v0_on) + "\n")
            file.write("luce:\n" + str(self.luce) + "\n")
            file.write("kappaOff:\n" + str(self.kappaOff) + "\n")
            file.write("kappaOn:\n" + str(self.kappaOn) + "\n")
            file.write("seprate_tol:\n" + str(self.separate_tol) + "\n")

            file.write("DETAILED PARAMETERS\n")
            file.write("V_off_0:\n" + str(self.v0_off) + "\n")
            file.write("V_off:\n" + " ".join(map(str, self.value_off_v)) + "\n")
            file.write("V_on_0:\n" + " ".join(map(str, self.value_on_0)) + "\n")
            file.write("V_on:\n")
            for row in self.value_on_v:
                file.write(" ".join(map(str, row)) + "\n")

            file.write("R_off:\n" + " ".join(map(str, self.r_off[:, 0])) + "\n")
            file.write("R_on:\n")
            for row in self.r_on:
                file.write(" ".join(map(str, row)) + "\n")

  # def read_data_from_txt(self, filename):
  #     """
  #     to be done
  #     """
  #     # None

        
#%% model operations: define variables, add constraints
    
def define_varaiables(data, option, model, xType='C', xBoth=0):
    """
    Creat variables for "model".
    if xType='C', creat x_off as continuous variables, else as Binary variables.
    if xBoth=1, creat both x_off and x_on, else onle x_off.
    """
    # decompress data
    value_off_0 = data.value_off_0
    value_off_v = data.value_off_v
    value_on_0 = data.value_on_0
    value_on_v = data.value_on_v
    r_off = data.r_off
    r_on = data.r_on
    I = data.I
    J = data.J
    prod_cust = data.prod_cust
    numProd = data.numProd
    numCust = data.numCust
    
    if (data.kappaOff < 1) & ('CardiOff' in data.ExtraConstrList):
        koff  = data.Ex_Cstr_Dict['CardiOff'].iloc[:,0].values[0]
    else:
        koff = data.numProd
    if (data.kappaOn < 1) & ('CardiOn' in data.ExtraConstrList):
        kon = data.Ex_Cstr_Dict['CardiOn'].iloc[:,0].values
    else:
        kon = np.repeat(numProd, numCust)
    kon = np.array([min(int(koff), k) for k in kon])
    # define variables
    # improved-2
    y_off_0_l = 1/(value_off_0+sum(np.sort(value_off_v)[-koff:]))
    y_off_0_u = 1/(value_off_0)
    y_on_0_l = 1/(value_on_0+[sum(np.sort(value_on_v,axis=0)[-kon[i]:,i]) for i in range(numCust)])
    y_on_0_u = 1/(value_on_0)
    # improved-1
    y_off_0_l = 1/(value_off_0+sum(value_off_v))
    y_off_0_u = 1/(value_off_0)
    y_on_0_l = 1/(value_on_0+sum(value_on_v))
    y_on_0_u = 1/(value_on_0)
    
    x_off = model.addVars(I, lb=0, ub=1, vtype=xType, name='x_off')
    y_off_0 = model.addVar(lb=y_off_0_l, ub=y_off_0_u, name='y_off_0')
    y_off_y = model.addVars(I, lb=0, ub=y_off_0_u, name='y_off_y')
    y_on_0 = model.addVars(J, lb=y_on_0_l, ub=y_on_0_u, name='y_on_0')
    y_on_y = model.addVars(prod_cust, lb=0, ub=np.tile(y_on_0_u, (numProd,1)), name='y_on_y')
    
    model._x_off = x_off
    model._y_off_0 = y_off_0
    model._y_off_y = y_off_y
    model._y_on_0 = y_on_0
    model._y_on_y = y_on_y
    
    model._y_off_0_l = y_off_0_l
    model._y_off_0_u = y_off_0_u
    model._y_on_0_l = y_on_0_l
    model._y_on_0_u = y_on_0_u
    
    if option.MMNL == 1:
        model._x_on  = x_off
        
    elif xBoth == 1:
        x_on = model.addVars(prod_cust, lb=0, ub=1, vtype=xType, name='x_on')
        model._x_on  = x_on
        
    
    
    
    return model

def define_w(data, option, model, w=[0,0]):
    """
    Creat w variables for "model".
    w is list with length 2, indicating whether create variables for w_off and w_on
    """
    # decompress data
    value_off_0 = data.value_off_0
    value_off_v = data.value_off_v
    value_on_0 = data.value_on_0
    value_on_v = data.value_on_v
    
    if w[0] == 1:
        w_off = model.addVar(lb=value_off_0, name='w_off')
        # w_off = model.addVar(lb=value_off_0, ub=value_off_0+sum(value_off_v),name='w_off')
        model._w_off = w_off
    if w[1] == 1:
        w_on = model.addVars(data.J, lb=value_on_0, name='w_on')
        # w_on = model.addVars(data.J, lb=value_on_0, ub=value_on_0+value_on_v.sum(axis=0), name='w_on')
        model._w_on = w_on
        
    return model
    
def add_constraints(data, option, model, cstrName, PI_ineq=[0, 0]):
    """
    Creat constraints for "model".
    cstrName: constraint name to be created
    TODO: clean this and delete PI_ineq and its depedencies
    """
    # decompress data
    value_off_0 = data.value_off_0
    value_off_v = data.value_off_v
    value_on_0 = data.value_on_0
    value_on_v = data.value_on_v
    r_off = data.r_off
    r_on = data.r_on
    I = data.I
    J = data.J
    prod_cust = data.prod_cust
    numProd = data.numProd
    numCust = data.numCust
    
    # 
    if cstrName == 'prob_hyperplane':
        PiMap = lambda y0, y, u0, u: y0 * u0 + sum(y[i] * u[i] for i in range(len(y)))
        Pi_off_Expr = PiMap(model._y_off_0,
                            model._y_off_y,
                            value_off_0,
                            value_off_v)
        Pi_on_Expr = lambda j: PiMap(model._y_on_0[j], 
                                     model._y_on_y.select('*', j), 
                                     value_on_0[j], 
                                     value_on_v[:, j])
        if PI_ineq[0] == 0:
            HP_off = model.addConstr( Pi_off_Expr == 1, name='HP_off')
        elif PI_ineq[0] == 1:
            HP_off = model.addConstr( Pi_off_Expr >= 1, name='HP_off')
        elif PI_ineq[0] == -1:
            HP_off = model.addConstr( Pi_off_Expr <= 1, name='HP_off')
        
        if PI_ineq[1] == 0:
            HP_on = model.addConstrs((Pi_on_Expr(j) == 1 for j in J), name='HP_on')
        elif PI_ineq[1] == 1:
            HP_on = model.addConstrs((Pi_on_Expr(j) >= 1 for j in J), name='HP_on')
        elif PI_ineq[1] == -1:
            HP_on = model.addConstrs((Pi_on_Expr(j) <= 1 for j in J), name='HP_on')
        model._HP_off = HP_off
        model._HP_on = HP_on
        
    if cstrName == 'MC_BL_off':
        MC_offl1 = model.addConstrs(
            (model._y_off_y[i] <= model._y_off_0_l*(model._x_off[i]-1) + model._y_off_0 for i in data.I),
            name="MC_offl1")
        MC_offl2 = model.addConstrs(
            (model._y_off_y[i] <= model._y_off_0_u*model._x_off[i] for i in data.I), 
            name="MC_offl2")
        MC_offg1 = model.addConstrs(
            (model._y_off_y[i] >= model._y_off_0_u*(model._x_off[i]-1) + model._y_off_0 for i in data.I), 
            name="MC_offg1")
        MC_offg2 = model.addConstrs(
            (model._y_off_y[i] >= model._y_off_0_l*model._x_off[i] for i in data.I), 
            name="MC_offg2")
        model._MC_offl1 = MC_offl1
        model._MC_offl2 = MC_offl2
        model._MC_offg1 = MC_offg1
        model._MC_offg2 = MC_offg2
        
        if option.MMNL == 1:
            MC_onl1 = model.addConstrs(
                (model._y_on_y[i,j] <= model._y_on_0_l[j]*(model._x_off[i]-1) + model._y_on_0[j] 
                 for i in data.I for j in data.J), 
                name="MC_onl1")
            MC_onl2 = model.addConstrs(
                (model._y_on_y[i,j] <= model._y_on_0_u[j]*model._x_off[i]
                 for i in data.I for j in data.J), 
                name="MC_onl2")
            MC_ong1 = model.addConstrs(
                (model._y_on_y[i,j] >= model._y_on_0_u[j]*(model._x_off[i]-1) + model._y_on_0[j] 
                 for i in data.I for j in data.J), 
                name="MC_ong1")
            MC_ong2 = model.addConstrs(
                (model._y_on_y[i,j] >= model._y_on_0_l[j]*model._x_off[i]
                 for i in data.I for j in data.J), 
                name="MC_ong2")
            model._MC_onl1 = MC_onl1
            model._MC_onl2 = MC_onl2
            model._MC_ong1 = MC_ong1
            model._MC_ong2 = MC_ong2
        
    if cstrName == 'MC_BL_link':
        if option.MMNL == 0:
            MC_linkl1 = model.addConstrs(
                (model._y_on_y[i,j] <= model._y_on_0_l[j]*(model._x_off[i]-1) + model._y_on_0[j] 
                 for i in data.I for j in data.J), 
                name="MC_linkl1")
            MC_linkl2 = model.addConstrs(
                (model._y_on_y[i,j] <= model._y_on_0_u[j]*model._x_off[i] 
                 for i in data.I for j in data.J), 
                name="MC_linkl2")
            model._MC_linkl1 = MC_linkl1
            model._MC_linkl2 = MC_linkl2
        
    if cstrName == 'MC_BL_on':
        if option.MMNL == 0:
            MC_onl1 = model.addConstrs(
                (model._y_on_y[i,j] <= model._y_on_0_l[j]*(model._x_on[i,j]-1) + model._y_on_0[j] 
                 for i in data.I for j in data.J), 
                name="MC_onl1")
            MC_onl2 = model.addConstrs(
                (model._y_on_y[i,j] <= model._y_on_0_u[j]*model._x_on[i,j] 
                 for i in data.I for j in data.J), 
                name="MC_onl2")
            MC_ong1 = model.addConstrs(
                (model._y_on_y[i,j] >= model._y_on_0_u[j]*(model._x_on[i,j]-1) + model._y_on_0[j] 
                 for i in data.I for j in data.J), 
                name="MC_ong1")
            MC_ong2 = model.addConstrs(
                (model._y_on_y[i,j] >= model._y_on_0_l[j]*model._x_on[i,j] 
                 for i in data.I for j in data.J), 
                name="MC_ong2")
            model._MC_onl1 = MC_onl1
            model._MC_onl2 = MC_onl2
            model._MC_ong1 = MC_ong1
            model._MC_ong2 = MC_ong2
                
    if cstrName == 'moMC_BL_off':
        alp = tf.Alpha(value_off_0, value_off_v, value_on_0, value_on_v)
        MC_offl1 = model.addConstrs(
            (model._y_off_y[i] <=
                alp.compute(np.setdiff1d(I,i),-1)*(model._x_off[i]-1) + model._y_off_0 
             for i in data.I), 
            name="MC_off_cover_all-i")
        MC_offl2 = model.addConstrs(
            (model._y_off_y[i] <= alp.compute([i],-1)*model._x_off[i]
             for i in data.I), 
            name="MC_off_cover_i")
        MC_offg1 = model.addConstrs(
            (model._y_off_y[i] >= alp.compute(I,-1)*model._x_off[i] 
             for i in data.I), 
            name="MC_off_pack_all")
        MC_offg2 = model.addConstrs(
            (model._y_off_y[i] >= 
                 alp.compute([],-1)*(model._x_off[i]-1) + model._y_off_0 
             for i in data.I), 
            name="MC_off_pack_empty")
        model._MC_offl1 = MC_offl1
        model._MC_offl2 = MC_offl2
        model._MC_offg1 = MC_offg1
        model._MC_offg2 = MC_offg2
        
        if option.MMNL == 1:
            alp = tf.Alpha(value_off_0, value_off_v, value_on_0, value_on_v)
            MC_onl1 = model.addConstrs(
                (model._y_on_y[i,j] <= 
                     alp.compute(np.setdiff1d(I,i),j)*(model._x_off[i]-1) + model._y_on_0[j]
                 for i in data.I for j in J),
                name="MC_on_cover_all-i")
            MC_onl2 = model.addConstrs(
                (model._y_on_y[i,j] <= alp.compute([i],j)*model._x_off[i] 
                 for i in data.I for j in J), 
                name="MC_on_cover_i")
            MC_ong1 = model.addConstrs(
                (model._y_on_y[i,j] >= alp.compute(I,j)*model._x_off[i]
                 for i in data.I for j in J), 
                name="MC_on_pack_all")
            MC_ong2 = model.addConstrs(
                (model._y_on_y[i,j] >= 
                     alp.compute([],j)*(model._x_off[i]-1) + model._y_on_0[j]
                 for i in data.I for j in J), 
                name="MC_on_pack_empty")
            model._MC_onl1 = MC_onl1
            model._MC_onl2 = MC_onl2
            model._MC_ong1 = MC_ong1
            model._MC_ong2 = MC_ong2
        
    if cstrName == 'moMC_BL_link':
        if option.MMNL == 0:
            alp = tf.Alpha(value_off_0, value_off_v, value_on_0, value_on_v)
            MC_linkl1 = model.addConstrs(
                (model._y_on_y[i,j] <= 
                     alp.compute(np.setdiff1d(I,i),j)*(model._x_off[i]-1) + model._y_on_0[j]
                 for i in data.I for j in J),
                name="MC_link_cover_all-i")
            MC_linkl2 = model.addConstrs(
                (model._y_on_y[i,j] <= alp.compute([i],j)*model._x_off[i] 
                 for i in data.I for j in J), 
                name="MC_link_cover_i")
            model._MC_linkl1 = MC_linkl1
            model._MC_linkl2 = MC_linkl2
        
    if cstrName == 'moMC_BL_on':
        if option.MMNL == 0:
            alp = tf.Alpha(value_off_0, value_off_v, value_on_0, value_on_v)
            MC_onl1 = model.addConstrs(
                (model._y_on_y[i,j] <= 
                     alp.compute(np.setdiff1d(I,i),j)*(model._x_on[i,j]-1) + model._y_on_0[j]
                 for i in data.I for j in J),
                name="MC_on_cover_all-i")
            MC_onl2 = model.addConstrs(
                (model._y_on_y[i,j] <= alp.compute([i],j)*model._x_on[i,j] 
                 for i in data.I for j in J), 
                name="MC_on_cover_i")
            MC_ong1 = model.addConstrs(
                (model._y_on_y[i,j] >= alp.compute(I,j)*model._x_on[i,j]
                 for i in data.I for j in J), 
                name="MC_on_pack_all")
            MC_ong2 = model.addConstrs(
                (model._y_on_y[i,j] >= 
                     alp.compute([],j)*(model._x_on[i,j]-1) + model._y_on_0[j]
                 for i in data.I for j in J), 
                name="MC_on_pack_empty")
            model._MC_onl1 = MC_onl1
            model._MC_onl2 = MC_onl2
            model._MC_ong1 = MC_ong1
            model._MC_ong2 = MC_ong2
        
    if cstrName == 'cardimoMC_BL_off':
        # if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
        #     koff  = data.Ex_Cstr_Dict['CardiOff'].iloc[:,0].values[0]
        koff = data.Ex_Cstr_Dict['CardiOff'].iloc[:,0][0]
        alp = tf.Alpha(value_off_0, value_off_v, value_on_0, value_on_v)
        MC_offl1 = model.addConstrs(
            (model._y_off_y[i] <=
                alp.cardi_x0(koff,I,i,-1)*(model._x_off[i]-1) + model._y_off_0 
             for i in data.I), 
            name="cardimoMC_off_cover_all-i")
        MC_offl2 = model.addConstrs(
            (model._y_off_y[i] <= alp.compute([i],-1)*model._x_off[i]
             for i in data.I), 
            name="MC_off_cover_i")
        MC_offg1 = model.addConstrs(
            (model._y_off_y[i] >= alp.cardi_x1(koff,I,i,-1)*model._x_off[i] 
             for i in data.I), 
            name="cardimoMC_off_pack_all")
        MC_offg2 = model.addConstrs(
            (model._y_off_y[i] >= 
                 alp.compute([],-1)*(model._x_off[i]-1) + model._y_off_0 
             for i in data.I), 
            name="MC_off_pack_empty")
        model._MC_offl1 = MC_offl1
        model._MC_offl2 = MC_offl2
        model._MC_offg1 = MC_offg1
        model._MC_offg2 = MC_offg2
        
        if option.MMNL == 1:
            if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
                koff  = data.Ex_Cstr_Dict['CardiOff'].iloc[:,0].values[0]
            else:
                koff = data.numProd
            if (data.kappaOn < 1) & ("CardiOn" in data.ExtraConstrList):
                kon = data.Ex_Cstr_Dict['CardiOn'].iloc[:,0].values
            else:
                kon = np.repeat(numProd, numCust)
            kon = np.array([min(int(koff), k) for k in kon])
            alp = tf.Alpha(value_off_0, value_off_v, value_on_0, value_on_v)
            MC_onl1 = model.addConstrs(
                (model._y_on_y[i,j] <= 
                     alp.cardi_x0(kon[j],I,i,j)*(model._x_off[i]-1) + model._y_on_0[j]
                 for i in data.I for j in J),
                name="cardimoMC_on_cover_all-i")
            MC_onl2 = model.addConstrs(
                (model._y_on_y[i,j] <= alp.compute([i],j)*model._x_off[i] 
                 for i in data.I for j in J), 
                name="MC_on_cover_i")
            
            MC_ong1 = model.addConstrs(
                (model._y_on_y[i,j] >= alp.cardi_x1(kon[j],I,i,j)*model._x_off[i]
                 for i in data.I for j in J), 
                name="cardimoMC_on_pack_all")
            MC_ong2 = model.addConstrs(
                (model._y_on_y[i,j] >= 
                     alp.compute([],j)*(model._x_off[i]-1) + model._y_on_0[j]
                 for i in data.I for j in J), 
                name="MC_on_pack_empty")
            model._MC_onl1 = MC_onl1
            model._MC_onl2 = MC_onl2
            model._MC_ong1 = MC_ong1
            model._MC_ong2 = MC_ong2
        
    if cstrName == 'cardimoMC_BL_link':
        if option.MMNL == 0:
            if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
                koff  = data.Ex_Cstr_Dict['CardiOff'].iloc[:,0].values[0]
            else:
                koff = data.numProd
            if (data.kappaOn < 1) & ("CardiOn" in data.ExtraConstrList):
                kon = data.Ex_Cstr_Dict['CardiOn'].iloc[:,0].values
            else:
                kon = np.repeat(numProd, numCust)
            kon = np.array([min(int(koff), k) for k in kon])
            alp = tf.Alpha(value_off_0, value_off_v, value_on_0, value_on_v)
            MC_linkl1 = model.addConstrs(
                (model._y_on_y[i,j] <= 
                     alp.cardi_x0(kon[j],I,i,j)*(model._x_off[i]-1) + model._y_on_0[j]
                 for i in data.I for j in J),
                name="cardimoMC_link_cover_all-i")
            MC_linkl2 = model.addConstrs(
                (model._y_on_y[i,j] <= alp.compute([i],j)*model._x_off[i] 
                 for i in data.I for j in J), 
                name="MC_link_cover_i")
            model._MC_linkl1 = MC_linkl1
            model._MC_linkl2 = MC_linkl2
        
    if cstrName == 'cardimoMC_BL_on':
        if option.MMNL == 0:
            if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
                koff  = data.Ex_Cstr_Dict['CardiOff'].iloc[:,0].values[0]
            else:
                koff = data.numProd
            if (data.kappaOn < 1) & ("CardiOn" in data.ExtraConstrList):
                kon = data.Ex_Cstr_Dict['CardiOn'].iloc[:,0].values
            else:
                kon = np.repeat(numProd, numCust)
            kon = np.array([min(int(koff), k) for k in kon])
            alp = tf.Alpha(value_off_0, value_off_v, value_on_0, value_on_v)
            MC_onl1 = model.addConstrs(
                (model._y_on_y[i,j] <= 
                     alp.cardi_x0(kon[j],I,i,j)*(model._x_on[i,j]-1) + model._y_on_0[j]
                 for i in data.I for j in J),
                name="cardimoMC_on_cover_all-i")
            MC_onl2 = model.addConstrs(
                (model._y_on_y[i,j] <= alp.compute([i],j)*model._x_on[i,j] 
                 for i in data.I for j in J), 
                name="MC_on_cover_i")
            
            MC_ong1 = model.addConstrs(
                (model._y_on_y[i,j] >= alp.cardi_x1(kon[j],I,i,j)*model._x_on[i,j]
                 for i in data.I for j in J), 
                name="cardimoMC_on_pack_all")
            MC_ong2 = model.addConstrs(
                (model._y_on_y[i,j] >= 
                     alp.compute([],j)*(model._x_on[i,j]-1) + model._y_on_0[j]
                 for i in data.I for j in J), 
                name="MC_on_pack_empty")
            model._MC_onl1 = MC_onl1
            model._MC_onl2 = MC_onl2
            model._MC_ong1 = MC_ong1
            model._MC_ong2 = MC_ong2
        
    if cstrName == 'x_link':
        if option.MMNL == 0:
             x_link = model.addConstrs(
                 (model._x_off[i] >= model._x_on[i,j] 
                                        for i in data.I for j in data.J), 
                 name='x_link')
             model._x_link = x_link
         
         
    if cstrName == 'Conic_BL_off':
        model = define_w(data, option, model, w=[1,0])
        w_off = model._w_off
        
        conic_off1 = model.addConstrs(
            (model._x_off[i]**2 <= model._y_off_y[i] * w_off 
             for  i in data.I), 
            name='soc_off1')
        conic_off2 = model.addConstr(
            1 <= w_off * model._y_off_0, 
            name='soc_off2')
        
        w_off_eq = model.addConstr(
            w_off == value_off_0 
                        + grb.quicksum(value_off_v[i] * model._x_off[i] 
                                       for i in data.I), 
            name='w_off_eq')
        
        model._conic_off1 = conic_off1
        model._conic_off2 = conic_off2
        model._w_off_eq = w_off_eq
        
        if option.MMNL == 1:
            model = define_w(data, option, model, w=[0,1])
            w_on = model._w_on
            
            conic_on1 = model.addConstrs(
                (model._x_off[i]**2 <= model._y_on_y[i,j] * w_on[j] 
                 for  i in data.I for j in data.J), 
                name='soc_on1')
            conic_on2 = model.addConstrs(
                (1 <= w_on[j] * model._y_on_0[j] for j in data.J) , 
                name='soc_on2')   
            
            w_on_eq = model.addConstrs(
                (w_on[j] == value_on_0[j] 
                               + grb.quicksum(value_on_v[i,j] * model._x_off[i] 
                                              for i in data.I) 
                 for j in data.J), 
                name='w_on_eq')

            model._conic_on1 = conic_on1
            model._conic_on2 = conic_on2
            model._w_on_eq = w_on_eq
        
    if cstrName == 'Conic_BL_on':
        if option.MMNL == 0:
            model = define_w(data, option, model, w=[0,1])
            w_on = model._w_on
            
            conic_on1 = model.addConstrs(
                (model._x_on[i,j]**2 <= model._y_on_y[i,j] * w_on[j] 
                 for  i in data.I for j in data.J), 
                name='soc_on1')
            conic_on2 = model.addConstrs(
                (1 <= w_on[j] * model._y_on_0[j] for j in data.J) , 
                name='soc_on2')   
            
            w_on_eq = model.addConstrs(
                (w_on[j] == value_on_0[j] 
                               + grb.quicksum(value_on_v[i,j] * model._x_on[i,j] 
                                              for i in data.I) 
                 for j in data.J), 
                name='w_on_eq')

            model._conic_on1 = conic_on1
            model._conic_on2 = conic_on2
            model._w_on_eq = w_on_eq
    
    if cstrName == 'SOC_BL_off':
        model = define_w(data, option, model, w=[1,0])
        w_off = model._w_off
        
        conic_off2 = model.addConstr(
            1 <= w_off * model._y_off_0, 
            name='soc_off2')
        
        w_off_eq = model.addConstr(
            w_off == value_off_0 
                        + grb.quicksum(value_off_v[i] * model._x_off[i] 
                                       for i in data.I), 
            name='w_off_eq')
        
        model._conic_off2 = conic_off2
        model._w_off_eq = w_off_eq
        
        if option.MMNL == 1:
            model = define_w(data, option, model, w=[0,1])
            w_on = model._w_on
            
            conic_on2 = model.addConstrs(
                (1 <= w_on[j] * model._y_on_0[j] for j in data.J) , 
                name='soc_on2')   
            
            w_on_eq = model.addConstrs(
                (w_on[j] == value_on_0[j] 
                               + grb.quicksum(value_on_v[i,j] * model._x_off[i] 
                                              for i in data.I) 
                 for j in data.J), 
                name='w_on_eq')

            model._conic_on2 = conic_on2
            model._w_on_eq = w_on_eq
    
    if cstrName == 'SOC_BL_link':
        if option.MMNL == 0:
            model = define_w(data, option, model, w=[0,1])
            w_on = model._w_on
            
            conic_on2 = model.addConstrs(
                (1 <= w_on[j] * model._y_on_0[j] for j in data.J) , 
                name='soc_link2')   
            
            w_on_eq = model.addConstrs(
                (w_on[j] == value_on_0[j] 
                               + grb.quicksum(value_on_v[i,j] * model._x_off[i] 
                                              for i in data.I) 
                 for j in data.J), 
                name='w_link_eq')
            
            model._conic_on2 = conic_on2
            model._w_on_eq = w_on_eq
        
    if cstrName == 'SOC_BL_on':
        if option.MMNL == 0:
            model = define_w(data, option, model, w=[0,1])
            w_on = model._w_on
            
            conic_on2 = model.addConstrs(
                (1 <= w_on[j] * model._y_on_0[j] for j in data.J) , 
                name='soc_on2')   
            
            w_on_eq = model.addConstrs(
                (w_on[j] == value_on_0[j] 
                               + grb.quicksum(value_on_v[i,j] * model._x_on[i,j] 
                                              for i in data.I) 
                 for j in data.J), 
                name='w_on_eq')

            model._conic_on2 = conic_on2
            model._w_on_eq = w_on_eq
        
    if cstrName == 'bigM_BL_off':
        U = 1/value_off_0
        bigM_off1 = model.addConstrs((model._y_off_y[i] <= model._y_off_0
                                      for i in data.I), name='bigM_off_1')
        bigM_off2 = model.addConstrs((model._y_off_y[i] <= model._x_off[i] * U
                                      for i in data.I), name='bigM_off_2')
        bigM_off3 = model.addConstrs((model._y_off_y[i] >= model._y_off_0 - (1-model._x_off[i]) * U
                                      for i in data.I), name='bigM_off_3')
        model._bigM_off1 = bigM_off1
        model._bigM_off2 = bigM_off2
        model._bigM_off3 = bigM_off3
        
        if option.MMNL == 1:
            U = 1/value_on_0
            bigM_on1 = model.addConstrs((model._y_on_y[i,j] <= model._y_on_0[j]
                                          for i in data.I for j in data.J), name='bigM_on_1')
            bigM_on2 = model.addConstrs((model._y_on_y[i,j] <= model._x_off[i] * U[j]
                                          for i in data.I for j in data.J), name='bigM_on_2')
            bigM_on3 = model.addConstrs((model._y_on_y[i,j] >= model._y_on_0[j] - (1-model._x_off[i]) * U[j]
                                          for i in data.I for j in data.J), name='bigM_on_3')
            model._bigM_on1 = bigM_on1
            model._bigM_on2 = bigM_on2
            model._bigM_on3 = bigM_on3
        
    if cstrName == 'bigM_BL_link':
        if option.MMNL == 0:
            U = 1/value_on_0
            bigM_link1 = model.addConstrs((model._y_on_y[i,j] <= model._y_on_0[j]
                                          for i in data.I for j in data.J), name='bigM_link_1')
            bigM_link2 = model.addConstrs((model._y_on_y[i,j] <= model._x_off[i] * U[j]
                                          for i in data.I for j in data.J), name='bigM_link_2')
            bigM_link3 = model.addConstrs((model._y_on_y[i,j] >= model._y_on_0[j] - (1-model._x_off[i]) * U[j]
                                          for i in data.I for j in data.J), name='bigM_link_3')
            model._bigM_link1 = bigM_link1
            model._bigM_link2 = bigM_link2
            model._bigM_link3 = bigM_link3
        
    if cstrName == 'bigM_BL_on':
        if option.MMNL == 0:
            U = 1/value_on_0
            bigM_on1 = model.addConstrs((model._y_on_y[i,j] <= model._y_on_0[j]
                                          for i in data.I for j in data.J), name='bigM_on_1')
            bigM_on2 = model.addConstrs((model._y_on_y[i,j] <= model._x_on[i,j] * U[j]
                                          for i in data.I for j in data.J), name='bigM_on_2')
            bigM_on3 = model.addConstrs((model._y_on_y[i,j] >= model._y_on_0[j] - (1-model._x_on[i,j]) * U[j]
                                          for i in data.I for j in data.J), name='bigM_on_3')
            model._bigM_on1 = bigM_on1
            model._bigM_on2 = bigM_on2
            model._bigM_on3 = bigM_on3
        
    model.update()
    return model
            
def add_extra_constraints(data, option, model, extra_cstrName):
    """
    Add extrational constraints that rised from operations requirements.
    for 2 stage luce model: 
        "luce_onx": add 2slm constraint on x variable for the online chinnel
        "luce_onf": add 2slm constraint on F set for the online chinnel
    """
    # decompress data
    value_off_0 = data.value_off_0
    value_off_v = data.value_off_v
    value_on_0 = data.value_on_0
    value_on_v = data.value_on_v
    r_off = data.r_off
    r_on = data.r_on
    I = data.I
    J = data.J
    prod_cust = data.prod_cust
    numProd = data.numProd
    numCust = data.numCust
    
    if extra_cstrName.lower() in ['luce', 'luce_onx', 'luce_onf'] and data.luceType == 'Tree_oldStyle':
        row_ind = data.Ex_Cstr_Dict['Luce'].loc[:,('where','row')].dropna().astype('int')
        col_ind = data.Ex_Cstr_Dict['Luce'].loc[:,('where','col')].dropna().astype('int')
        Nodes_involved = data.Ex_Cstr_Dict['Luce'].loc[:,'Nodes_involved'].dropna().astype('int')
        involved_nodes_num = len(Nodes_involved)
        
        # nonzeros = np.nonzero(value_on_v)
        # loc = []
        # for i in range(np.count_nonzero(value_on_v)):
        #     loc.append(( nonzeros[0][i], nonzeros[1][i]) )
        # nonzeros = grb.tuplelist(loc)
        z_index = []
        for j in range(numCust):
            z_index = z_index + [(t, j) for t in Nodes_involved[j]]
        z_index = grb.tuplelist(z_index)
        z = model.addVars(z_index, lb=0, name='z')
        
        adj_matrix = np.zeros((involved_nodes_num, involved_nodes_num), dtype='int')
        adj_matrix[row_ind, col_ind] = 1
        reach_matrix, cover_matrix, minimal_nodes = tf.get_reach_cover_minomalNodes(adj_matrix)
        # reach_matrix = data.Ex_Cstr_Dict['Luce']['reach_matrix']
        # cover_matrix = data.Ex_Cstr_Dict['Luce']['cover_matrix']
        # minimal_nodes = data.Ex_Cstr_Dict['Luce']['minimal_nodes']
        if option.plot_network == 1:
            tf.plot_network(adj_matrix, cover_matrix)
        
        if extra_cstrName.lower() == 'luce_onf':
            DG = nx.from_numpy_array(adj_matrix, create_using=nx.DiGraph)
            roots  = [v for v, d in DG.in_degree() if d==0]
            leaves = [v for v, d in DG.out_degree() if d==0]
            all_paths = []
            for root in roots:
                paths = nx.all_simple_paths(DG, root, leaves)
                all_paths.extend(paths)
            
            if option.MMNL == 0:
                model.addConstrs((grb.quicksum(model._x_on.select(all_paths[p], j)) <= 1
                                  for p in range(len(all_paths)) ), 
                                  name='luce_onF_{}'.format(j))
            if option.MMNL == 1:
                model.addConstrs((grb.quicksum(model._x_off.select(all_paths[p])) <= 1
                                  for p in range(len(all_paths)) ), 
                                  name='luce_onF_{}'.format(j))
                
        elif extra_cstrName.lower == 'luce_onx':  
            if option.MMNL == 0:
                #  z upper bound
                model.addConstrs((z.select('*',j)[k] <= 1 for k in range(involved_nodes_num)) , name='luce_z_upperbond_{}'.format(j) )
                
                #  reaching, dorminance relationship
                ReachG = nx.from_numpy_array(reach_matrix, create_using=nx.DiGraph)
                reach_edges = ReachG.edges                    
                for l,r in reach_edges:
                    l_node = Nodes_involved[j][l]
                    r_node = Nodes_involved[j][r]
                    model.addConstr(z.select(l_node,j)[0] - z.select(r_node,j)[0] >= 0, name='luce_reaching_cstr_{}'.format(j))
                
                #  covering, cover relationship
                CoverG = nx.from_numpy_array(cover_matrix, create_using=nx.DiGraph)
                cover_edges = CoverG.edges
                for l,r in cover_edges:
                    l_node = Nodes_involved[j][l]
                    r_node = Nodes_involved[j][r]
                    model.addConstr(z.select(l_node,j)[0] - z.select(r_node,j)[0] >= model._x_on[l_node , j], name='luce_covering_cstr_{}'.format(j))
                
                #  minimal nodes
                for node in Nodes_involved[j][minimal_nodes]:
                    model.addConstr(model._x_on[node,j] == z.select(node, j)[0], name='luce_mininal_node_{}'.format(j))
            if option.MMNL == 1:
                #  z upper bound
                model.addConstrs((z.select('*',j)[k] <= 1 for k in range(involved_nodes_num)) , name='luce_z_upperbond_{}'.format(j) )
                
                #  reaching, dorminance relationship
                ReachG = nx.from_numpy_array(reach_matrix, create_using=nx.DiGraph)
                reach_edges = ReachG.edges                    
                for l,r in reach_edges:
                    l_node = Nodes_involved[j][l]
                    r_node = Nodes_involved[j][r]
                    model.addConstr(z.select(l_node,j)[0] - z.select(r_node,j)[0] >= 0, name='luce_reaching_cstr_{}'.format(j))
                
                #  covering, cover relationship
                CoverG = nx.from_numpy_array(cover_matrix, create_using=nx.DiGraph)
                cover_edges = CoverG.edges
                for l,r in cover_edges:
                    l_node = Nodes_involved[j][l]
                    r_node = Nodes_involved[j][r]
                    model.addConstr(z.select(l_node,j)[0] - z.select(r_node,j)[0] >= model._x_off[l_node], name='luce_covering_cstr_{}'.format(j))
                
                #  minimal nodes
                for node in Nodes_involved[j][minimal_nodes]:
                    model.addConstr(model._x_off[node] == z.select(node, j)[0], name='luce_mininal_node_{}'.format(j))
        else:
            if option.MMNL == 0:
                #  z upper bound
                model.addConstrs((z.select('*',j)[k] <= model._y_on_0[j] for k in range(involved_nodes_num)) , name='luce_z_upperbond_{}'.format(j) )
                
                #  reaching, dorminance relationship
                ReachG = nx.from_numpy_array(reach_matrix, create_using=nx.DiGraph)
                reach_edges = ReachG.edges
                for l,r in reach_edges:
                    l_node = Nodes_involved[j][l]
                    r_node = Nodes_involved[j][r]
                    model.addConstr(z.select(l_node,j)[0] - z.select(r_node,j)[0] >= 0, name='luce_reaching_cstr_{}'.format(j) )
                
                #  covering, cover relationship
                CoverG = nx.from_numpy_array(cover_matrix, create_using=nx.DiGraph)
                cover_edges = CoverG.edges
                for l,r in cover_edges:
                    l_node = Nodes_involved[j][l]
                    r_node = Nodes_involved[j][r]
                    model.addConstr(z.select(l_node,j)[0] - z.select(r_node,j)[0] >= model._y_on_y[l_node , j], name='luce_covering_cstr_{}'.format(j) )
                
                #  minimal nodes
                for node in Nodes_involved[j][minimal_nodes]:
                    model.addConstr(model._y_on_y[node,j] == z.select(node, j)[0], name='luce_mininal_node_{}'.format(j))
            if option.MMNL == 1:
                #  z upper bound
                model.addConstrs((z.select('*',j)[k] <= model._y_on_0[j] for k in range(involved_nodes_num)) , name='luce_z_upperbond_{}'.format(j) )
                
                #  reaching, dorminance relationship
                ReachG = nx.from_numpy_array(reach_matrix, create_using=nx.DiGraph)
                reach_edges = ReachG.edges
                for l,r in reach_edges:
                    l_node = Nodes_involved[j][l]
                    r_node = Nodes_involved[j][r]
                    model.addConstr(z.select(l_node,j)[0] - z.select(r_node,j)[0] >= 0, name='luce_reaching_cstr_{}'.format(j) )
                
                #  covering, cover relationship
                CoverG = nx.from_numpy_array(cover_matrix, create_using=nx.DiGraph)
                cover_edges = CoverG.edges
                for l,r in cover_edges:
                    l_node = Nodes_involved[j][l]
                    r_node = Nodes_involved[j][r]
                    model.addConstr(z.select(l_node,j)[0] - z.select(r_node,j)[0] >= model._y_on_y[l_node , j], name='luce_covering_cstr_{}'.format(j) )
                
                #  minimal nodes
                for node in Nodes_involved[j][minimal_nodes]:
                    model.addConstr(model._y_on_y[node,j] == z.select(node, j)[0], name='luce_mininal_node_{}'.format(j))
                
    elif extra_cstrName.lower() in ['luce', 'luce_onx', 'luce_onf'] and data.luceType in ['GroupPair', 'Tree']:
        z_index = []
        Nodes_involved = {}
        for j in range(numCust):
            row_ind = data.Ex_Cstr_Dict['Luce'].loc[:,('on{}'.format(j),'row')].dropna().astype('int')
            col_ind = data.Ex_Cstr_Dict['Luce'].loc[:,('on{}'.format(j),'col')].dropna().astype('int')
            Nodes_involved[j] = np.unique(np.hstack([row_ind,col_ind]))
            z_index = z_index + [(t, j) for t in Nodes_involved[j]]
        z_index = grb.tuplelist(z_index)
        z = model.addVars(z_index, lb=0, name='z')
        for j in range(numCust):
            row_ind = data.Ex_Cstr_Dict['Luce'].loc[:,('on{}'.format(j),'row')].dropna().astype('int')
            col_ind = data.Ex_Cstr_Dict['Luce'].loc[:,('on{}'.format(j),'col')].dropna().astype('int')
            nodes_perturb = data.Ex_Cstr_Dict['Luce'].loc[:,('on{}'.format(j),'prodPerturb')].dropna().astype('int')
            adj_matrix = np.zeros((numProd, numProd), dtype='int')
            adj_matrix[row_ind, col_ind] = 1
            reach_matrix, cover_matrix, minimal_nodes = tf.get_reach_cover_minomalNodes(adj_matrix)
            
            if option.plot_network == 1 and data.luceType == 'GroupPair':
                n1 = len(nodes_perturb)//3
                nodeGroup = [nodes_perturb[:n1], nodes_perturb[n1:-n1], nodes_perturb[-n1:]]
                tf.plot_network(adj_matrix, cover_matrix, luceType='GroupPair', nodeGroup=nodeGroup)
            if option.plot_network == 1 and data.luceType == 'Tree':
                nodeGroup = nodes_perturb
                tf.plot_network(adj_matrix, cover_matrix, luceType='Tree', nodeGroup=nodeGroup)
            
            if extra_cstrName.lower() == 'luce_onf':
                DG = nx.from_numpy_array(adj_matrix, create_using=nx.DiGraph)
                roots  = [v for v, d in DG.in_degree() if d==0]
                leaves = [v for v, d in DG.out_degree() if d==0]
                all_paths = []
                for root in roots:
                    paths = nx.all_simple_paths(DG, root, leaves)
                    all_paths.extend(paths)
                    
                if option.MMNL == 0:
                    model.addConstrs((grb.quicksum(model._x_on.select(all_paths[p], j)) <= 1
                                      for p in range(len(all_paths)) ), 
                                      name='luce_onF_{}'.format(j))
                if option.MMNL == 1:
                    model.addConstrs((grb.quicksum(model._x_off.select(all_paths[p])) <= 1
                                      for p in range(len(all_paths)) ), 
                                      name='luce_onF_{}'.format(j))
                
            elif extra_cstrName.lower() == 'luce_onx':  
                if option.MMNL == 0:
                    #  z upper bound
                    model.addConstrs((z.select('*',j)[k] <= 1 for k in range(len(z.select('*',j))) ) , name='luce_z_upperbond_{}'.format(j) )
                    
                    #  reaching, dorminance relationship
                    ReachG = nx.from_numpy_array(reach_matrix, create_using=nx.DiGraph)
                    reach_edges = ReachG.edges         
                    model.addConstrs((z.select(l_node,j)[0] - z.select(r_node,j)[0] >= 0
                                      for l_node,r_node in reach_edges),
                                      name='luce_reaching_cstr_{}'.format(j))
                    
                    #  covering, cover relationship
                    CoverG = nx.from_numpy_array(cover_matrix, create_using=nx.DiGraph)
                    cover_edges = CoverG.edges
                    model.addConstrs((z.select(l_node,j)[0] - z.select(r_node,j)[0] >= model._x_on[l_node , j]
                                    for l_node,r_node in cover_edges),
                                    name='luce_covering_cstr_{}'.format(j) )
                    
                    #  minimal nodes
                    model.addConstrs((model._x_on[node,j] == z.select(node, j)[0] 
                                      for node in minimal_nodes), 
                                      name='luce_mininal_node_{}'.format(j))
                if option.MMNL == 1:
                    #  z upper bound
                    model.addConstrs((z.select('*',j)[k] <= 1 for k in range(len(z.select('*',j))) ) , name='luce_z_upperbond_{}'.format(j) )
                    
                    #  reaching, dorminance relationship
                    ReachG = nx.from_numpy_array(reach_matrix, create_using=nx.DiGraph)
                    reach_edges = ReachG.edges         
                    model.addConstrs((z.select(l_node,j)[0] - z.select(r_node,j)[0] >= 0
                                      for l_node,r_node in reach_edges),
                                      name='luce_reaching_cstr_{}'.format(j))
                    
                    #  covering, cover relationship
                    CoverG = nx.from_numpy_array(cover_matrix, create_using=nx.DiGraph)
                    cover_edges = CoverG.edges
                    model.addConstrs((z.select(l_node,j)[0] - z.select(r_node,j)[0] >= model._x_off[l_node]
                                    for l_node,r_node in cover_edges),
                                    name='luce_covering_cstr_{}'.format(j) )
                    
                    #  minimal nodes
                    model.addConstrs((model._x_off[node] == z.select(node, j)[0] 
                                      for node in minimal_nodes), 
                                      name='luce_mininal_node_{}'.format(j))
            else:
                if option.MMNL == 0:
                    #  z upper bound
                    model.addConstrs((z.select('*',j)[k] <= model._y_on_0[j] for k in  range(len(z.select('*',j))) ) , name='luce_z_upperbond_{}'.format(j) )
                    
                    #  reaching, dorminance relationship
                    ReachG = nx.from_numpy_array(reach_matrix, create_using=nx.DiGraph)
                    reach_edges = ReachG.edges
                    model.addConstrs((z.select(l_node,j)[0] - z.select(r_node,j)[0] >= 0
                                      for l_node,r_node in reach_edges), 
                                      name='luce_reaching_cstr_{}'.format(j) )
                    # for reaching in Nodes_involved[j][reach_edges]:
                    #     print(reaching)
                    #     model.addConstr(z.select(reaching[0],j)[0] - z.select(reaching[1],j)[0] >= 0, name='luce_reaching_cstr' )
                    
                    #  covering, cover relationship
                    CoverG = nx.from_numpy_array(cover_matrix, create_using=nx.DiGraph)
                    cover_edges = CoverG.edges
                    model.addConstrs((z.select(l_node,j)[0] - z.select(r_node,j)[0] >= model._y_on_y[l_node , j]
                                      for l_node,r_node in cover_edges), 
                                      name='luce_covering_cstr_{}'.format(j) )
                    
                    #  minimal nodes
                    model.addConstrs((model._y_on_y[node,j] == z.select(node, j)[0]
                                      for node in minimal_nodes), name='luce_mininal_node_{}'.format(j))
                if option.MMNL == 1:
                    #  z upper bound
                    model.addConstrs((z.select('*',j)[k] <= model._y_on_0[j] for k in  range(len(z.select('*',j))) ) , name='luce_z_upperbond_{}'.format(j) )
                    
                    #  reaching, dorminance relationship
                    ReachG = nx.from_numpy_array(reach_matrix, create_using=nx.DiGraph)
                    reach_edges = ReachG.edges
                    model.addConstrs((z.select(l_node,j)[0] - z.select(r_node,j)[0] >= 0
                                      for l_node,r_node in reach_edges), 
                                      name='luce_reaching_cstr_{}'.format(j) )
                    # for reaching in Nodes_involved[j][reach_edges]:
                    #     print(reaching)
                    #     model.addConstr(z.select(reaching[0],j)[0] - z.select(reaching[1],j)[0] >= 0, name='luce_reaching_cstr' )
                    
                    #  covering, cover relationship
                    CoverG = nx.from_numpy_array(cover_matrix, create_using=nx.DiGraph)
                    cover_edges = CoverG.edges
                    model.addConstrs((z.select(l_node,j)[0] - z.select(r_node,j)[0] >= model._y_on_y[l_node , j]
                                      for l_node,r_node in cover_edges), 
                                      name='luce_covering_cstr_{}'.format(j) )
                    
                    #  minimal nodes
                    model.addConstrs((model._y_on_y[node,j] == z.select(node, j)[0]
                                      for node in minimal_nodes), name='luce_mininal_node_{}'.format(j))
    
            

    elif extra_cstrName.lower() in ['cardioff', 'cardion', 'cardion_onx' ]:
        if option.MMNL == 0:
            if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
                koff  = data.Ex_Cstr_Dict['CardiOff'].iloc[:,0].values[0]
            else:
                koff = data.numProd
            if (data.kappaOn < 1) & ("CardiOn" in data.ExtraConstrList):
                kon = data.Ex_Cstr_Dict['CardiOn'].iloc[:,0].values
            else:
                kon = np.repeat(numProd, numCust)
            kon = np.array([min(int(koff), k) for k in kon])
            
            if extra_cstrName.lower() == 'cardioff':
                model.addConstr(grb.quicksum(model._x_off) <= koff, name='CardiOff')
            if extra_cstrName.lower() == 'cardion':
                model.addConstrs((grb.quicksum(model._y_on_y.select('*',j)) <= kon[j]*model._y_on_0[j] for j in data.J), name='CardiOn')
            if extra_cstrName.lower() == 'cardion_onx':
                model.addConstrs((grb.quicksum(model._x_on.select('*',j)) <= kon[j] for j in data.J), name='CardiOn_onX')
        if option.MMNL == 1:
            if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
                koff  = data.Ex_Cstr_Dict['CardiOff'].iloc[:,0].values[0]
            else:
                koff = data.numProd
            if (data.kappaOn < 1) & ("CardiOn" in data.ExtraConstrList):
                kon = data.Ex_Cstr_Dict['CardiOn'].iloc[:,0].values
            else:
                kon = np.repeat(numProd, numCust)
            kon = np.array([min(int(koff), k) for k in kon])
            
            if extra_cstrName.lower() == 'cardioff':
                model.addConstr(grb.quicksum(model._x_off) <= koff, name='CardiOff')
            if extra_cstrName.lower() == 'cardion':
                model.addConstrs((grb.quicksum(model._y_on_y.select('*',j)) <= kon[j]*model._y_on_0[j] for j in data.J), name='CardiOn')
            if extra_cstrName.lower() == 'cardion_onx':
                model.addConstrs((grb.quicksum(model._x_off.select('*')) <= kon[j] for j in data.J), name='CardiOn_onX')
    
    
    elif extra_cstrName.lower()  in ['knapsackoff', 'knapsackon', 'knapsackoff_onx', 'knapsackon_onx' ]:
        if option.MMNL == 0:
            weight_space  = data.Ex_Cstr_Dict['KnapsackOff'].values
            weight = weight_space[:,:numProd]
            space = weight.sum(1) * weight_space[:,-1]
            dim = weight.shape[0]
            if  extra_cstrName.lower() == 'knapsackoff':
                model.addConstrs((grb.quicksum(weight[k, i] * model._x_off[i] for i in data.I) <= space[k] for k in range(dim)), name="KnapsackOff" )
            # if  extra_cstrName.lower() == 'knapsackoff':
            #     model.addConstrs((grb.quicksum(weight[i, :] * model._y_off_y) <= space[i]*model._y_off_0 for i in range(dim)), name="KnapsackOff" )
        
        
        
    return model


def get_obj_express(data, option, model):
    value_off_0 = data.value_off_0
    value_off_v = data.value_off_v
    value_on_0 = data.value_on_0
    value_on_v = data.value_on_v
    r_off = data.r_off
    r_on = data.r_on
    I = data.I
    J = data.J
    
    arriveRatio_off = data.arriveRatio[0]/ (data.arriveRatio[0] + data.arriveRatio[1])
    arriveRatio_on  = data.arriveRatio[1]/ (data.arriveRatio[0] + data.arriveRatio[1])
    arriveRatio_on  = np.repeat(arriveRatio_on, data.numCust )/data.numCust
            
    revenue_off = arriveRatio_off * sum(model._y_off_y[i] * r_off[i] * value_off_v[i] for i in I)
    revenue_on  = sum(arriveRatio_on[j] * model._y_on_y[i, j] * r_on[i, j] * value_on_v[i,j] for i in I for j in J)
    
    r_off_max = r_off.max()*1
    r_off_tilde = r_off - r_off_max
    r_on_max = r_on.max(0)*1
    r_on_tilde = r_on - r_on_max
    revenue_off_conic = arriveRatio_off * r_off_max\
                        - arriveRatio_off * r_off_max * model._y_off_0 * value_off_0\
                        + arriveRatio_off * sum(model._y_off_y[i] * r_off_tilde[i] * value_off_v[i] for i in I)
    revenue_on_conic = sum(arriveRatio_on[j] * r_on_max[j]\
                        - arriveRatio_on[j] * r_on_max[j] * model._y_on_0[j] * value_on_0[j]\
                        + arriveRatio_on[j] * sum(model._y_on_y[i, j] * r_on_tilde[i, j] * value_on_v[i,j] for i in I) for j in J)
    
    model._revenue_off = revenue_off
    model._revenue_on = revenue_on
    return revenue_off, revenue_on, revenue_off_conic, revenue_on_conic
    
#%% instance building
class Instance(Data, Option):
    """build (rebuild) and solve model"""
    def __init__(self, data, option):
        ####### control parameters
        self.option = option
        self.data = data
        
        # ####### control parameters
        # self.para_randomData = option.para_randomData
        # self.para_relaxModel = option.para_relaxModel

        # ######## generate problem data
        self.value_off_0 = data.value_off_0
        self.value_off_v = data.value_off_v
        self.value_on_0 = data.value_on_0
        self.value_on_v = data.value_on_v
        self.r_off = data.r_off
        self.r_on = data.r_on
        self.numProd = data.numProd
        self.numCust = data.numCust
        self.I = grb.tuplelist(range(data.numProd))  # index set of products
        self.J = grb.tuplelist(range(data.numCust))  # index set of online-customer type
        arriveRatio_off = data.arriveRatio[0]/ (data.arriveRatio[0] + data.arriveRatio[1])
        arriveRatio_on  = data.arriveRatio[1]/ (data.arriveRatio[0] + data.arriveRatio[1])
        self.arriveRatio_off = arriveRatio_off
        self.arriveRatio_on  = np.repeat(arriveRatio_on, data.numCust )/data.numCust
        
        self.Sols = pd.DataFrame() 
        self.modelStatus = ''
        self.modelName = ''
        self.gotResult = 0
        
        self.Model_history = {}

    
    def MC_MC(self, xType='C', mMC='', soc=''):
        data = self.data
        option = self.option
        if mMC == 'mo' and option.cardiMC == 1:
            if (data.kappaOn < 1) & ('CardiOn' in data.ExtraConstrList):
                mMCOn = 'cardi'+mMC
            else:
                mMCOn = mMC
            if (data.kappaOff < 1) & ('CardiOff' in data.ExtraConstrList):
                mMCOff = 'cardi'+mMC
                mMCOn = 'cardi'+mMC
            else:
                mMCOff = mMC
        else:
            mMCOff = mMCOn = mMC
        
        ################ creat a model ##############################
        name="MC_MC-"+mMCOff+mMCOn+soc+"-"+xType
        model = grb.Model(name=name)
        model.setParam('OutputFlag', option.grb_para_OutputFlag)
        model.setParam('TimeLimit', option.grb_para_timelimit)
        # model.setParam('FeasibilityTol', 1e-06)

        ################ define variables ###########################
        model = define_varaiables(data, option, model, xType, xBoth=1)
        
        ################ add constraints ############################
        # probability hyperplane
        model = add_constraints(data, option, model, "prob_hyperplane", PI_ineq=(0,0))
        ## modified MC relaxation for 'BL_off'
        model = add_constraints(data, option, model, mMCOff+"MC_BL_off")
        # x link
        model = add_constraints(data, option, model, "x_link")
        # MC relaxation for 'BL_online'
        model = add_constraints(data, option, model, mMCOn+"MC_BL_on")
        if soc == 'soc': 
            ## second order cone for 'BL_off'
            model = add_constraints(data, option, model, "SOC_BL_off")
            ## second order cone for 'BL_link'
            model = add_constraints(data, option, model, "SOC_BL_on")
        # Extend Constraints 
        if (data.luce == 1) & ('Luce' in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="Luce_onX")
        if (data.kappaOff < 1) & ('CardiOff' in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="CardiOff")
        if (data.kappaOn < 1) & ('CardiOn' in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="CardiOn_onX")
        if (data.knapsackOff > 0) & ('KnapsackOff' in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="KnapsackOff")
    
        ################ set objective function  #############
        revenue_off, revenue_on, revenue_off_conic, revenue_on_conic = get_obj_express(data, option, model)
        obj_express = revenue_off + revenue_on
        
        model.setObjective(obj_express, sense=grb.GRB.MAXIMIZE)
        
        model.update()
        self.model = model
        self.modelName = name
    
    
    def MC_Conv(self, xType='C', mMC='', soc=''):
        data = self.data
        option = self.option
        if mMC == 'mo' and option.cardiMC == 1:
            if (data.kappaOn < 1) & ('CardiOn' in data.ExtraConstrList):
                mMCOn = 'cardi'+mMC
            else:
                mMCOn = mMC
            if (data.kappaOff < 1) & ('CardiOff' in data.ExtraConstrList):
                mMCOff = 'cardi'+mMC
                mMCOn = 'cardi'+mMC
            else:
                mMCOff = mMC
        else:
            mMCOff = mMCOn = mMC
        
        ################ creat a model ##############################
        name="MC_Conv-"+mMCOff+mMCOn+soc+"-"+xType
        model = grb.Model(name=name)
        model.setParam('OutputFlag', option.grb_para_OutputFlag)
        model.setParam('TimeLimit', option.grb_para_timelimit)
        # model.setParam('FeasibilityTol', 1e-06)

        ################ define variables ###########################
        model = define_varaiables(data, option, model, xType, xBoth=0)
        
        ################ add constraints ############################
        # probability hyperplane
        model = add_constraints(data, option, model, "prob_hyperplane", PI_ineq=(0,0))
        ## MC relaxation for 'BL_off'
        model = add_constraints(data, option, model, mMCOff+"MC_BL_off")
        ## MC relaxation for 'BL_link'
        model = add_constraints(data, option, model, mMCOn+"MC_BL_link")
        if soc == 'soc': 
            ## second order cone for 'BL_off'
            model = add_constraints(data, option, model, "SOC_BL_off")
            ## second order cone for 'BL_link'
            model = add_constraints(data, option, model, "SOC_BL_link")
        # Extend Constraints 
        if (data.luce ==  1) & ('Luce' in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="Luce")
        if (data.kappaOff < 1) & ('CardiOff' in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="CardiOff")
        if (data.kappaOn < 1) & ('CardiOn' in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="CardiOn")
        if (data.knapsackOff > 0) & ('KnapsackOff' in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="KnapsackOff")


        ################ set objective function  #############
        revenue_off, revenue_on, revenue_off_conic, revenue_on_conic = get_obj_express(data, option, model)
        obj_express = revenue_off + revenue_on
        
        model.setObjective(obj_express, sense=grb.GRB.MAXIMIZE)
        
        model.update()
        self.model = model
        self.modelName = name

    
    def MC_Conic(self, xType='C', mMC='', soc=''):
        data = self.data
        option = self.option
        if mMC == 'mo' and option.cardiMC == 1:
            if (data.kappaOn < 1) & ('CardiOn' in data.ExtraConstrList):
                mMCOn = 'cardi'+mMC
            else:
                mMCOn = mMC
            if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
                mMCOff = 'cardi'+mMC
                mMCOn = 'cardi'+mMC
            else:
                mMCOff = mMC
        else:
            mMCOff = mMCOn = mMC
        
        ################ creat a model ##############################
        name="MC_Conic-"+mMCOff+mMCOn+soc+"-"+xType
        model = grb.Model(name=name)
        model.setParam('OutputFlag', option.grb_para_OutputFlag)
        model.setParam('TimeLimit', option.grb_para_timelimit)
        # model.setParam('FeasibilityTol', 1e-06)

        ################ define variables ###########################
        model = define_varaiables(data, option, model, xType, xBoth=1)
        
        ################ add constraints ############################
        # probability hyperplane
        model = add_constraints(data, option, model, "prob_hyperplane", PI_ineq=(0,1))
        ## modified MC relaxation for 'BL_off'
        model = add_constraints(data, option, model, mMCOff+"MC_BL_off")
        # x link
        model = add_constraints(data, option, model, "x_link")
        # MC relaxation for 'BL_online'
        model = add_constraints(data, option, model, mMCOn+"MC_BL_on")
        # conic for 'BL_online'
        model = add_constraints(data, option, model, "Conic_BL_on")
        if soc == 'soc': 
            ## second order cone for 'BL_off'
            model = add_constraints(data, option, model, "SOC_BL_off")
            ## second order cone for 'BL_online'
            # model = add_constraints(data, option, model, "SOC_BL_on")
        # Extend Constraints 
        if (data.luce ==  1) & ('Luce' in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="Luce_onX")
        if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="CardiOff")
        if (data.kappaOn < 1) & ("CardiOn" in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="CardiOn_onX")
        if (data.knapsackOff > 0) & ('KnapsackOff' in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="KnapsackOff")
    
        ################ set objective function  #############
        revenue_off, revenue_on, revenue_off_conic, revenue_on_conic = get_obj_express(data, option, model)
        obj_express = revenue_off + revenue_on_conic
        
        model.setObjective(obj_express, sense=grb.GRB.MAXIMIZE)
        
        model.update()
        self.model = model
        self.modelName = name
        
        
    def Conic_MC(self, xType='C', mMC='', soc=''):
        data = self.data
        option = self.option
        if mMC == 'mo' and option.cardiMC == 1:
            if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
                mMCOff = 'cardi'+mMC
            else:
                mMCOff = mMC
            if (data.kappaOn < 1) & ("CardiOn" in data.ExtraConstrList):
                mMCOn = 'cardi'+mMC
            else:
                mMCOn = mMC
        else:
            mMCOff = mMCOn = mMC
        
        ################ creat a model ##############################
        name = "Conic_MC-"+mMCOff+mMCOn+soc+"-"+xType
        model = grb.Model(name=name)
        model.setParam('OutputFlag', option.grb_para_OutputFlag)
        model.setParam('TimeLimit', option.grb_para_timelimit)
        # model.setParam('FeasibilityTol', 1e-06)

        ################ define variables ###########################
        model = define_varaiables(data, option, model, xType, xBoth=1 )
        
        ################ add constraints ############################
        # probability hyperplane
        model = add_constraints(data, option, model, "prob_hyperplane", PI_ineq=(1,0))
        ## modified MC relaxation for 'BL_off'
        model = add_constraints(data, option, model, mMCOff+"MC_BL_off")
        # conic for 'BL_off'
        model = add_constraints(data, option, model, "Conic_BL_off")
        # x link
        model = add_constraints(data, option, model, "x_link")
        # MC relaxation for 'BL_online'
        model = add_constraints(data, option, model, mMCOn+"MC_BL_on")
        # conic for 'BL_online'
        # model = add_constraints(data, option, model, "Conic_BL_on")
        if soc == 'soc': 
            ## second order cone for 'BL_off'
            # model = add_constraints(data, option, model, "SOC_BL_off")
            ## second order cone for 'BL_online'
            model = add_constraints(data, option, model, "SOC_BL_on")
        # Extend Constraints 
        if (data.luce ==  1) & ('Luce' in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="Luce")
        if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="CardiOff")
        if (data.kappaOn < 1) & ("CardiOn" in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="CardiOn")
        if (data.knapsackOff > 0) & ('KnapsackOff' in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="KnapsackOff")


        ################ set objective function  #############
        revenue_off, revenue_on, revenue_off_conic, revenue_on_conic = get_obj_express(data, option, model)
        obj_express = revenue_off_conic + revenue_on
        
        model.setObjective(obj_express, sense=grb.GRB.MAXIMIZE)
        
        # model.setParam("BarQCPConvTol", 1e-4)
        
        model.update()
        self.model = model
        self.modelName = name
        
        
    def Conic_Conv(self, xType='C', mMC='', soc=''):
        data = self.data
        option = self.option
        if mMC == 'mo' and option.cardiMC == 1:
            if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
                mMCOff = 'cardi'+mMC
            else:
                mMCOff = mMC
            if (data.kappaOn < 1) & ("CardiOn" in data.ExtraConstrList):
                mMCOn = 'cardi'+mMC
            else:
                mMCOn = mMC
        else:
            mMCOff = mMCOn = mMC
        
        ################ creat a model ##############################
        name="Conic_Conv-"+mMCOff+mMCOn+soc+"-"+xType
        model = grb.Model(name=name)
        model.setParam('OutputFlag', option.grb_para_OutputFlag)
        model.setParam('TimeLimit', option.grb_para_timelimit)
        # model.setParam('FeasibilityTol', 1e-06)

        ################ define variables ###########################
        model = define_varaiables(data, option, model, xType, xBoth=0 )
        
        ################ add constraints ############################
        # probability hyperplane
        model = add_constraints(data, option, model, "prob_hyperplane", PI_ineq=(1,0))
        ## modified MC relaxation for 'BL_off'
        model = add_constraints(data, option, model, mMCOff+"MC_BL_off")
        # conic for 'BL_off'
        model = add_constraints(data, option, model, "Conic_BL_off")
        ## MC relaxation for 'BL_link'
        model = add_constraints(data, option, model, mMCOn+"MC_BL_link")
        if soc == 'soc': 
            ## second order cone for 'BL_off'
            # model = add_constraints(data, option, model, "SOC_BL_off")
            ## second order cone for 'BL_online'
            model = add_constraints(data, option, model, "SOC_BL_link")
        # Extend Constraints 
        if (data.luce ==  1) & ('Luce' in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="Luce")
        if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="CardiOff")
        if (data.kappaOn < 1) & ("CardiOn" in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="CardiOn")
        if (data.knapsackOff > 0) & ('KnapsackOff' in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="KnapsackOff")


        ################ set objective function  #############
        revenue_off, revenue_on, revenue_off_conic, revenue_on_conic = get_obj_express(data, option, model)
        obj_express = revenue_off_conic + revenue_on
        
        model.setObjective(obj_express, sense=grb.GRB.MAXIMIZE)
        
        # model.setParam("BarQCPConvTol", 1e-4)
        
        model.update()
        self.model = model
        self.modelName = name
        
        
    def Conic_Conic(self, xType='C', mMC='', soc=''):
        data = self.data
        option = self.option
        if mMC == 'mo' and option.cardiMC == 1:
            if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
                mMCOff = 'cardi'+mMC
            else:
                mMCOff = mMC
            if (data.kappaOn < 1) & ("CardiOn" in data.ExtraConstrList):
                mMCOn = 'cardi'+mMC
            else:
                mMCOn = mMC
        else:
            mMCOff = mMCOn = mMC
            
        ################ creat a model ##############################
        name="Conic_Conic-"+mMCOff+mMCOn+soc+"-"+xType
        model = grb.Model(name=name)
        model.setParam('OutputFlag', option.grb_para_OutputFlag)
        model.setParam('TimeLimit', option.grb_para_timelimit)
        # model.setParam('FeasibilityTol', 1e-06)

        ################ define variables ###########################
        model = define_varaiables(data, option, model, xType, xBoth=1 )
        
        ################ add constraints ############################
        # probability hyperplane
        model = add_constraints(data, option, model, "prob_hyperplane", PI_ineq=(1,1))
        ## modified MC relaxation for 'BL_off'
        model = add_constraints(data, option, model, mMCOff+"MC_BL_off")
        # conic for 'BL_off'
        model = add_constraints(data, option, model, "Conic_BL_off")
        # x link
        model = add_constraints(data, option, model, "x_link")
        # MC relaxation for 'BL_online'
        model = add_constraints(data, option, model, mMCOn+"MC_BL_on")
        # conic for 'BL_online'
        model = add_constraints(data, option, model, "Conic_BL_on")
        if soc == 'soc': 
            ## second order cone for 'BL_off'
            # model = add_constraints(data, option, model, "SOC_BL_off")
            ## second order cone for 'BL_online'
            model = add_constraints(data, option, model, "SOC_BL_on")
        # Extend Constraints 
        if (data.luce ==  1) & ('Luce' in data.ExtraConstrList):
            # model = add_extra_constraints(data, option, model, extra_cstrName="Luce_onF")
            model = add_extra_constraints(data, option, model, extra_cstrName="Luce_onX")
        if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="CardiOff")
        if (data.kappaOn < 1) & ("CardiOn" in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="CardiOn_onX")
        if (data.knapsackOff > 0) & ('KnapsackOff' in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="KnapsackOff")


        ################ set objective function  #############
        revenue_off, revenue_on, revenue_off_conic, revenue_on_conic = get_obj_express(data, option, model)
        obj_express = revenue_off_conic + revenue_on_conic
        
        model.setObjective(obj_express, sense=grb.GRB.MAXIMIZE)
        
        # model.setParam("BarQCPConvTol", 1e-4)
        
        
        model.update()
        self.model = model
        self.modelName = name

    def MILP(self, xType='C', mMC='', soc=''):
        data = self.data
        option = self.option
        if mMC == 'mo' and option.cardiMC == 1:
            if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
                mMCOff = 'cardi'+mMC
            else:
                mMCOff = mMC
            if (data.kappaOn < 1) & ("CardiOn" in data.ExtraConstrList):
                mMCOn = 'cardi'+mMC
            else:
                mMCOn = mMC
        else:
            mMCOff = mMCOn = mMC
            
        ################ creat a model ##############################
        name="MILP-"+mMCOff+mMCOn+soc+"-"+xType
        model = grb.Model(name=name)
        model.setParam('OutputFlag', option.grb_para_OutputFlag)
        model.setParam('TimeLimit', option.grb_para_timelimit)
        # model.setParam('FeasibilityTol', 1e-06)

        ################ define variables ###########################
        model = define_varaiables(data, option, model, xType, xBoth=1 )
        
        ################ add constraints ############################
        # probability hyperplane
        model = add_constraints(data, option, model, "prob_hyperplane", PI_ineq=(0,0))
        # bigM for relaxation for 'BL_off'
        model = add_constraints(data, option, model, "bigM_BL_off")
        # x link
        model = add_constraints(data, option, model, "x_link")
        # bigM for relaxation for 'BL_on'
        model = add_constraints(data, option, model, "bigM_BL_on")
        
        ## modified MC relaxation for 'BL_off'
        # model = add_constraints(data, option, model, mMCOff+"MC_BL_off")
        # conic for 'BL_off'
        # model = add_constraints(data, option, model, "Conic_BL_off")
        
        # MC relaxation for 'BL_online'
        # model = add_constraints(data, option, model, mMCOn+"MC_BL_on")
        # conic for 'BL_online'
        # model = add_constraints(data, option, model, "Conic_BL_on")
        # if soc == 'soc': 
            ## second order cone for 'BL_off'
            # model = add_constraints(data, option, model, "SOC_BL_off")
            ## second order cone for 'BL_online'
            # model = add_constraints(data, option, model, "SOC_BL_on")
        # Extend Constraints 
        if (data.luce ==  1) & ('Luce' in data.ExtraConstrList):
            # model = add_extra_constraints(data, option, model, extra_cstrName="Luce_onF")
            model = add_extra_constraints(data, option, model, extra_cstrName="Luce_onX")
        if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="CardiOff")
        if (data.kappaOn < 1) & ("CardiOn" in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="CardiOn_onX")
        if (data.knapsackOff > 0) & ('KnapsackOff' in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="KnapsackOff")


        ################ set objective function  #############
        revenue_off, revenue_on, revenue_off_conic, revenue_on_conic = get_obj_express(data, option, model)
        obj_express = revenue_off + revenue_on
        
        model.setObjective(obj_express, sense=grb.GRB.MAXIMIZE)
        
        # model.setParam("BarQCPConvTol", 1e-4)
        
        
        model.update()
        self.model = model
        self.modelName = name
        
    def MILP2(self, xType='C', mMC='', soc=''):
        data = self.data
        option = self.option
        if mMC == 'mo' and option.cardiMC == 1:
            if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
                mMCOff = 'cardi'+mMC
            else:
                mMCOff = mMC
            if (data.kappaOn < 1) & ("CardiOn" in data.ExtraConstrList):
                mMCOn = 'cardi'+mMC
            else:
                mMCOn = mMC
        else:
            mMCOff = mMCOn = mMC
            
        ################ creat a model ##############################
        name="MILP2-"+mMCOff+mMCOn+soc+"-"+xType
        model = grb.Model(name=name)
        model.setParam('OutputFlag', option.grb_para_OutputFlag)
        model.setParam('TimeLimit', option.grb_para_timelimit)
        # model.setParam('FeasibilityTol', 1e-06)

        ################ define variables ###########################
        model = define_varaiables(data, option, model, xType, xBoth=0 )
        
        ################ add constraints ############################
        # probability hyperplane
        model = add_constraints(data, option, model, "prob_hyperplane", PI_ineq=(0,0))
        # after CC transformation
        model.addConstrs((model._y_off_y[j] <= model._y_off_0 for j in data.J), name="bound_off")
        model.addConstrs((model._y_off_y[j] <= model._x_off[j]*model._y_off_0_u for i in data.I for j in data.J), name="capability_off")
        
        model.addConstrs((model._y_on_y[i,j] <= model._y_on_0[i] for i in data.I for j in data.J), name="bound")
        model.addConstrs((model._y_on_y[i,j] <= model._x_off[j] for i in data.I for j in data.J), name="capability")
        
        # Extend Constraints 
        if (data.luce ==  1) & ('Luce' in data.ExtraConstrList):
            # model = add_extra_constraints(data, option, model, extra_cstrName="Luce_onF")
            model = add_extra_constraints(data, option, model, extra_cstrName="Luce_onX")
        if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="CardiOff")
        if (data.kappaOn < 1) & ("CardiOn" in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="CardiOn_onX")
        if (data.knapsackOff > 0) & ('KnapsackOff' in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="KnapsackOff")

        ################ set objective function  #############
        revenue_off, revenue_on, revenue_off_conic, revenue_on_conic = get_obj_express(data, option, model)
        obj_express = revenue_off + revenue_on
        
        model.setObjective(obj_express, sense=grb.GRB.MAXIMIZE)
        
        # model.setParam("BarQCPConvTol", 1e-4)
        
        
        model.update()
        self.model = model
        self.modelName = name
        
        
    def SO_RO_off(self):
        data = self.data
        option = self.option
        
            
        ################ creat a model ##############################
        name="SO-RO_off"
        # model = grb.Model(name=name)
        # model.setParam('OutputFlag', option.grb_para_OutputFlag)
        # model.setParam('TimeLimit', option.grb_para_timelimit)
        self.modelName = name
        
        ################ define variables ###########################
        # decompress data
        value_off_0 = data.value_off_0
        value_off_v = data.value_off_v
        value_on_0 = data.value_on_0
        value_on_v = data.value_on_v
        r_off = data.r_off[:,0]
        r_on = data.r_on
        I = data.I
        J = data.J
        prod_cust = data.prod_cust
        numProd = data.numProd
        numCust = data.numCust
        
        
        def obtain_revenue_mnl(v0,v,r,S):
            numProd = len(v)
            p = np.zeros(numProd)
            p[S] = v[S] / (v0 + sum(v[S]))
            obj = sum(r[S]*p[S])
            return obj
        
        x_off = np.zeros(numProd)
        obj_off = []
        r_sort_ind = np.argsort(-r_off)
        for k in range(numProd):
            S = r_sort_ind[range(k+1)]
            obj = obtain_revenue_mnl(value_off_0, value_off_v, r_off, S) 
            if k > 0 and (obj_off[-1] > obj):
                break
            S_old = S.copy()        
            obj_off.append(obj)
        S_max_off = S_old
        obj_max_off = obj_off[-1]
        x_off[S_max_off] = 1
        
        x_on = np.zeros((numProd, numCust))
        S_max_on = []
        obj_max_on = []
        for j in J:
            obj_on_j = []
            r_sort_ind = np.argsort(-r_on[:,j])
            for k in range(numProd):
                S = np.intersect1d(r_sort_ind[range(k+1)], S_max_off)
                obj = obtain_revenue_mnl(value_on_0[j], value_on_v[:,j], r_on[:,j], S) 
                if k > 0 and (obj_on_j[-1] > obj):
                    break
                S_old = S.copy()        
                obj_on_j.append(obj)
            S_max_on.append(S_old)
            obj_max_on.append(obj_on_j[-1])
            x_on[S_max_on[j],j] = 1

        arriveRatio_off = data.arriveRatio[0]/ (data.arriveRatio[0] + data.arriveRatio[1])
        arriveRatio_on  = data.arriveRatio[1]/ (data.arriveRatio[0] + data.arriveRatio[1])
        arriveRatio_on  = np.repeat(arriveRatio_on, data.numCust )/data.numCust  
        
        revenue_off = arriveRatio_off * obj_max_off
        revenue_on = sum(arriveRatio_on * obj_max_on)
        revenue_total = revenue_off + revenue_on
        
        x_off_pd = pd.Series(x_off, index=['x_off[{}]'.format(i) for i in I])
        x_on_pd = pd.Series(x_on.reshape((numProd*numCust,)), index=['x_on[{},{}]'.format(i, j) for i in I for j in J])
        sol = pd.Series(pd.concat([x_off_pd, x_on_pd]), name=name)
        sol.loc['obj'] = revenue_total
        self.Sols = pd.concat([self.Sols, sol], axis=1)
        
        return S_max_off, S_max_on, revenue_off, revenue_on, x_off, x_on
        
    def SO_enumerate_off(self):
        data = self.data
        option = self.option
        
            
        ################ creat a model ##############################
        name="SO-enumerate_off"
        # model = grb.Model(name=name)
        # model.setParam('OutputFlag', option.grb_para_OutputFlag)
        # model.setParam('TimeLimit', option.grb_para_timelimit)
        self.modelName = name
        
        ################ define variables ###########################
        # decompress data
        value_off_0 = data.value_off_0
        value_off_v = data.value_off_v
        value_on_0 = data.value_on_0
        value_on_v = data.value_on_v
        r_off = data.r_off[:,0]
        r_on = data.r_on
        I = data.I
        J = data.J
        prod_cust = data.prod_cust
        numProd = data.numProd
        numCust = data.numCust
        
        
        def obtain_revenue_mnl(v0,v,r,S):
            numProd = len(v)
            p = np.zeros(numProd)
            p[S] = v[S] / (v0 + sum(v[S]))
            obj = float(sum(r[S]*p[S]) )
            return obj
        
        def revenue_by_order_given_assortment_off(S_off):
            S_on = []
            obj_on = []
            for j in J:
                obj_on_j = []
                r_sort_ind = np.argsort(-r_on[:,j])
                for k in range(numProd):
                    S = np.intersect1d(r_sort_ind[range(k+1)], S_off)
                    obj = obtain_revenue_mnl(value_on_0[j], value_on_v[:,j], r_on[:,j], S) 
                    if k > 0 and (obj_on_j[-1] > obj):
                        break
                    S_old = S.copy()        
                    obj_on_j.append(obj)
                    if len(S) >= len(S_off):
                        break
                S_on.append(S_old)
                obj_on.append(obj_on_j[-1])
            return S_on, obj_on

        def obtain_revenue_luce(v0, v, r, S, j):
            row_ind = data.Ex_Cstr_Dict['Luce'].loc[:, ('on{}'.format(j), 'row')].dropna().astype('int')
            col_ind = data.Ex_Cstr_Dict['Luce'].loc[:, ('on{}'.format(j), 'col')].dropna().astype('int')
            adj_matrix = np.zeros((self.numProd, self.numProd), dtype='int')
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
        def revenue_by_order_given_assortment_off_with_luce(S_off):
            S_on = []
            obj_on = []
            for j in J:
                obj_on_j = []
                S_on_j = []
                r_sort_ind = np.argsort(-r_on[:, j])
                for k in range(numProd):
                    S = np.intersect1d(r_sort_ind[range(k+1)], S_off)
                    obj, _S, dominated = obtain_revenue_luce(value_on_0[j], value_on_v[:, j], r_on[:, j], S, j)
                    # obj = obtain_revenue_mnl(value_on_0[j], value_on_v[:,j], r_on[:,j], S)
                    # if k > 0 and (obj_on_j[-1] > obj):
                    #     break
                    # if k > 0 and obj_on_j[-1] > obj:
                    #     print(f"obj is decreasing j {j}, k {k}, old obj {round(obj_on_j[-1],3)}, new obj {round(obj,3)} \n", [round(float(_obj), 3) for _obj in obj_on_j])
                    S_on_j.append(S.copy())
                    obj_on_j.append(obj)
                    if len(S) >= len(S_off):
                        break

                max_loc = np.argmax(obj_on_j)
                S_on.append(S_on_j[max_loc])
                obj_on.append(obj_on_j[max_loc])
            return S_on, obj_on


        def get_cardinality(data):
            if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
                koff = data.Ex_Cstr_Dict['CardiOff'].iloc[:, 0].values[0]
            else:
                koff = data.numProd
            if (data.kappaOn < 1) & ("CardiOn" in data.ExtraConstrList):
                kon = data.Ex_Cstr_Dict['CardiOn'].iloc[:, 0].values
            else:
                kon = np.repeat(numProd, numCust)
            kon = np.array([min(int(koff), k) for k in kon])
            return koff, kon


        def solve_offline_with_cardinality():
            ################ creat a model ##############################
            model = grb.Model(name=name)
            model.setParam('OutputFlag', option.grb_para_OutputFlag)
            model.setParam('TimeLimit', option.grb_para_timelimit)
            # model.setParam('FeasibilityTol', 1e-06)

            ################ define variables ###########################
            y_off_0_l = 1 / (value_off_0 + sum(value_off_v))
            y_off_0_u = 1 / (value_off_0)
            x_off = model.addVars(I, lb=0, ub=1, vtype='B', name='x_off')
            y_off_0 = model.addVar(lb=y_off_0_l, ub=y_off_0_u, name='y_off_0')
            y_off_y = model.addVars(I, lb=0, ub=1, name='y_off_y')

            koff, kon = get_cardinality(data)
            model.addConstr(y_off_0 * value_off_0 + sum(y_off_y[i] * value_off_v[i] for i in I) == 1, name="hyperplane")
            model.addConstr(grb.quicksum(x_off) <= koff, name="cardinality")
            model.addConstrs((y_off_y[i] <= y_off_0 for i in I), name="bound_off")
            model.addConstrs((y_off_y[i] <= x_off[i] * y_off_0_u for i in data.I),
                             name="capability_off")

            obj_express = grb.quicksum(y_off_y[i] * value_off_v[i] * r_off[i] for i in I)
            model.setObjective(obj_express, sense=grb.GRB.MAXIMIZE)

            model.optimize()

            obj_off = model.ObjVal
            sol_x_off = [x_off[i].X for i in data.I]
            S_off = [i for i in data.I if x_off[i].X >0.95]

            return obj_off, S_off



        arriveRatio_off = data.arriveRatio[0]/ (data.arriveRatio[0] + data.arriveRatio[1])
        arriveRatio_on  = data.arriveRatio[1]/ (data.arriveRatio[0] + data.arriveRatio[1])
        arriveRatio_on  = np.repeat(arriveRatio_on, data.numCust )/data.numCust

        revenue_off_list = []
        revenue_on_list = []
        S_off_list = []
        S_on_list = []

        if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
            obj_off, S_off = solve_offline_with_cardinality()
            S_on, obj_on = revenue_by_order_given_assortment_off(S_off)
            revenue_off = arriveRatio_off * obj_off
            revenue_on = sum(arriveRatio_on * obj_on)
            revenue_total =  revenue_off + revenue_on

            S_max_off = copy.copy(S_off)
            S_max_on = copy.copy(S_on)
        else:
            r_sort_ind = np.argsort(-r_off)
            for k in range(numProd):
                S_off = r_sort_ind[range(k+1)]
                obj_off = obtain_revenue_mnl(value_off_0, value_off_v, r_off, S_off)
                S_on, obj_on = revenue_by_order_given_assortment_off(S_off)
                print(f"\nenumerate RO-off: k: {k}, obj: {round(sum(obj_on), 4)}\n", [round(float(_obj), 3) for _obj in obj_on])

                revenue_off = arriveRatio_off * obj_off
                revenue_on = sum(arriveRatio_on * obj_on)

                revenue_off_list.append(revenue_off)
                revenue_on_list.append(revenue_on)
                S_off_list.append(S_off)
                S_on_list.append(S_on)

            revenue_total_list = np.array(revenue_off_list) + np.array(revenue_on_list)
            max_loc = np.argmax(revenue_total_list)

            revenue_total = revenue_total_list[max_loc]
            revenue_off = revenue_off_list[max_loc]
            revenue_on = revenue_on_list[max_loc]

            S_max_off = copy.copy(S_off_list[max_loc])
            S_max_on = copy.copy(S_on_list[max_loc])

        obj_off = obtain_revenue_mnl(value_off_0, value_off_v, r_off, S_max_off)
        if data.luce == 1:
            # S_on, obj_on = revenue_by_order_given_assortment_off_with_luce(S_max_off)
            obj_on = obtain_revenue_by_applying_luce_to_assortment_on(S_max_on)
        else:
            S_on, obj_on = revenue_by_order_given_assortment_off(S_max_off)
        revenue_off = arriveRatio_off * obj_off
        revenue_on = sum(arriveRatio_on * obj_on)
        revenue_total = revenue_off + revenue_on

        x_off = np.zeros(numProd)
        x_off[S_max_off] = 1
        x_on = np.zeros((numProd, numCust))
        for j in J:
            x_on[S_max_on[j],j] = 1

        x_off_pd = pd.Series(x_off, index=['x_off[{}]'.format(i) for i in I])
        x_on_pd = pd.Series(x_on.reshape((numProd*numCust,)), index=['x_on[{},{}]'.format(i, j) for i in I for j in J])
        sol = pd.Series(pd.concat([x_off_pd, x_on_pd]), name=name)
        sol.loc['obj'] = revenue_total
        self.Sols = pd.concat([self.Sols, sol], axis=1)

        
        return S_max_off, S_max_on, revenue_off, revenue_on, x_off, x_on, revenue_off_list, revenue_on_list
    
    

    def SO_enumerate_off_enumerate_on(self):
        data = self.data
        option = self.option

        ################ creat a model ##############################
        name = "SO-enumerate_off_enumerate_on"
        # model = grb.Model(name=name)
        # model.setParam('OutputFlag', option.grb_para_OutputFlag)
        # model.setParam('TimeLimit', option.grb_para_timelimit)
        self.modelName = name

        ################ define variables ###########################
        # decompress data
        value_off_0 = data.value_off_0
        value_off_v = data.value_off_v
        value_on_0 = data.value_on_0
        value_on_v = data.value_on_v
        r_off = data.r_off[:, 0]
        r_on = data.r_on
        I = data.I
        J = data.J
        prod_cust = data.prod_cust
        numProd = data.numProd
        numCust = data.numCust

        if data.luce == 0:
            S_max_off = []
            S_max_on = [[] for j in data.J]
            x_off = np.zeros(numProd)
            x_on = np.zeros((numProd, numCust))
            revenue_off = 0
            revenue_on = 0
            revenue_off_list = []
            revenue_on_list = []
            return S_max_off, S_max_on, revenue_off, revenue_on, x_off, x_on, revenue_off_list, revenue_on_list

        def obtain_revenue_mnl(v0, v, r, S):
            numProd = len(v)
            p = np.zeros(numProd)
            p[S] = v[S] / (v0 + sum(v[S]))
            obj = sum(r[S] * p[S])
            return obj

        def obtain_revenue_luce(v0, v, r, S, j):
            row_ind = data.Ex_Cstr_Dict['Luce'].loc[:, ('on{}'.format(j), 'row')].dropna().astype('int')
            col_ind = data.Ex_Cstr_Dict['Luce'].loc[:, ('on{}'.format(j), 'col')].dropna().astype('int')
            adj_matrix = np.zeros((self.numProd, self.numProd), dtype='int')
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
            S = np.setdiff1d(S, list(dominated))

            obj = obtain_revenue_mnl(v0, v, r, S)
            return obj
        def revenue_by_order_given_assortment_off_with_luce(S_off):
            S_on = []
            obj_on = []
            for j in J:
                obj_on_j = []
                S_on_j = []
                r_sort_ind = np.argsort(-r_on[:, j])
                for k in range(numProd):
                    S = np.intersect1d(r_sort_ind[range(k+1)], S_off)
                    obj = obtain_revenue_luce(value_on_0[j], value_on_v[:, j], r_on[:, j], S, j)
                    # obj = obtain_revenue_mnl(value_on_0[j], value_on_v[:,j], r_on[:,j], S)
                    # if k > 0 and (obj_on_j[-1] > obj):
                    #     break
                    # if k > 0 and obj_on_j[-1] > obj:
                    #     print(f"obj is decreasing j {j}, k {k}, old obj {round(obj_on_j[-1],3)}, new obj {round(obj,3)} \n", [round(float(_obj), 3) for _obj in obj_on_j])
                    S_on_j.append(S.copy())
                    obj_on_j.append(obj)
                    if len(S) >= len(S_off):
                        break

                max_loc = np.argmax(obj_on_j)
                S_on.append(S_on_j[max_loc])
                obj_on.append(obj_on_j[max_loc])
            return S_on, obj_on

        def get_cardinality(data):
            if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
                koff = data.Ex_Cstr_Dict['CardiOff'].iloc[:, 0].values[0]
            else:
                koff = data.numProd
            if (data.kappaOn < 1) & ("CardiOn" in data.ExtraConstrList):
                kon = data.Ex_Cstr_Dict['CardiOn'].iloc[:, 0].values
            else:
                kon = np.repeat(numProd, numCust)
            kon = np.array([min(int(koff), k) for k in kon])
            return koff, kon

        def solve_offline_with_cardinality():
            ################ creat a model ##############################
            model = grb.Model(name=name)
            model.setParam('OutputFlag', option.grb_para_OutputFlag)
            model.setParam('TimeLimit', option.grb_para_timelimit)
            # model.setParam('FeasibilityTol', 1e-06)

            ################ define variables ###########################
            y_off_0_l = 1 / (value_off_0 + sum(value_off_v))
            y_off_0_u = 1 / (value_off_0)
            x_off = model.addVars(I, lb=0, ub=1, vtype='B', name='x_off')
            y_off_0 = model.addVar(lb=y_off_0_l, ub=y_off_0_u, name='y_off_0')
            y_off_y = model.addVars(I, lb=0, ub=1, name='y_off_y')

            koff, kon = get_cardinality(data)
            model.addConstr(y_off_0 * value_off_0 + sum(y_off_y[i] * value_off_v[i] for i in I) == 1, name="hyperplane")
            model.addConstr(grb.quicksum(x_off) <= koff, name="cardinality")
            model.addConstrs((y_off_y[i] <= y_off_0 for i in I), name="bound_off")
            model.addConstrs((y_off_y[i] <= x_off[i] * y_off_0_u for i in data.I),
                             name="capability_off")

            obj_express = grb.quicksum(y_off_y[i] * value_off_v[i] * r_off[i] for i in I)
            model.setObjective(obj_express, sense=grb.GRB.MAXIMIZE)

            model.optimize()

            obj_off = model.ObjVal
            sol_x_off = [x_off[i].X for i in data.I]
            S_off = [i for i in data.I if x_off[i].X > 0.95]
            return obj_off, S_off

        arriveRatio_off = data.arriveRatio[0] / (data.arriveRatio[0] + data.arriveRatio[1])
        arriveRatio_on = data.arriveRatio[1] / (data.arriveRatio[0] + data.arriveRatio[1])
        arriveRatio_on = np.repeat(arriveRatio_on, data.numCust) / data.numCust

        revenue_off_list = []
        revenue_on_list = []
        S_off_list = []
        S_on_list = []

        if (data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList):
            obj_off, S_off = solve_offline_with_cardinality()
            S_on, obj_on = revenue_by_order_given_assortment_off_with_luce(S_off)
            revenue_off = arriveRatio_off * obj_off
            revenue_on = sum(arriveRatio_on * obj_on)
            revenue_total =  revenue_off + revenue_on

            S_max_off = copy.copy(S_off)
            S_max_on = copy.copy(S_on)
        else:
            r_sort_ind = np.argsort(-r_off)
            for k in range(numProd):
                koff, kon = get_cardinality(data)
                if k >= koff: break
                S_off = r_sort_ind[range(k+1)]
                obj_off = obtain_revenue_mnl(value_off_0, value_off_v, r_off, S_off)
                S_on, obj_on = revenue_by_order_given_assortment_off_with_luce(S_off)
                print(f"\nenumerate RO-off: k: {k}, obj: {round(sum(obj_on), 4)}\n", [round(float(_obj),3) for _obj in obj_on])

                revenue_off = arriveRatio_off * obj_off
                revenue_on = sum(arriveRatio_on * obj_on)

                revenue_off_list.append(revenue_off)
                revenue_on_list.append(revenue_on)
                S_off_list.append(S_off)
                S_on_list.append(S_on)

            revenue_total_list = np.array(revenue_off_list) + np.array(revenue_on_list)
            max_loc = np.argmax(revenue_total_list)

            revenue_total = revenue_total_list[max_loc]
            revenue_off = revenue_off_list[max_loc]
            revenue_on = revenue_on_list[max_loc]

            S_max_off = copy.copy(S_off_list[max_loc])
            S_max_on = copy.copy(S_on_list[max_loc])

        obj_off = obtain_revenue_mnl(value_off_0, value_off_v, r_off, S_max_off)
        S_on, obj_on = revenue_by_order_given_assortment_off_with_luce(S_max_off)
        revenue_off = arriveRatio_off * obj_off
        revenue_on = sum(arriveRatio_on * obj_on)
        revenue_total = revenue_off + revenue_on

        x_off = np.zeros(numProd)
        x_off[S_max_off] = 1
        x_on = np.zeros((numProd, numCust))
        for j in J:
            x_on[S_max_on[j], j] = 1

        x_off_pd = pd.Series(x_off, index=['x_off[{}]'.format(i) for i in I])
        x_on_pd = pd.Series(x_on.reshape((numProd * numCust,)),
                            index=['x_on[{},{}]'.format(i, j) for i in I for j in J])
        sol = pd.Series(pd.concat([x_off_pd, x_on_pd]), name=name)
        sol.loc['obj'] = revenue_total
        self.Sols = pd.concat([self.Sols, sol], axis=1)



        return S_max_off, S_max_on, revenue_off, revenue_on, x_off, x_on, revenue_off_list, revenue_on_list




    def FPTAS(self, sigma=1e-1):
        data = self.data
        option = self.option
        
            
        ################ creat a model ##############################
        name="FPTAS"
        model = grb.Model(name=name)
        model.setParam('OutputFlag', option.grb_para_OutputFlag)
        model.setParam('TimeLimit', option.grb_para_timelimit)
        self.modelName = name
        
        ################ define variables ###########################
        # decompress data
        value_off_0 = data.value_off_0
        value_off_v = data.value_off_v
        value_on_0 = data.value_on_0
        value_on_v = data.value_on_v
        r_off = data.r_off[:,0]
        r_on = data.r_on
        I = data.I
        J = data.J
        prod_cust = data.prod_cust
        numProd = data.numProd
        numCust = data.numCust
        K = numProd
        
        
        r_min = min(np.min(r_off), np.min(r_on))
        r_max = max(np.max(r_off), np.max(r_on))
        value_min = min(np.min(value_off_v), np.min(value_on_v[np.where(value_on_v>0)]))
        B_min = r_min * value_min / (1+value_min)
        B_max = r_max
        
        k_min = int(np.floor(np.log(B_min)/np.log(1+sigma)))
        k_max = int(np.ceil(np.log(B_max)/np.log(1+sigma)))
        grid_lattice = (1+sigma)**np.arange(k_min, k_max+1)
        L = len(grid_lattice)
        
        x_off = model.addVars(I, vtype='B', name='x_off')
        lattice_ind_off = range(L)
        z_off = model.addVars(range(L),vtype='B', name='z_off')
        
        # x_on = model.addVars(prod_cust, vtype='B', name='x_on')
        lattice_ind_on = grb.tuplelist((itertools.product(range(L), J)))
        z_on = model.addVars(lattice_ind_on, vtype='B', name='z_on')
        
        model._x_off = x_off
        
        
        ################ add constraints ############################
        distjunct_off = model.addConstrs((sum(value_off_v[i] * (r_off[i] - grid_lattice[l]) * x_off[i] for i in I if (r_off[i] - grid_lattice[l]) >0 ) 
                                          >= grid_lattice[l] * z_off[l] 
                                      for l in lattice_ind_off),
                             name='distjunct_off')
        distjunct_on = model.addConstrs((sum(value_on_v[i,j] * (r_on[i,j] - grid_lattice[l]) * x_off[i] for i in I if (r_on[i,j] - grid_lattice[l])>0) 
                                      >= grid_lattice[l] * z_on[l,j] 
                                      for l in lattice_ind_off for j in J),
                                     name='distjunct_on')
        # model.addConstr(x_off.sum() <= K)
        model.addConstr(z_off.sum() == 1)
        model.addConstrs(z_on.sum('*', j) == 1 for j in J)
        model.update()
        
        
        # Extra Constraints 
        if ((data.kappaOff < 1) & ("CardiOff" in data.ExtraConstrList)) or ((data.kappaOn < 1) & ('CardiOn' in data.ExtraConstrList)) :
            model = add_extra_constraints(data, option, model, extra_cstrName="CardiOff")
        if (data.knapsackOff > 0) & ('KnapsackOff' in data.ExtraConstrList):
            model = add_extra_constraints(data, option, model, extra_cstrName="KnapsackOff")
            
        ################ set objective ###########################
        arriveRatio_off = data.arriveRatio[0]/ (data.arriveRatio[0] + data.arriveRatio[1])
        arriveRatio_on  = data.arriveRatio[1]/ (data.arriveRatio[0] + data.arriveRatio[1])
        arriveRatio_on  = np.repeat(arriveRatio_on, data.numCust )/data.numCust
        revenue_off = arriveRatio_off * sum(grid_lattice[l] * z_off[l] for l in lattice_ind_off)
        revenue_on = sum(arriveRatio_on[j] * sum(grid_lattice[l] * z_on[l,j] 
                                               for l in lattice_ind_off)
                                               for j in J)
        
        model._revenue_off = revenue_off
        model._revenue_on  = revenue_on
        obj_express = revenue_off + revenue_on
        model.setObjective(obj_express, sense=grb.GRB.MAXIMIZE)
        
        
        
        model.update()
        self.model = model
        self.modelName = name
        
        
        
    def modelOptimize(self, mycallbackFun=''):            
        self.gotResult = 0
        if self.option.para_logging == 1:
            self.model.Params.logFile = 'LogFile/' + self.data.probName + '_' + self.modelName + '.log'
        if self.option.para_write_lp== 1:
            self.writeModel(self.modelName, self.option.para_write_lp, 'lp')
        if callable(mycallbackFun):
            self.model.optimize(mycallbackFun)
        else:
            self.model.optimize()
        self.Model_history[self.modelName] = self.model.copy()

    def modelGetResult(self):
        # get the result
        self.gotResult = 1
        model = self.model
        I = self.I
        J = self.J
        numProd = self.numProd
        numCust = self.numCust
        # print('=============model.status:{}'.format(model.status))
        # if model.status == grb.GRB.status.OPTIMAL or model.status == grb.GRB.status.TIME_LIMIT:
        if model.status in [ grb.GRB.status.OPTIMAL, grb.GRB.status.TIME_LIMIT, grb.GRB.status.SUBOPTIMAL]:
            sol_x_off = [model.getVarByName('x_off[{}]'.format(i)).getAttr('x') for i in I]
            sol_y_off_0 = model.getVarByName('y_off_0').getAttr('x')
            sol_y_off_y = [model.getVarByName('y_off_y[{}]'.format(i)).getAttr('x') for i in I]
            sol_y_on_0 = [model.getVarByName('y_on_0[{}]'.format(j)).getAttr('x') for j in J]
            sol_y_on_y = np.zeros((numProd, numCust))
            for i in I:
                for j in J:
                    sol_y_on_y[i, j] = model.getVarByName('y_on_y[{},{}]'.format(i, j)).getAttr('x')

            obj_value = model.getObjective().getValue()
        else:
            print('\n=============model.status:{}===========\n'.format(model.status))

        self.s_x_off = np.array(sol_x_off).reshape(numProd, 1)
        self.s_y_off_0 = sol_y_off_0
        self.s_y_off_y = np.array(sol_y_off_y).reshape(numProd, 1)
        self.s_y_on_0 = np.array(sol_y_on_0)#.reshape(1, numCust)
        self.s_y_on_y = np.array(sol_y_on_y).reshape(numProd, numCust)
        self.obj_value = obj_value
               
    
    def writeModel(self, name, wirteLp=0, suffix='lp'):
        if wirteLp>0:
            # self.model.write("{}\{}.{}".format(self.option.lpFolder, name, suffix))
            self.model.write("{}/{}.{}".format(lpFolder, name, suffix))
            
    def get_sol_pd(self, model=''):
        modelName = self.modelName
        if any(model):
            pass
        else:
            model = self.model         
        
        if model.SolCount >= 1:
            var_values = model.getAttr('x')
            obj_value = model.getAttr('ObjVal')
            var_index = model.getAttr('VarName')
            var_values.insert(0, obj_value)
            var_index.insert(0, 'obj')
            sol = pd.Series(var_values, index=var_index, name=modelName)
            self.Sols = pd.concat([self.Sols, sol], axis=1)
        else:
            pass
        return sol

    def check_convexHull_new(self):
        if self.gotResult==0:
            self.modelGetResult()
        option = self.option
        separate_tol = self.data.separate_tol
        # check offline customer
        y0 = np.array(self.s_y_off_0)
        y = self.s_y_off_y.reshape(self.numProd)
        u0 = self.value_off_0
        u = self.value_off_v
        I = self.I
        Infeasi_flag_off = {}
        coeDict_off = {}
        rank = np.argsort(y)
        
        for i in I:
            if u[i] == 0:
                continue
            xi = self.s_x_off[i]
            infeasi_flag, [coe_xi, coe_y0, coe_y] = tf.separate(i, xi, y0, y, u0, u, separate_tol)
            if infeasi_flag > 0:
                Infeasi_flag_off[i] = infeasi_flag;
                coeDict_off[i] = [coe_xi, coe_y0, coe_y]
            # if option.para_print_checkProcess == 1:
            #     print("product {}, infeasible flag: {}".format(i, infeasi_flag))
            #     print("  coe_xi:{},\n coe_y0:{},\n coe_y:{}".format(coe_xi, coe_y0, coe_y))
            #     print("  left:{}\n".format(coe_xi * xi + coe_y0 * y0 + sum(coe_y[i] * y[i] for i in I)))
            
        Infeasi_flag_on = {}
        coeDict_on = {}
        for j in range(self.numCust):
            y0 = np.array(self.s_y_on_0[j])
            y = self.s_y_on_y[:,j]
            u0 = self.value_on_0[j]
            u = self.value_on_v[:,j]
            for i in I:
                if u[i] == 0:
                    continue
                xi = self.s_x_off[i]
                infeasi_flag, [coe_xi, coe_y0, coe_y] = tf.separate(i, xi, y0, y, u0, u, separate_tol)
                if infeasi_flag == 2:
                    Infeasi_flag_on[i,j] = infeasi_flag;
                    coeDict_on[i,j] = [coe_xi, coe_y0, coe_y]
                
        Infeasi_flag = [Infeasi_flag_off, Infeasi_flag_on]
        coeDict = [coeDict_off, coeDict_on]
        self.Infeasi_flag = Infeasi_flag
        self.coeDict = coeDict
        return Infeasi_flag, coeDict
    
    def check_convexHull(self):
        if self.gotResult==0:
            self.modelGetResult()
        option = self.option
        separate_tol = self.data.separate_tol
        # check offline customer
        y0 = np.array(self.s_y_off_0)
        y = self.s_y_off_y.reshape(self.numProd)
        u0 = self.value_off_0
        u = self.value_off_v
        I = self.I
        Infeasi_flag_off = {}
        coeDict_off = {}
        for i in I:
            if u[i] == 0:
                continue
            xi = self.s_x_off[i]
            infeasi_flag, [coe_xi, coe_y0, coe_y] = tf.separate(i, xi, y0, y, u0, u, separate_tol)
            if infeasi_flag > 0:
                Infeasi_flag_off[i] = infeasi_flag;
                coeDict_off[i] = [coe_xi, coe_y0, coe_y]
            # if option.para_print_checkProcess == 1:
            #     print("product {}, infeasible flag: {}".format(i, infeasi_flag))
            #     print("  coe_xi:{},\n coe_y0:{},\n coe_y:{}".format(coe_xi, coe_y0, coe_y))
            #     print("  left:{}\n".format(coe_xi * xi + coe_y0 * y0 + sum(coe_y[i] * y[i] for i in I)))
            
        Infeasi_flag_on = {}
        coeDict_on = {}
        for j in range(self.numCust):
            y0 = np.array(self.s_y_on_0[j])
            y = self.s_y_on_y[:,j]
            u0 = self.value_on_0[j]
            u = self.value_on_v[:,j]
            for i in I:
                if u[i] == 0:
                    continue
                xi = self.s_x_off[i]
                infeasi_flag, [coe_xi, coe_y0, coe_y] = tf.separate(i, xi, y0, y, u0, u, separate_tol)
                if infeasi_flag == 2:
                    Infeasi_flag_on[i,j] = infeasi_flag;
                    coeDict_on[i,j] = [coe_xi, coe_y0, coe_y]
                if option.MMNL == 1 and infeasi_flag == 1:
                    Infeasi_flag_on[i,j] = infeasi_flag;
                    coeDict_on[i,j] = [coe_xi, coe_y0, coe_y]
                
        Infeasi_flag = [Infeasi_flag_off, Infeasi_flag_on]
        coeDict = [coeDict_off, coeDict_on]
        self.Infeasi_flag = Infeasi_flag
        self.coeDict = coeDict
        return Infeasi_flag, coeDict

    def add_cut(self, index_set, coeDict, cut_round, cutType='cut_both'):
        """add a cuttingplan inequality constraint into the model"""
        # i = index_set[0]
        I = self.I
        J = self.J
        model = self.model
        [index_set_off, index_set_on] = index_set
        [coeDict_off, coeDict_on] = coeDict
        numCut_off = len(index_set_off)
        numCut_on  = [sum([1 for ind in index_set[1] if ind[1]==j]) for j in J]
        
        if cutType == 'cut_offline':
            print("\n************** ADDING {}, round {}***************\n".format(cutType, cut_round))
            print("*********add {} offline cuts ".format(numCut_off))
            # print(index_set_off)
            cuttingName_off = 'cutting_off_{}'.format(cut_round)
            cutPlane_off = model.addConstrs((coeDict_off[i][0] * model._x_off[i] + coeDict_off[i][1] * model._y_off_0
                                     + coeDict_off[i][2] @ model._y_off_y.select('*') >= 0 for i in index_set_off), name=cuttingName_off)
            model._cutPlane_off = cutPlane_off
            self.modelName = 'cut_off_rd{}'.format(cut_round)
            if '_cutPlane_on' in dir(model):
                model.remove(model._cutPlane_on)
            cutPlane_on_list = [constr for constr in model.getConstrs() if 'cutting _on' in constr.ConstrName]
            model.remove(cutPlane_on_list)
                
        if cutType == 'cut_online':
            print("\n************** ADDING {}, round{}***************\n".format(cutType, cut_round))
            print("*********add {} online cuts (total {}) ".format(numCut_on, sum(numCut_on)))
            # print(index_set_on)
            cuttingName_on = 'cutting_on_{}'.format(cut_round)
            cutPlane_on = model.addConstrs((coeDict_on[i_j][0] * model._x_off[i_j[0]] + coeDict_on[i_j][1] * model._y_on_0[i_j[1]]
                                    + coeDict_on[i_j][2] @ model._y_on_y.select('*',i_j[1]) >= 0 
                                    for i_j in index_set_on), name=cuttingName_on)
            model._cutPlane_on = cutPlane_on
            self.modelName = 'cut_on_rd{}'.format(cut_round)
            if '_cutPlane_off' in dir(model):
                model.remove(model._cutPlane_off)
            cutPlane_off_list = [constr for constr in model.getConstrs() if 'cutting _off' in constr.ConstrName]
            model.remove(cutPlane_off_list)
                
        if cutType == 'cut_both':
            print("\n************** ADDING {}, round{}***************\n".format(cutType, cut_round))
            print("*********add {} offline cuts ".format(numCut_off))
            # print(index_set_off)
            print("*********add {} online cuts (total {}) ".format(numCut_on, sum(numCut_on)))
            # print(index_set_on)
            cuttingName_bothoff = 'cutting_both_off_{}'.format(cut_round)
            cutPlane_bothoff = model.addConstrs((coeDict_off[i][0] * model._x_off[i] + coeDict_off[i][1] * model._y_off_0
                                     + coeDict_off[i][2] @ model._y_off_y.select('*') >= 0 for i in index_set_off), name=cuttingName_bothoff)
            cuttingName_bothon = 'cutting_both_on_{}'.format(cut_round)
            cutPlane_bothon = model.addConstrs((coeDict_on[i_j][0] * model._x_off[i_j[0]] + coeDict_on[i_j][1] * model._y_on_0[i_j[1]]
                                    + coeDict_on[i_j][2] @ model._y_on_y.select('*',i_j[1]) >= 0 
                                    for i_j in index_set_on), name=cuttingName_bothon)
            model._cutPlane_bothoff = cutPlane_bothoff
            model._cutPlane_bothon = cutPlane_bothon
            self.modelName = 'cut_both_rd{}'.format(cut_round)
            
            cutPlane_off_list = [constr for constr in model.getConstrs() if 'cutting _off' in constr.ConstrName]
            model.remove(cutPlane_off_list)
            cutPlane_on_list = [constr for constr in model.getConstrs() if 'cutting _on' in constr.ConstrName]
            model.remove(cutPlane_on_list)
            
        model.update()
        self.model = model
        self.numCut_off = numCut_off
        self.numCut_on = numCut_on

    def remove_cut(self):
        model = self.model
        cutting_constr_off = [constr for constr in model.getConstrs() if 'cutting_off' in constr.ConstrName]
        cutting_constr_on = [constr for constr in model.getConstrs() if 'cutting_on' in constr.ConstrName]
        cutting_constr_both = [constr for constr in model.getConstrs() if 'cutting' in constr.ConstrName]
        model.remove(cutting_constr_off)
        model.remove(cutting_constr_on)
        model.remove(cutting_constr_both)
        
        self.model = model
    

#%%      
if __name__ == '__main__':
    print("************************ TESTING ************************")
    para_randomData = 1
    para_relaxModel = 0
    option = Option(para_randomData, para_relaxModel)
    numProd, numCust = (10, 3)
    data = Data(option, (numProd, numCust))
    m = Instance(data, option)
    m.buildeExactModel(data)
    m.modelOptimize()
    m.print_result()
    sol_ex = m.get_sol_pd()
    m.writeModel("model_exact")

    m.relax_x('C')
    m.modelOptimize()
    m.print_result()
    sol_r_off = m.get_sol_pd()
    m.writeModel("model_r_off")

    m.relax_McCormick()
    m.modelOptimize()
    m.print_result()
    sol_r_MC = m.get_sol_pd()
    m.writeModel("model_r_MC")
    
    option.para_print_checkProcess = 1
    cut_round = 1
    sol_withCut = {}
    while cut_round <= 10:
        Infeasi_flag, coeDict = m.check_convexHull()
        if any(Infeasi_flag):
            print("\n************** ADDING CutingPlane {}***************\n".format(cut_round))
            index_set = np.where(Infeasi_flag)[0]
            m.cut_equal(index_set, coeDict, cut_round)
        else:
            break
        m.modelOptimize()
        m.print_result()
        m.writeModel("model_r_MC_cutcyc{}".format(cut_round))
        sol_withCut[cut_round] = m.get_sol_pd()
        cut_round += 1
    print("implemented {} cycle cuts".format(cut_round))
        
