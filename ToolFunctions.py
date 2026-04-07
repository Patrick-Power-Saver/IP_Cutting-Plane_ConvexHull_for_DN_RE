"""Separation algorithm:"""
"""__author__ = 'Yunlong Wang'"""

import random, itertools
import pandas as pd
import numpy as np
import networkx as nx
import matplotlib.pyplot as plt
import sys, os, time, pickle

#%% check folder
import os, sys
cpy  = os.path.abspath(__file__)
cwd = os.path.abspath(os.path.join(cpy, "../"))
folders_list = ["./DataSet", "./Output", "./Logfile", "./lpFolder"]
for f in folders_list:
    if not os.path.exists(f):
        os.mkdir(f)

#%%
class Alpha():
    """compute alpha value for any index set S, given attraction value u0 and u"""
    def __init__(self, value_off_0, value_off_v, value_on_0, value_on_v):
        self.value_off_0 = value_off_0
        self.value_off_v = value_off_v
        self.value_on_0 = value_on_0
        self.value_on_v = value_on_v
    def compute(self, prod_set_index, cust_index=-1): 
        """compute the alpha value on each customer segement.
            prod_set_index: production index set, in N
            cust_index:
                        -1: compute the alpha value for the offline customer
                        0+: compute the alpha value for each online customer segment"""
        if cust_index >= 0:
            return 1 / (self.value_on_0[cust_index] + sum(self.value_on_v[prod_set_index, cust_index]))
        else:
            return 1 / (self.value_off_0 + sum(self.value_off_v[prod_set_index]))
        
    def cardi_x0(self, k, I, prod_index, cust_index=-1):
        """compute the alpha value on each customer segement, considering cardinality constraints and x_i=0.
            k: cardianlity number
            I: total considered products set
            prod_set_index: production index set, in N
            cust_index:
                        -1: compute the alpha value for the offline customer
                        0+: compute the alpha value for each online customer segment"""
        
        I_i = np.setdiff1d(I,prod_index)
        if cust_index >= 0:
            return  1/(self.value_on_0[cust_index]+ sum(np.sort(self.value_on_v[I_i, cust_index])[-k:]))
        else:
            return 1/(self.value_off_0 + sum(np.sort(self.value_off_v[I_i])[-k:]))
            
    def cardi_x1(self, k, I, prod_index, cust_index=-1):
        """compute the alpha value on each customer segement, considering cardinality constraints and x_i=1.
            k: cardianlity number
            I: total considered products set
            prod_set_index: production index set, in N
            cust_index:
                        -1: compute the alpha value for the offline customer
                        0+: compute the alpha value for each online customer segment"""
        I_i = np.setdiff1d(I,prod_index)
        if cust_index >= 0:
            return  1/(self.value_on_0[cust_index]
                       + sum(np.sort(self.value_on_v[I_i, cust_index])[-k+1:]) 
                       + self.value_on_v[prod_index, cust_index])
        else:
            return 1/(self.value_off_0 + sum(np.sort(self.value_off_v[I_i])[-k+1:]) + self.value_off_v[prod_index])          
    
def separate(i, xi, y0, y, u0, u, feasi_tol = 1e-12):
    """
    ``seperate(i,xi,y0,y, u0,u)``

    Separation algorithm:
    return if a point (a,y0,y) satisfies one of the two kinfs or valid inequalities of the voncex hull or is in it.

    # Input:
           i:  i=1,2,...n, indictes ith element of Product Set Index I
           xi:  in [0,1], corresponding to  the x_i
           y0: dim 1, positive number
           y:  dim n, positive number
           u0: dim 1, attracting value of no purchase
           u:  dim n, attracting value of products, characterizing the hyperplane Y

    # Output:
           infeasible_flag: indicting the feasibility of input point (xi, y0, y)
                          0, feasible for both,
                          1, infeasible due to B_less,
                          2, infeasible due to B_greater.
           coe = [ineq_coe_xi, ineq_coe_y0, ineq_coe_y], corresponding coefficients.
    # attention : the sense of separation inequality is ``>=``, i.e., ``coe'*[xi; y0; y] >= 0``
    """

    # get basic info
    # feasi_tol = 1e-12
    numProd = len(y)
    I = np.arange(numProd)

    # get the optimal sets to construct valid inequalities
    S_star = np.setdiff1d(I[y >= y[i]], i)
    T_star = np.setdiff1d(I[y >= y0 - y[i]], i)

    # construct the valid inequalities
    S_temp = np.append(S_star, i)
    T_temp = np.append(T_star, i)
    alpha = lambda set_index: 1 / (u0 + sum(u[set_index]))

    ineq_coe1_xi = -alpha(S_temp)
    ineq_coe1_y0 = 0
    ineq_coe1_y = np.zeros(numProd)
    ineq_coe1_y[i] = 1
    ineq_coe1_y[np.setdiff1d(I, S_temp)] = alpha(S_temp) * u[np.setdiff1d(I, S_temp)]
    ineq_B1 = (ineq_coe1_y0 * y0 + ineq_coe1_y @ y + ineq_coe1_xi * xi >= -feasi_tol)

    if ineq_B1:
        ineq_coe2_xi = alpha(T_temp)
        ineq_coe2_y0 = (1 - (u0 + u[i]) * alpha(T_temp))
        ineq_coe2_y = np.zeros(numProd)
        ineq_coe2_y[i] = -1
        ineq_coe2_y[T_star] = -alpha(T_temp) * u[T_star]
        ineq_B2 = (ineq_coe2_y0 * y0 + ineq_coe2_y @ y + ineq_coe2_xi * xi >= -feasi_tol)
        if ineq_B2:
            return 0, [0, 0, np.zeros(numProd)]
        else:
            return 2, [ineq_coe2_xi, ineq_coe2_y0, ineq_coe2_y]
    else:
        return 1, [ineq_coe1_xi, ineq_coe1_y0, ineq_coe1_y]


# def revenue_mnl(v0,v,r,S):
#     numProd = len(v)
#     p = np.zeros(numProd)
#     p[S] = v[S] / (v0 + sum(v[S]))
#     obj = sum(r[S]*p[S])
#     return obj

# def get_revenue(data, Solution):
#     # decompress data
#     value_off_0 = data.value_off_0
#     value_off_v = data.value_off_v
#     value_on_0 = data.value_on_0
#     value_on_v = data.value_on_v
#     r_off = data.r_off[:,0]
#     r_on = data.r_on
#     I = data.I
#     J = data.J
#     prod_cust = data.prod_cust
#     numProd = data.numProd
#     numCust = data.numCust
#     arrivRatio_off = data.arrivRatio[0]/ (data.arrivRatio[0] + data.arrivRatio[1])
#     arrivRatio_on  = data.arrivRatio[1]/ (data.arrivRatio[0] + data.arrivRatio[1])
#     arrivRatio_on  = np.repeat(arrivRatio_on, data.numCust )/data.numCust  
    
#     S_off = np.array([i for i in data.I if 'x_off' in Solution.index[i]] )
#     obj_opt_off = revenue_mnl(value_off_0, value_off_v, r_off, S_off) 
#     for j in data.J
#     obj_opt_on  = [revenue_mnl(value_on_0[j], value_on_v[:,j], r_on[:,j], S_off) ]
#     revenue_total = arrivRatio_off * obj_opt_off + sum(arrivRatio_on * obj_opt_on)
    
#%% bathCase_gapAnalysis
def bathCase_gapAnalysis(OBJ_df):
    OBJ_df['gap_MC'] = OBJ_df['model_rl_MC']- OBJ_df['model_exact']
    OBJ_df['gap_offline'] = OBJ_df['cut_offline']- OBJ_df['model_exact']
    OBJ_df['gap_online'] = OBJ_df['cut_online']- OBJ_df['model_exact']
    OBJ_df['gap_both'] = OBJ_df['cut_both']- OBJ_df['model_exact']
    return OBJ_df


#%% write execel
def writeExcel(folder, dataframeDict):
    """write the dataframe in dataframeDict into one excel having several sheets"""
    if not isinstance(dataframeDict, dict):
        print("please give dataframeDict with type 'dict'")
        pass
    else:
        writer = pd.ExcelWriter(folder)
        for key,df in dataframeDict.items():
            if len(df) > 0:
                df.to_excel(excel_writer=writer, sheet_name='{}'.format(key), index=True)
        # writer.save()
        writer.close()
        
#% save data
def save(filename, *args):
    if '.pkl' not in filename:
        filename = filename + '.pkl'
    with open(filename, 'wb') as f:
        pickle.dump(args, f)
        
#% load data
def load(filename):
    if '.pkl' not in filename:
        filename = filename + '.pkl'
    with open(filename, 'rb') as f:
        args = pickle.load(f)
    return args

def extract_report(option, modelReport, probSettingSet, InfoDict, FileName="", savereporttable=0):
    """
    extract an table (CompleteTable of type DataFrame) from the results (InfoDict)
    if savereporttable = 1 and FileName is given, CompleteTable will be save to FileName.csv
    """

    variableNeed, variableReport = option.variableNeed,  option.variableReport
    variableNeed_dict = {}      
    for variable in variableNeed:
         temp_able = pd.concat((InfoDict[probSetting_info][1][variable]
                                       for probSetting_info in probSettingSet   
                                       ),
                               axis=1,
                               keys = probSettingSet,
                               names=['size', 'alpha', 'v0', 'luce', 'kappa', 'knapsack'])
         variableNeed_dict[variable] = temp_able
    # FileName = './Output/Tables_ReportTable1_'+option.probType+ time_stamp_str +'_raw.xlsx'
    # writeExcel(FileName, variableNeed_dict)

    index = pd.MultiIndex.from_product([modelReport, variableReport])
    AggTable = pd.DataFrame(index=index, columns=probSettingSet)
    AggTable.columns.names = ['size', 'alpha', 'v0', 'luce', 'kappa', 'knapsack']
    # AggTable = pd.DataFrame(index=index, columns=pd.MultiIndex.from_product([[*probSettingSet]]))
    
    for probSetting_info in probSettingSet:
        for variable in variableReport:
            for m in modelReport:
                if variable == 'NumSolved':
                    # AggTable.loc[(m, variable),(probSetting_info,)] = np.sum(variableNeed_dict['Status'][(probSetting_info,)]==2, axis=1).loc[m]
                    AggTable.loc[(m, variable),probSetting_info] = (variableNeed_dict['Status'][probSetting_info].loc[m] ==2) * 1
                else:
                    # AggTable.loc[(m, variable),(probSetting_info,)] = variableNeed_dict[variable][(probSetting_info,)].mean(axis=1, skipna=True).loc[m]
                    AggTable.loc[(m, variable),probSetting_info] = variableNeed_dict[variable][probSetting_info].loc[m]
        
        # recompute the run time of models with cuts
        allCarriedModels= [*variableNeed_dict['Runtime'][probSetting_info].index]
        runtime = variableNeed_dict['Runtime'][probSetting_info]
        separtime = variableNeed_dict['Separtime'][probSetting_info]
        
        for modelName in allCarriedModels:
            if 'aC' not in modelName:
                continue
            loc_aCModel = get_model_location(modelName, allCarriedModels)
            if loc_aCModel >= 0:
                modelType = modelName.split('-')[0]
                if 'mo' in modelName.split('-'):
                    modelType = modelType + '-mo'
                if 'soc' in modelName.split('-'):
                    modelType = modelType + '-soc'
                modelType_C = modelType + '-C'
                loc_CTNModel = get_model_location(modelType_C, allCarriedModels)
                index_set = range(loc_CTNModel, loc_aCModel+1)
                AggTable.loc[(modelName, 'Runtime_cut'), probSetting_info] = runtime.iloc[index_set[0:-1]].sum(axis=0)
                AggTable.loc[(modelName,'Runtime_sep'), probSetting_info] = separtime.sum(axis=0)
                AggTable.loc[(modelName, 'Runtime'), probSetting_info] = runtime.iloc[index_set].sum(axis=0) #- runtime.iloc[index_set[-1]]
    
    key_order = ['AggTable'] + [*variableNeed_dict.keys()]
    CompleteTable = {}
    CompleteTable.fromkeys(key_order)
    CompleteTable['AggTable']= AggTable.sort_index(level=1)
    CompleteTable.update(variableNeed_dict) 
    
    if savereporttable == 1:
        writeExcel(FileName, CompleteTable)
        print("="*50+"\n table save to "+FileName+"\n"+"="*50)
    
    return CompleteTable

def update_Folder(option_instance):
    folder = os.path.abspath(os.path.join(cwd, "lpFolder"))
    if not os.path.exists(folder):
        os.makedirs(folder)
    option_instance.lpFolder = folder
    return option_instance
    
#%% save input data to device
def saveData_toExcel(data):
    """ save the data to excel
    TODO: should be deprecated
    """
    FileName = 'DataSet/'+data.probName+'.xlsx'
    data.to_df()
    DATA_DICT = data.DATA_DICT.copy()
    if 'Luce' not in data.ExtraConstrList:
        DATA_DICT.pop('Luce', None)
    if 'CardiOff' not in data.ExtraConstrList:
        DATA_DICT.pop('CardiOff', None)
    if 'CardiOn' not in data.ExtraConstrList:
        DATA_DICT.pop('CardiOn', None)
    writeExcel(FileName, DATA_DICT)
    print('\n save input data to table {}'.format(FileName))
        
#%% extract data and option from S_I_DO_repeat
def extract_dataOption(r,probSetting_info,
                       SolutionDict_InfoDict_dataOptionDict_repeat_raw):
    """
    extract the corresponding data and option from SolutionDict_InfoDict_dataOptionDict_repeat_raw

    Parameters
    ----------
    r : the repeat round.
    probSetting_info: (numProd, numCust), arriveRation_off, (v0_off, v0_on), luce, (kappa_on, kappa_off), (knapsack_off, knapsack_on)
    SolutionDict_InfoDict_dataOptionDict_repeat_raw : Dict
        three parts: SolutionDict, InfoDict and dataOptionDict.

    Returns
    -------
    data : TYPE
        DESCRIPTION.
    option : TYPE
        DESCRIPTION.

    """
    dataOptionDict_raw = SolutionDict_InfoDict_dataOptionDict_repeat_raw[r][2]
    
    # get data and option
    data,option = dataOptionDict_raw[probSetting_info]
    
    # reset data
    data = data
    
    # reset option
    option.cut_round_limit = 2
    option.grb_para_timelimit = 3600
    
    option = update_Folder(option)
    
    probSetting_str = 'Sz{}_{}_v{}_{}_s{:.1f}_{:.1f}_c{:.1f}_{:.1f}'.format(data.numProd, data.numCust,
                                                        int(data.value_off_0), int(data.value_on_0[0]),
                                                        data.utilitySparsity_off, data.utilitySparsity_on,
                                                        data.kappaOff, data.kappaOn)
    data.probName = data.probType+ '_r%d_'%(r) + probSetting_str
    
    # if option.save_data == 1 :
    #     tf.saveData_toExcel(data)
    return data, option


#%% generate the adjacent matrix that reflects the dominance relationship of products.
def generate_random_trees(n):
    """
    generate the adjacent matrix indicating the dominance relations
    method: generate several trees
    TODO: to test and decide whether delete this function
    """
    # 备选节点
    # N = 100;
    # n = int(0.25*N)
    # nodes = random.sample(range(N),n)
    nodes = list(range(n))
    # 构建邻接矩阵
    adj_matrix = np.zeros((n,n), dtype=int)
    width = min(6, n)
    k = int(0.6*width)
    for i in range(len(nodes)):
        covered = []
        if i+1 < width:
            # each of the first width nodes must dominate at least one nodes
            num_selected = max(random.randint(0,k), 1)
            num_selected = min(n-(i+1), num_selected)
            covered = random.sample(nodes[i+1: i+width+1], num_selected)
        elif i+width <= n:
            # only the node except the last width nodes dominates other nodes
            num_selected = random.randint(0,k)
            num_selected = min(n-(i+1), num_selected)
            covered = random.sample(nodes[i+1: i+width+1], num_selected)
        adj_matrix[i,covered] = 1
        
    # reach_matrix, cover_matrix, minimal_nodes = get_reach_cover_minomalNodes(adj_matrix)
    
    # G = nx.from_numpy_array(adj_matrix, create_using=nx.DiGraph)
    # ajd_edge = G.edges
    # CoverG = nx.from_numpy_array(cover_matrix, create_using=nx.DiGraph)
    # cover_edge = CoverG.edges
    # ReachG = nx.from_numpy_array(reach_matrix, create_using=nx.DiGraph)
    # reach_edge = ReachG.edges
    # pos = nx.spiral_layout(G, resolution=2,equidistant=True)
    # G.remove_edges_from(cover_edge)
    # nx.draw(G, pos, with_labels=True, node_size=100, font_size=8, width=0.5, style=':')
    # # nx.draw_networkx_labels(G, pos,  font_size=8)
    # nx.draw_networkx_edges(G, pos, edgelist=cover_edge, width=1, edge_color='g')
    # plt.title('Donimance Relations')
    # plt.show()
    
    # # # pos = nx.spring_layout(G, seed=2023)
    # # pos = nx.nx_pydot.graphviz_layout(G)
    # # pos = nx.drawing.nx_pydot.graphviz_layout(G)
    # # pos = nx.planar_layout(G)
    # # pos = nx.kamada_kawai_layout(G)
    # # pos = nx.circular_layout(G)
    
    return adj_matrix

def get_reach_cover_minomalNodes(adj_matrix):
    """
    get the corresponding matrix from adjacent matrix of a graph
    reach_matrix: reach matrix indicating the reachibility of two nodes
    cover_matrix: conver matrix indicating the cover relation between two nodes
    minimal_nodes: minimal nodes, the dominated node of each chain
    """
    # G = nx.from_numpy_array(adj_matrix, create_using=nx.DiGraph)
    # roots  = [v for v, d in DG.in_degree() if d==0]
    # leaves = [v for v, d in DG.out_degree() if d==0]
    # reach_matrix = np.zeros
    # minimal_nodes = leaves
    adj_matrix = np.array(adj_matrix, dtype=bool)
    A = adj_matrix.dot(adj_matrix)
    R = A
    reach_matrix_old = adj_matrix
    for i in range(1,adj_matrix.shape[0]):
        A = A.dot(adj_matrix)
        R = R + A
        reach_matrix = adj_matrix + R
        if (reach_matrix==reach_matrix_old).all():
            break
        reach_matrix_old = reach_matrix
        
    reach_matrix = 1 * reach_matrix
    cover_matrix = 1 * (adj_matrix & ~(adj_matrix & R) )
    minimal_nodes = np.where((adj_matrix.sum(0) > 0) & (adj_matrix.sum(1)==0))[0] # 入度>0 & 出度=0
    return reach_matrix, cover_matrix, minimal_nodes

def get_luceInfo(LuceConstrDF):
    numCust = len(LuceConstrDF.columns.get_level_values(0).unique())
    luce_numPath_avgLength = []
    for j in range(numCust):
        row_ind = LuceConstrDF.loc[:,('on{}'.format(j),'row')].dropna().astype('int')
        col_ind = LuceConstrDF.loc[:,('on{}'.format(j),'col')].dropna().astype('int')
        nodes_perturb = LuceConstrDF.loc[:,('on{}'.format(j),'prodPerturb')].dropna().astype('int')
        adj_matrix = np.zeros((nodes_perturb.max()+1, nodes_perturb.max()+1), dtype='int')
        adj_matrix[row_ind, col_ind] = 1
        DG = nx.from_numpy_array(adj_matrix, create_using=nx.DiGraph)
        roots  = [v for v, d in DG.in_degree() if d==0]
        leaves = [v for v, d in DG.out_degree() if d==0]
        
        # roots  = np.where((adj_matrix.sum(0) == 0) & (adj_matrix.sum(1)>0))[0]
        # leaves = np.where((adj_matrix.sum(0) > 0) & (adj_matrix.sum(1)==0))[0]  # 入度>0 & 出度=0
        # chain constr
        all_paths = []
        for root in roots:
            paths = nx.all_simple_paths(DG, root, leaves)
            all_paths.extend(paths)
        path_length = []
        for path in all_paths:
            path_length.append(len(list(path)))
        avg_length = np.mean(path_length)
        num_paths = len(path_length)    
        luce_numPath_avgLength.append([num_paths, avg_length])
    luce_numPath_avgLength = pd.DataFrame(luce_numPath_avgLength, columns=['num_paths', 'avg_length'])
    return luce_numPath_avgLength


def plot_network(adj_matrix, cover_matrix, luceType='', nodeGroup=''):    
    if luceType == 'GroupPair':
        G = nx.from_numpy_array(adj_matrix, create_using=nx.DiGraph)
        ajd_edge = G.edges
        CoverG = nx.from_numpy_array(cover_matrix, create_using=nx.DiGraph)
        cover_edge = CoverG.edges
        # n = len(I)//3
        # g1 = I[0:n]
        # g2 = I[n:-n]
        # g3 = I[-n:]
        g1 = nodeGroup[0].values
        g2 = nodeGroup[1].values
        g3 = nodeGroup[2].values
        pos = {}
        n_row = int(np.sqrt(len(g2)) ) + 1
        high  = -0.07
        width = 0.07
        loc_1 = np.array([0., 0.])
        loc_2 = np.array([0.4, 0.5])
        loc_3 = np.array([0.9, 0.0])
        for k in range(len(g1)):
            node = g1[k]
            row = k // n_row + 1
            col = k %  n_row
            pos[node] = np.array([col*width, row*high]) + loc_1
        for k in range(len(g2)):
            node = g2[k]
            row = k // n_row + 1
            col = k %  n_row
            pos[node] = np.array([col*width, row*high]) + loc_2
        for k in range(len(g3)):
            node = g3[k]
            row = k // n_row + 1
            col = k %  n_row
            pos[node] = np.array([col*width, row*high]) + loc_3
            
        nodes = nx.draw_networkx_nodes(
                    G, 
                    pos, 
                    node_size=100,
                    label = None
                    )
        nodes_label = nx.draw_networkx_labels(
                            G, 
                            pos, 
                            font_size=8,
                            labels = {n: n+1 for n in G}
                            )
        reach_edges_line = nx.draw_networkx_edges(
                                G, 
                                pos,  
                                edgelist=ajd_edge, 
                                width=0.5, 
                                style='--',
                                label = 'reach'
                                )
        # nx.draw_networkx_labels(G, pos,  font_size=8)
        cover_edges_line = nx.draw_networkx_edges(
                                G,
                                pos, 
                                edgelist=cover_edge, 
                                width=1, 
                                edge_color='g',
                                label = 'cover'
                                )
        plt.title('Donimance Relations')
        plt.legend(
                handles=[ cover_edges_line[0]], 
                labels=[ "cover edges"], 
                fontsize  = 5,
                borderpad = 0.1,
                labelspacing = 0.1,
                handlelength=3.0, 
                handleheight=0.05,  
                loc='upper right')
        plt.show()
    elif luceType == 'Tree':
        adj_matrix_tree = adj_matrix[nodeGroup,:][:,nodeGroup]
        cover_matrix_tree = cover_matrix[nodeGroup,:][:,nodeGroup]
        G = nx.from_numpy_array(adj_matrix_tree, create_using=nx.DiGraph)
        ajd_edge = G.edges
        CoverG = nx.from_numpy_array(cover_matrix_tree, create_using=nx.DiGraph)
        cover_edge = CoverG.edges
        
        # # pos = nx.spring_layout(G, seed=2023)
        
        # pos = nx.nx_pydot.graphviz_layout(G)
        # pos = nx.drawing.nx_pydot.graphviz_layout(G)
        # pos = nx.planar_layout(G)
        # pos = nx.kamada_kawai_layout(G)
        # pos = nx.circular_layout(G)
        pos = nx.spiral_layout(G, resolution=2,equidistant=True)
        # G.remove_edges_from(cover_edge)
        
        nodes = nx.draw_networkx_nodes(
                    G, 
                    pos, 
                    node_size=100,
                    label = None
                    )
        nodes_label = nx.draw_networkx_labels(
                            G, 
                            pos, 
                            font_size=8,
                            labels = {n: nodeGroup[n]+1 for n in range(len(nodeGroup))}
                            )
        reach_edges_line = nx.draw_networkx_edges(
                                G, 
                                pos,  
                                edgelist=ajd_edge, 
                                width=0.5, 
                                style='--',
                                label = 'reach'
                                )
        # nx.draw_networkx_labels(G, pos,  font_size=8)
        cover_edges_line = nx.draw_networkx_edges(
                                G,
                                pos, 
                                edgelist=cover_edge, 
                                width=1, 
                                edge_color='g',
                                label = 'cover'
                                )
        plt.title('Donimance Relations')
        plt.legend(
                handles=[ cover_edges_line[0]], 
                labels=[ "cover edges"], 
                fontsize  = 5,
                borderpad = 0.1,
                labelspacing = 0.1,
                handlelength=3.0, 
                handleheight=0.05,  
                loc='upper right')
        plt.show()
    return


def get_model_location(modelName, model_list):
    """
    get the location of "modelName" in the "model_list"

    Parameters
    ----------
    modelName : string
        model name.
    model_list : list of string
        list of model name.

    Returns
    -------
    loc_aCModel : Int
        location script.
    """
    modelName_info = modelName.split('-')
    loc_aCModel = -1
    for k in range(len(model_list)):
        s1 = all(key in model_list[k].split('-') for key in modelName_info )
        if 'mo' in modelName_info:
            s2 = s1 and 'mo' in model_list[k].split('-')
        else:
            s2 = s1 and 'mo' not in model_list[k].split('-')
        if s2:
            loc_aCModel = k
            break
        else:
            continue
    return loc_aCModel

def get_model_list(modelReport):
    model_list = modelReport.copy()
    for modelName in modelReport:
        if 'aC' not in modelName:
            continue
        loc_index = get_model_location(modelName, model_list)
        modelType = modelName.split('-')[0]
        if 'mo' in modelName.split('-'):
            modelType = modelType + '-mo'
        if 'soc' in modelName.split('-'):
            modelType = modelType + '-soc'
        modelType_C = modelType + '-C'
        modelType_cut = modelType + '-C-cut'
        if loc_index >=0:
            model_list.insert(loc_index, modelType_C)
            model_list.insert(loc_index+1, modelType_cut)
    return model_list

# #%%
# def getMCbound(data):
#     value_off_0 = data.value_off_0
#     value_off_v = data.value_off_v
#     value_on_0 = data.value_on_0
#     value_on_v = data.value_on_v
#     r_off = data.r_off
#     r_on = data.r_on
#     I = data.I
#     J = data.J
#     prod_cust = data.prod_cust
#     numProd = data.numProd
#     numCust = data.numCust
    
#     # y_off_0_l0 = np.zeros(numCust,1)
#     # for j in I:
        
#     #     y_off_0_l0[j] = 
#     # y_off_0_l1 = 
#     # y_off_0_u1 = 
#     # y_on_0_l = 
#     # y_on_0_u = 
        
#%%
def cutAll(value_off_0, value_off_v, numProd):
    numVertices = 2**(numProd-1)
    I = np.arange(numProd)
    x_vertices = np.array(list(itertools.product([0,1], repeat=numProd)))
    
    ineq_coe1_dict = {}
    ineq_coe2_dict = {}
    columns_name_x = ["x[{}]".format(i) for i in range(numProd)]
    columns_name_y0=['y0']
    columns_name_y =['y[{}]'.format(i) for i in range(numProd)]
    columns_name = np.hstack((columns_name_x, columns_name_y0, columns_name_y))
    
    alp = Alpha(value_off_0, value_off_v)
    for i in range(numProd):
        set_indict = x_vertices[x_vertices[:,i]==0]
        ineq_coe1_df = pd.DataFrame(index=range(numVertices), columns=columns_name)
        ineq_coe2_df = pd.DataFrame(index=range(numVertices), columns=columns_name)
        for v in range(numVertices):
            S = np.where(set_indict[v,:])
            S_temp = np.append(S, i)
            ineq_coe1_xi = -alp.compute(S_temp)
            ineq_coe1_x = np.zeros(numProd)
            ineq_coe1_x[i] = ineq_coe1_xi
            ineq_coe1_y0 = 0
            ineq_coe1_y = np.zeros(numProd)
            ineq_coe1_y[i] = 1
            ineq_coe1_y[np.setdiff1d(I, S_temp)] = alp.compute(S_temp) * value_off_v[np.setdiff1d(I, S_temp)]
            ineq_coe1 = [ineq_coe1_x, ineq_coe1_y0, ineq_coe1_y]
            
            T = np.where(set_indict[v,:])
            T_temp = np.append(T, i)
            ineq_coe2_xi = alp.compute(T_temp)
            ineq_coe2_x = np.zeros(numProd)
            ineq_coe2_x[i] = ineq_coe2_xi
            ineq_coe2_y0 = (1 - (value_off_0 + value_off_v[i]) * alp.compute(T_temp))
            ineq_coe2_y = np.zeros(numProd)
            ineq_coe2_y[i] = -1
            ineq_coe2_y[T] = -alp.compute(T_temp) * value_off_v[T]
            ineq_coe2 = [ineq_coe2_x, ineq_coe2_y0, ineq_coe2_y]
            
            ineq_coe1_df.iloc[v, :] = np.hstack(ineq_coe1)
            ineq_coe2_df.iloc[v, :] = np.hstack(ineq_coe2)
            
        ineq_coe1_dict[i] = ineq_coe1_df
        ineq_coe2_dict[i] = ineq_coe2_df
        
    ineq_coe1 = pd.concat(ineq_coe1_dict.values(), axis=0)
    ineq_coe2 = pd.concat(ineq_coe2_dict.values(), axis=0)
    return ineq_coe1, ineq_coe2


#%%
def check_constraint(data, inst, nodelName, constrType):
    value_off_0 = data.value_off_0
    value_off_v = data.value_off_v
    value_on_0  = data.value_on_0
    value_on_v  = data.value_on_v
    I = inst.I
    j = inst.J
    numProd = inst.numProd
    numCust = inst.numCust
    
    Sols = inst.Sols.copy()
    nodelName = 'MC_Conic-aC'
    nodelName = 'MC_Conic-C-cut11'
    constrType = 'Conic_off'
    
    sol = Sols[nodelName].dropna()
    x_off_name = [name for name in sol.index if 'x_off' in name]
    y_off_0_name = 'y_off_0'
    y_off_y_name = [name for name in sol.index if 'y_off_y' in name]
    x_on_name = [name for name in sol.index if 'x_on' in name]
    y_on_0_name = [name for name in sol.index if 'y_on_0' in name]
    y_on_y_name = [name for name in sol.index if 'y_on_y' in name]
    
    s_x_off = sol.loc[x_off_name].values
    s_y_off_0 = sol.loc[y_off_0_name]
    s_y_off_y = sol.loc[y_off_y_name].values
    s_x_on = sol.loc[x_on_name].values.reshape(numProd, numCust)
    s_y_on_0 = sol.loc[y_on_0_name].values
    s_y_on_y = sol.loc[y_on_y_name].values.reshape(numProd, numCust)
    
    # verfy Conic_off satisfication
    epsilon = 1e-12
    w_off = value_off_0 + sum(value_off_v[i]*s_x_off[i] for i in I)
    w_off * s_y_off_0 >= 1 - epsilon
    w_off * s_y_off_y >= s_x_off**2 - epsilon
    value_off_0 * s_y_off_0 + sum(value_off_v[i]*s_y_off_y[i] for i in I) >= 1 - epsilon
    
    
    rank = np.argsort(s_y_off_y)
    wrong_index=[]
    for k in range(len(rank)):
        S = rank[-k:]
        alp = Alpha(value_off_0, value_off_v, value_on_0, value_on_v)
        alp_v = alp.compute(S,-1) 
        rhs = alp_v * (1-sum(value_off_v[i]*s_y_off_y[i] for i in np.setdiff1d(I, S)))
        if s_y_off_0 - rhs >= - epsilon:
            print('ok:{}'.format(s_y_off_0 - rhs))
        else:
            print('y_off_0<rhs')
            wrong_index.append(k)
            
def compare_separateTime(inst):
    
    data = inst.data
    numProd = data.numProd
    numCust = data.numCust
    I = np.arange(numProd)
    J = np.arange(numCust)
    
    solution  = inst.Sols.iloc[:,0]
    solution  = inst.Sols.iloc[:,-1]
    s_x_off   = solution[[ind for ind in solution.index if 'x_off' in ind]].values
    s_y_off_0 = solution[[ind for ind in solution.index if 'y_off_0' in ind]].values
    s_y_off_y = solution[[ind for ind in solution.index if 'y_off_y' in ind]].values
    s_x_on    = solution[[ind for ind in solution.index if 'x_on' in ind]].values
    if len(s_x_on) > 0 : s_x_on.reshape(numProd,numCust)
    s_y_on_0  = solution[[ind for ind in solution.index if 'y_on_0' in ind]].values
    s_y_on_y  = solution[[ind for ind in solution.index if 'y_on_y' in ind]].values.reshape(numProd,numCust)
    
    Time = pd.DataFrame(columns=['compare', 'sort'])
    for k in range(100):
        j=k%numCust
        y0 = s_y_on_0
        y = s_y_on_y[:,j]
        # time10 = time.process_time()
        time10 = time.perf_counter()
        for i in I:
            S = I[y >= y[i]]
            T = I[y >= y[i]]
        # time11 = time.process_time() - time10
        time11 = time.perf_counter() - time10
        
        # time20 = time.process_time()
        time20 = time.perf_counter()
        y_sort_ind = np.argsort(-y)
        for i in I:
            S = y_sort_ind[:(i+1)]
            T = y_sort_ind[-(i+1):]
        # time21 = time.process_time() - time20
        time21 = time.perf_counter() - time20
        Time.loc[k] = [time11, time21]
    Time.sum()
    return Time

#%%
####### testing
if __name__ == '__main__':
    # ########## generating test data
    random.seed(2022)
    numProd = 10
    u0 = 1 + np.random.randint(1, 10)
    u = np.reshape(1 + np.random.permutation(10), numProd)

    # generate feasible (x, y0, y)
    S0 = np.array([1, 3, 4])
    i = 3
    xi = 0.5
    y0 = 1 / (u0 + sum(u[S0]))
    z = (1 - u0 * y0) * np.random.rand(numProd) / numProd
    for k in range(50):
        z = z + (1 - u0 * y0 - sum(z)) * np.random.rand(numProd) / numProd
        y = z / u
        y[y > y0] = y0 * 0.9
        z = u * y

    z[-1] = z[-1] + (1 - u0 * y0 - sum(z))
    y = z / u

    # call separate function
    infeasi_flag, [coe_xi, coe_y0, coe_y] = separate(i, xi, y0, y, u0, u)
    print("infeasible flag:", infeasi_flag)
    print("coefficients:", [coe_xi, coe_y0, coe_y])


#%% check valid inequalities
# # dataDF = dataHist[sort_ind[0]]
# dataDF = dataHist[0]
# sol = SolsHist[0]
# thismodel = modelHist[0]
# I = thismodel.I
# J = thismodel.J

# #  get the inequalities coefficients for off-line customer
# value_off_0 = thismodel.data.value_off_0
# value_off_v = thismodel.data.value_off_v
# off_ineq_coe1, off_ineq_coe2 = cutAll(value_off_0, value_off_v, numProd)

# #  get the inequalities coefficients for on-line customer
# j=0
# value_on_0 = thismodel.data.value_on_0[j]
# value_on_v = thismodel.data.value_on_v[:,j]
# on_ineq_coe1, on_ineq_coe2 = cutAll(value_on_0, value_on_v, numProd)


# # check the validness
# x_off_vertices = np.array(list(itertools.product([0,1], repeat=numProd)))
# numVertices = 2**numProd
# alp = Alpha(value_off_0, value_off_v)
# y_off_0 = np.array([alp.compute(np.where(x_off_vertices[row,:])) for row in range(numVertices)])
# y_off_y = np.array([[y_off_0[row] * x_off_vertices[row, col] for col in range(numProd) ] for row in range(numVertices)])
# x_y_off_vertices_pd = pd.DataFrame(x_off_vertices, columns=["x[{}]".format(i) for i in range(numProd)])
# x_y_off_vertices_pd.loc[:, 'y0'] = y_off_0
# x_y_off_vertices_pd.loc[:, ['y[{}]'.format(i) for i in range(numProd)]] = y_off_y

# cutplane1_result = off_ineq_coe1 @ x_y_off_vertices_pd.T
# cutplane2_result = off_ineq_coe2 @ x_y_off_vertices_pd.T
# activeCutplane1_indict = cutplane1_result>=-1e-10  # >=0
# activeCutplane2_indict = cutplane2_result>=-1e-10  # >=0
# (activeCutplane1_indict) & (activeCutplane2_indict)

# activeCutplane1_indict = abs(cutplane1_result)<=1e-10  # ==0
# activeCutplane2_indict = abs(cutplane2_result)<=-1e-10 # ==0
# (activeCutplane1_indict) & (activeCutplane2_indict)
# # ???
