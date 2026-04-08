%% ============================================================
%  配电网可靠性评估 —— R11（IP + 割平面 + 凸包方法）
%
%  §6 替换说明:
%    原§6 使用 YALMIP 直接建模分式目标 MILP（Gurobi 拒绝非凸分式目标）。
%    新§6 采用以下三层嵌套框架，完全对齐 Python 框架:
%
%    [外层] Dinkelbach 参数化迭代
%           max f(x)/g(x)  →  max f(x) − λ·g(x)，迭代更新 λ
%           对应 run_callback.py 外层循环 + run_plain_repeat.py 迭代结构
%
%    [内层] K 轮割平面循环 (cut_round_limit = CUT_ROUND_LIMIT)
%           Round-0 : LP 松弛求解（对应 MC_Conv-C 连续松弛）
%           Round-k : separate_oracle() 寻找违反凸包约束的点，添加割平面
%                     对应 Python ToolFunctions.separate() 在可靠性场景的适应版本
%           最终轮  : 整数 MILP + 全部累积割平面
%
%    [割平面分类（对应 Python separate() 的两类有效不等式）]:
%         Type-1 (路径连通性, ≡ B_less 不等式):
%               Q(k,s) ≤ S(b,s)，针对路径瓶颈分支 b
%               — 若 LP 解中节点 k 的恢复概率大于其路径上某分支的开关概率，
%                 则该点不在可行集的凸包内，需添加切割
%         Type-2 (区域容量, ≡ B_greater 不等式):
%               Σ_{k∈Aff} Q(k,s) ≤ |Aff|·S(t,s)，针对联络线 t
%               — 若 LP 解中某故障场景受影响节点的总恢复量超过联络线
%                 可提供的最大容量，则需添加区域级切割
%
%  依赖: YALMIP + Gurobi
%  参考: Chen, He, Rong, Wang (2025). An Integer Programming Approach
%        for Quick-Commerce Assortment Planning. arXiv:2405.02553v2.
% =============================================================
clear; clc;

%% ── 用户配置区 ─────────────────────────────────────────────
% ── 系统文件 ──────────────────────────────────────────────────
sys_filename = '85-Node System Data.xlsx';
%sys_filename = '137-Node System Data.xlsx';
%sys_filename = '417-Node System Data.xlsx';
%sys_filename = '1080-Node System Data.xlsx';

tb_filename = 'Testbench for Linear Model Based Reliability Assessment Method for Distribution Optimization Models Considering Network Reconfiguration.xlsx';

sys_sheet = '85-node';
%sys_sheet = '137-node';
%sys_sheet = '417-node';
%sys_sheet = '1080-node';

LAMBDA_TRF = 0.5;        % 变压器故障率（0=统一用线路公式）
TAU_UP_SW  = 0.3;        % 上游开关操作时间(h)
TAU_TIE_SW = 0.5;        % 联络开关切换时间(h)

% [Q1] 综合重要性评分权重与分级阈值
W_SCORE_NC = 0.5;        % NC占比权重
W_SCORE_P  = 0.5;        % 需求占比权重
RATIO_L1   = 0.30;       % 累积重要性前30%→L1
RATIO_L2   = 0.30;       % 接下来30%→L2，其余→L3

% VOLL基准（元/kWh）与扰动
VOLL_BASE  = [200, 50, 10];   % [L1, L2, L3]
VOLL_NOISE = 0.20;
VOLL_SEED  = 123;

% 切负荷上限比例
SHED_LIMIT    = [0.00, 0.25, 1.00];  % [L1, L2, L3]
FLEX_RATIO_L3 = 0.8;   % L3快速响应比例（柔性资源）

% [Q2] 低压分支开关参数
N_BR_THRESHOLDS = [50, 150, 400];   % NC阈值
N_BR_VALUES     = [2, 3, 4, 5];    % 对应低压分支数
LV_REGEN        = true;            % false=复用固定种子；true=重新生成
LV_SEED         = 42;

% [Q4] 开关动作次数惩罚（元/次，0=不考虑）
GAMMA_SWITCH = 0;

SOLVE_MODE = 'MCF';
V_UPPER = 1.05; V_LOWER = 0.95; V_SRC = 1.0; PF = 0.9;

% §6 IP+割平面+凸包 专属参数
timelimit       = 3600;   % 总时限(秒)，用于每轮 MILP 求解
CUT_ROUND_LIMIT = 2;      % 割平面轮数 K（对应 Python cut_round_limit=2）
DINK_MAX_ITER   = 15;     % Dinkelbach 最大迭代次数
DINK_TOL        = 1e-3;   % Dinkelbach 收敛容差（Dinkelbach gap）
SEP_TOL         = 1e-6;   % 分离算法容差（对应 Python separate_tol=1e-9 量级）
MILP_GAP_TOL    = 1e-3;   % MILP MIPGap 参数
% ──────────────────────────────────────────────────────────────

program_total = tic;

%% §1  Testbench 数据读取
fprintf('>> [1/8] 读取 Testbench: Sheet="%s"\n', sys_sheet);
tb_cell = readcell(tb_filename, 'Sheet', sys_sheet);
nrows_tb = size(tb_cell,1);
hdr_row = 0;
for ri = 1:nrows_tb
    if ischar(tb_cell{ri,1}) && contains(tb_cell{ri,1},'Tie-Switch')
        hdr_row = ri; break;
    end
end
if hdr_row==0, error('未找到Tie-Switch表头行'); end
LINE_CAP = str2double(extractBefore(string(tb_cell{hdr_row+1,4}),' '));
TRAN_CAP = LINE_CAP;
TIE_LINES_RAW = [];
for ri = hdr_row+2:nrows_tb
    v1=tb_cell{ri,1}; v2=tb_cell{ri,2};
    if isnumeric(v1)&&~isnan(v1)&&isnumeric(v2)&&~isnan(v2)
        TIE_LINES_RAW(end+1,:)=[v1,v2]; %#ok<AGROW>
    end
end
fprintf('   线路容量=%.0f MW，联络线=%d条\n', LINE_CAP, size(TIE_LINES_RAW,1));

%% §2  可靠性参数读取
fprintf('>> [2/8] 读取可靠性参数: %s\n', sys_filename);
t_branch = readtable(sys_filename,'Sheet','Branch Lengths (km)');
t_branch = t_branch(:,1:3); t_branch.Properties.VariableNames = {'From','To','Length_km'};
t_branch = t_branch(~isnan(t_branch.From),:);
t_dur = readtable(sys_filename,'Sheet','Interruption durations (h)','HeaderLines',3);
t_dur = t_dur(:,1:4); t_dur.Properties.VariableNames = {'From','To','RP','SW'};
t_dur = t_dur(~isnan(t_dur.From),:);
t_cust = readtable(sys_filename,'Sheet','Numbers of customers per node');
t_cust = t_cust(:,1:2); t_cust.Properties.VariableNames = {'Node','NC'};
t_cust = t_cust(~isnan(t_cust.Node),:);
t_peak = readtable(sys_filename,'Sheet','Peak Nodal Demands (kW)');
t_peak = t_peak(:,1:2); t_peak.Properties.VariableNames = {'Node','P_kW'};
t_peak = t_peak(~isnan(t_peak.Node),:);
t_other = readtable(sys_filename,'Sheet','Other data','ReadVariableNames',false);
col1 = cellfun(@(x) string(x), t_other{:,1}, 'UniformOutput', true);
lambda_per_km = str2double(string(t_other{find(contains(col1,'Failure rate'),1),2}));
row_dur = find(contains(col1,'Duration'),1);
T_l = [str2double(string(t_other{row_dur,3})), str2double(string(t_other{row_dur+1,3})), str2double(string(t_other{row_dur+2,3}))];
row_lf = find(contains(col1,'Loading factors'),1);
L_f = [str2double(string(t_other{row_lf,3})), str2double(string(t_other{row_lf+1,3})), str2double(string(t_other{row_lf+2,3}))]/100;
fprintf('   lambda=%.4f/km\n', lambda_per_km);

%% §3  潮流参数
R_KM=0.003151; X_KM=0.001526; TAN_PHI=tan(acos(PF));
V_src_sq=V_SRC^2; V_upper_sq=V_UPPER^2; V_lower_sq=V_LOWER^2;
M_V=(V_upper_sq-V_lower_sq)*2; M_vn=V_upper_sq;

%% §4  拓扑索引
fprintf('>> [4/8] 构建拓扑索引...\n');
raw_nodes=unique([t_branch.From;t_branch.To;TIE_LINES_RAW(:)]);
num_nodes=length(raw_nodes);
node_map=containers.Map(raw_nodes,1:num_nodes);
inv_map=raw_nodes;
subs_raw=raw_nodes(~ismember(raw_nodes,t_cust.Node));
subs_idx=arrayfun(@(s) node_map(s), subs_raw);
nB_norm=height(t_branch); nTie=size(TIE_LINES_RAW,1); nB_all=nB_norm+nTie;

rel_branches=zeros(nB_norm,8);
for b=1:nB_norm
    u_raw=t_branch.From(b); v_raw=t_branch.To(b);
    u=node_map(u_raw); v=node_map(v_raw); len=t_branch.Length_km(b);
    match=(t_dur.From==u_raw&t_dur.To==v_raw)|(t_dur.From==v_raw&t_dur.To==u_raw);
    if ~any(match), error('分支(%d-%d)无停电时间',u_raw,v_raw); end
    is_trf=ismember(u,subs_idx)|ismember(v,subs_idx);
    cap_b=TRAN_CAP*is_trf+LINE_CAP*(~is_trf);
    lam_b=ternary(LAMBDA_TRF>0&&is_trf, LAMBDA_TRF, len*lambda_per_km);
    rel_branches(b,:)=[u,v,lam_b,t_dur.RP(match),t_dur.SW(match),R_KM*len,X_KM*len,cap_b];
end
is_trf_vec=ismember(rel_branches(:,1),subs_idx)|ismember(rel_branches(:,2),subs_idx);
n_trf=sum(is_trf_vec);

tie_branches=zeros(nTie,8);
for t=1:nTie
    u=node_map(TIE_LINES_RAW(t,1)); v=node_map(TIE_LINES_RAW(t,2));
    tie_branches(t,:)=[u,v,0,0,0,R_KM*0.1,X_KM*0.1,LINE_CAP];
end
all_branches=[rel_branches;tie_branches];
branch_from=all_branches(:,1); branch_to=all_branches(:,2);
r_b_all=all_branches(:,6); x_b_all=all_branches(:,7); cap_b_all=all_branches(:,8);

load_nodes=setdiff(1:num_nodes,subs_idx); nL=length(load_nodes); non_sub=load_nodes;
A_inc_norm=sparse(rel_branches(:,2),(1:nB_norm)',+1,num_nodes,nB_norm)+sparse(rel_branches(:,1),(1:nB_norm)',-1,num_nodes,nB_norm);
A_inc_all=sparse(branch_to,(1:nB_all)',+1,num_nodes,nB_all)+sparse(branch_from,(1:nB_all)',-1,num_nodes,nB_all);
A_free_all=A_inc_all(load_nodes,:);
B_to_all=sparse((1:nB_all)',branch_to,1,nB_all,num_nodes);
B_from_all=sparse((1:nB_all)',branch_from,1,nB_all,num_nodes);
BdV=B_to_all-B_from_all;
[~,pk_row]=ismember(inv_map(load_nodes),t_peak.Node);
P_free=zeros(nL,1); valid_pk=pk_row>0;
P_free(valid_pk)=t_peak.P_kW(pk_row(valid_pk))/1e3;
Q_free=P_free*TAN_PHI;

%% ================================================================
%  §4b  [Q1+Q2] 负荷分级 & 低压分支开关档位
% ================================================================
[~,c_row_pre]=ismember(inv_map(load_nodes),t_cust.Node);
NC_vec=zeros(nL,1); NC_vec(c_row_pre>0)=t_cust.NC(c_row_pre(c_row_pre>0));

% [Q1] 综合评分排序
total_NC=max(sum(NC_vec),1); total_P=max(sum(P_free),1e-9);
score_k = W_SCORE_NC*(NC_vec/total_NC) + W_SCORE_P*(P_free/total_P);
[score_sorted,sort_idx]=sort(score_k,'descend');
cum_score=cumsum(score_sorted)/max(sum(score_sorted),1e-9);

rank_vec=zeros(nL,1);
rank_vec(sort_idx(cum_score<=RATIO_L1))=1;
rank_vec(sort_idx(cum_score>RATIO_L1 & cum_score<=RATIO_L1+RATIO_L2))=2;
rank_vec(sort_idx(cum_score>RATIO_L1+RATIO_L2))=3;
idx_L1=find(rank_vec==1); idx_L2=find(rank_vec==2); idx_L3=find(rank_vec==3);
nL1=length(idx_L1); nL2=length(idx_L2); nL3=length(idx_L3);

shed_limit_vec=zeros(nL,1);
shed_limit_vec(idx_L1)=SHED_LIMIT(1);
shed_limit_vec(idx_L2)=SHED_LIMIT(2);
shed_limit_vec(idx_L3)=SHED_LIMIT(3)*FLEX_RATIO_L3;

rng(VOLL_SEED);
voll_vec=zeros(nL,1);
voll_vec(idx_L1)=VOLL_BASE(1)*(1+VOLL_NOISE*(2*rand(nL1,1)-1));
voll_vec(idx_L2)=VOLL_BASE(2)*(1+VOLL_NOISE*(2*rand(nL2,1)-1));
voll_vec(idx_L3)=VOLL_BASE(3)*(1+VOLL_NOISE*(2*rand(nL3,1)-1));
voll_pu=voll_vec*1e3;

% [Q2] 低压分支开关档位生成
if ~LV_REGEN
    rng(LV_SEED);
    fprintf('   [Q2] 使用固定随机种子(LV_SEED=%d)\n', LV_SEED);
else
    fprintf('   [Q2] 重新生成低压分支权重(LV_REGEN=true)\n');
end

node_levels=cell(nL,1); n_br_vec=zeros(nL,1);
for k=1:nL
    if shed_limit_vec(k)<=1e-6
        node_levels{k}=[0]; continue;
    end
    nc_k=max(NC_vec(k),1);
    if nc_k<=N_BR_THRESHOLDS(1);       n_br=N_BR_VALUES(1);
    elseif nc_k<=N_BR_THRESHOLDS(2);   n_br=N_BR_VALUES(2);
    elseif nc_k<=N_BR_THRESHOLDS(3);   n_br=N_BR_VALUES(3);
    else;                               n_br=N_BR_VALUES(4);
    end
    n_br_vec(k)=n_br;
    raw_w=ones(1,n_br)/n_br + 0.1*(2*rand(1,n_br)-1);
    raw_w=max(raw_w,0.02);
    branch_w=raw_w/sum(raw_w);
    n_states=2^n_br;
    lset=zeros(1,n_states);
    for s=0:n_states-1
        bits=bitget(s,1:n_br,'uint32');
        lset(s+1)=sum(branch_w.*double(bits));
    end
    lset=sort(unique(round(lset,4)));
    lset=lset(lset<=shed_limit_vec(k)+1e-6);
    if isempty(lset)||lset(1)~=0, lset=[0,lset]; end
    node_levels{k}=lset;
end
n_lev_arr=cellfun(@length,node_levels);

fprintf('   [Q1]负荷分级: L1=%d, L2=%d, L3=%d节点\n',nL1,nL2,nL3);
fprintf('   VOLL[元/kWh]: L1=%.0f~%.0f, L2=%.0f~%.0f, L3=%.0f~%.0f\n', ...
    min(voll_vec(idx_L1)),max(voll_vec(idx_L1)),min(voll_vec(idx_L2)),max(voll_vec(idx_L2)), ...
    min(voll_vec(idx_L3)),max(voll_vec(idx_L3)));
fprintf('   正常分支=%d，联络线=%d，负荷节点=%d\n',nB_norm,nTie,nL);

%% ================================================================
%  §5  MCF 路径识别
% ================================================================
fprintf('>> [5/8] MCF 路径识别...\n');
t_mcf=tic;
nSub=length(subs_idx); E_sub=sparse(subs_idx,1:nSub,1,num_nodes,nSub);

if strcmp(SOLVE_MODE,'MCF')
    E_load=sparse(load_nodes,1:nL,1,num_nodes,nL);
    F_mat=sdpvar(nB_norm,nL,'full'); Z_mat=sdpvar(nB_norm,nL,'full'); Gss=sdpvar(nSub,nL,'full');
    C_mcf=[-Z_mat<=F_mat,F_mat<=Z_mat,Z_mat>=0,0<=Gss<=1,sum(Gss,1)==1,A_inc_norm*F_mat==E_load-E_sub*Gss];
    sol=optimize(C_mcf,sum(sum(Z_mat)),sdpsettings('solver','gurobi','verbose',0));
    if sol.problem~=0, error('MCF失败: %s',sol.info); end
    f_res=sparse(abs(value(F_mat))>0.5);
else
    f_res=false(nB_norm,nL); opts_sp=sdpsettings('solver','gurobi','verbose',0);
    parfor k=1:nL
        f_k=sdpvar(nB_norm,1); z_k=sdpvar(nB_norm,1); g_k=sdpvar(nSub,1);
        d_k=sparse(load_nodes(k),1,1,num_nodes,1)-E_sub*g_k;
        C_k=[-z_k<=f_k,f_k<=z_k,z_k>=0,0<=g_k<=1,sum(g_k)==1,A_inc_norm*f_k==d_k];
        optimize(C_k,sum(z_k),opts_sp); f_res(:,k)=abs(value(f_k))>0.5;
    end
    f_res=sparse(f_res);
end
p_mat=f_res';

is_outlet=ismember(rel_branches(:,1),subs_idx)|ismember(rel_branches(:,2),subs_idx);
p_feeder_mat=sparse(nL,nB_norm);
for xy=1:nB_norm
    dn_k=find(p_mat(:,xy),1); if isempty(dn_k), continue; end
    for bi=find(f_res(:,dn_k))'
        if is_outlet(bi), p_feeder_mat(:,xy)=f_res(bi,:)'; break; end
    end
end
p_feeder_mat=sparse(p_feeder_mat);
t_mcf_elapsed=toc(t_mcf);
fprintf('   MCF完成（%.1f秒），p_direct nnz=%d，p_feeder nnz=%d\n',...
    t_mcf_elapsed,nnz(p_mat),nnz(p_feeder_mat));

% MCF 后清除 YALMIP 内部状态，避免影响 §6 变量命名
yalmip('clear');

%% ================================================================
%  §6  IP + 割平面 + 凸包方法（分式目标 Dinkelbach 参数化）
%
%  设计对应关系（Python 框架 → MATLAB 可靠性适应版）:
%  ┌────────────────────────────┬──────────────────────────────────┐
%  │ Python (assortment)        │ MATLAB (reliability)             │
%  ├────────────────────────────┼──────────────────────────────────┤
%  │ x_i ∈ {0,1} (产品引入)    │ Q_mat(k,s) (节点恢复决策)        │
%  │ y_off_0, y_off_y (MNL概率) │ S_mat(b,s) (开关状态)           │
%  │ separate(i,xi,y0,y,u0,u)  │ separate_oracle(Q_hat,S_hat,...) │
%  │ B_less 不等式 (凸包Type-1) │ Q(k,s)≤S(b,s) 路径连通性割平面  │
%  │ B_greater 不等式 (Type-2)  │ ΣQ≤n·S(t,s) 区域容量割平面      │
%  │ cut_round_limit = K        │ CUT_ROUND_LIMIT = K              │
%  │ 分式目标 revenue/MNL       │ 分式目标 VOLL_saving/switch_cost │
%  │ Dinkelbach outer loop      │ Dinkelbach outer loop            │
%  └────────────────────────────┴──────────────────────────────────┘
% ================================================================
fprintf('>> [6/8] IP+割平面+凸包（Dinkelbach+路径切集分离）...\n');
t_milp = tic;

%% §6.0  算法参数（已在用户配置区定义）
opts_lp   = sdpsettings('solver','gurobi','verbose',0);
opts_milp = sdpsettings('solver','gurobi','verbose',0,...
            'gurobi.MIPGap',MILP_GAP_TOL,'gurobi.TimeLimit',timelimit);

fprintf('   [参数] CUT_ROUND=%d, DINK_MAX=%d, DINK_TOL=%.1e, SEP_TOL=%.1e\n',...
    CUT_ROUND_LIMIT, DINK_MAX_ITER, DINK_TOL, SEP_TOL);

%% §6.1  基础数据转换
nScen        = nB_norm;
p_mat_d      = double(p_mat);          % (nL × nScen)，节点-故障路径矩阵
p_feeder_d   = double(p_feeder_mat);   % (nL × nScen)，馈线-故障矩阵
lam_vec      = rel_branches(:,3);      % (nScen × 1)，各分支故障率
trp_vec      = rel_branches(:,4);      % (nScen × 1)，各分支修复时间
p_upstream_d = p_feeder_d - p_mat_d;   % 上游（馈线断路器侧）路径矩阵

%% §6.2  VOLL 目标函数线性化
%  核心思想（对应 Python MC_Conv 模型的线性化技巧）:
%  将 VOLL_loss_R2(Q,L) 分解为:
%    VOLL_loss_R2 = 常数项
%                + c_Q(k,s)·Q(k,s)  [联络恢复节约 + 等待修复成本，线性于 Q]
%                + c_L(k,s)·L(k,s)  [切负荷部分停电，线性于 L]
%  故 max VOLL_saving - λ·switch_cost 是关于 (Q,L,S) 的线性目标

[~,p_row] = ismember(inv_map(load_nodes), t_peak.Node);
P_avg = zeros(nL,1);
P_avg(p_row>0) = t_peak.P_kW(p_row(p_row>0)) * sum(L_f.*(T_l/8760));
voll_Pa = voll_vec .* P_avg;   % 元/年·MW 综合权重

% R1 基准损失（无重构时）
CID_up_const = TAU_UP_SW * (p_upstream_d * lam_vec);        % (nL×1)
CID_rep_noQ  = p_mat_d * (lam_vec .* trp_vec);              % (nL×1)
VOLL_loss_R1_val = sum(voll_Pa .* (CID_up_const + CID_rep_noQ));

% 目标系数矩阵
% c_Q(k,s) = voll_Pa(k)·p_mat(k,s)·λ_s·(τ_s - TAU_TIE)
%           > 0 表示恢复节点 k 在场景 s 有净收益
% c_L(k,s) = -voll_Pa(k)·p_mat(k,s)·λ_s·max(τ_s-TAU_TIE,0)/P_free(k)
%           ≤ 0 表示切负荷引入额外损失
P_free_safe = max(P_free, 1e-9);
Q_obj_coef  = zeros(nL, nScen);
L_obj_coef  = zeros(nL, nScen);
for s = 1:nScen
    ls = lam_vec(s); ts = trp_vec(s);
    Q_obj_coef(:,s) = voll_Pa .* p_mat_d(:,s) .* ls .* (ts - TAU_TIE_SW);
    L_obj_coef(:,s) = -voll_Pa .* p_mat_d(:,s) .* ls .* max(ts-TAU_TIE_SW,0) ./ P_free_safe;
end

%% §6.3  路径结构预计算（割平面分离 separate_oracle 所需）
%  path_branches_cell{k,s}: 节点 k 在故障 s 下的 MCF 最短路径分支集合
%  （排除故障分支 s 本身）
%  对应 Python separate() 中识别最优集合 S_star, T_star 的结构
f_res_full = full(f_res);               % (nB_norm × nL)
path_branches_cell = cell(nL, nScen);
for k = 1:nL
    for s = 1:nScen
        if p_mat_d(k,s) > 0.5
            pb = find(f_res_full(:,k) > 0.5);
            pb = pb(pb ~= s);           % 排除故障分支
            path_branches_cell{k,s} = pb;
        end
    end
end
tie_branch_idx = (nB_norm+1 : nB_all)';  % 联络线分支索引

%% §6.4  公共稀疏矩阵
Dr    = spdiags(r_b_all, 0, nB_all, nB_all);
Dx    = spdiags(x_b_all, 0, nB_all, nB_all);
Dp    = spdiags(P_free,  0, nL,     nL);
Dq_m  = spdiags(Q_free,  0, nL,     nL);
Cap   = spdiags(cap_b_all, 0, nB_all, nB_all);
fault_lin_idx = (0:nB_norm-1)*nB_all + (1:nB_norm);
P_max_mat = repmat(P_free, 1, nScen);

% ZZ 切负荷档位稀疏矩阵（与原§6相同）
can_shed = shed_limit_vec > 1e-6;
n_shed = sum(can_shed); shed_nodes_idx = find(can_shed);
total_ZZ = sum(n_lev_arr(shed_nodes_idx));
row_s=zeros(total_ZZ,1); val_sel=zeros(total_ZZ,1); val_one=ones(total_ZZ,1);
ptr=0;
for ki=1:n_shed
    k=shed_nodes_idx(ki); lv=node_levels{k}; nk=length(lv);
    rows=ptr+1:ptr+nk;
    row_s(rows)=ki; val_sel(rows)=P_free(k)*lv(:);
    ptr=ptr+nk;
end
col_s=(1:total_ZZ)';
SEL_s   = sparse(row_s, col_s, val_sel, n_shed, total_ZZ);
ONESUM_s= sparse(row_s, col_s, val_one, n_shed, total_ZZ);
fprintf('   ZZ档位列数=%d（可切节点%d/%d）\n', total_ZZ, n_shed, nL);

% 开关初始状态（正常分支闭合=1，联络线断开=0）
S_NO     = ones(nB_all, 1); S_NO(nB_norm+1:end) = 0;
S_NO_mat = repmat(S_NO, 1, nScen);

%% §6.5  割平面索引存储（跨 Dinkelbach 迭代共享）
%  存储方式: 纯数值索引，不含 YALMIP 对象引用
%  可在 yalmip('clear') 后重新为任意变量集生成约束
%  对应 Python run_callback.py 中 cut_number_off / cut_number_on 的累积机制
cut_type_arr  = zeros(0, 1);   % 1=路径连通 2=区域容量
cut_k_arr     = zeros(0, 1);   % 目标节点 (Type-1)
cut_s_arr     = zeros(0, 1);   % 故障场景
cut_b_arr     = zeros(0, 1);   % 瓶颈分支 / 联络线
cut_zone_cell = cell(0, 1);             % 区域节点集合 (Type-2)

%% §6.6  Dinkelbach 迭代初始化
lambda_dink   = 0;   % 初始参数（等价于纯最大化 VOLL_saving）

% 解的占位符（若优化彻底失败则使用默认值）
q_mat   = logical(1 - p_feeder_d);
L_res   = zeros(nL, nScen);
Pf_res  = zeros(nB_all, nScen);
Qf_res  = zeros(nB_all, nScen);
Vm_res  = repmat(V_src_sq, num_nodes, nScen);
Sw_res  = zeros(nB_all, nScen);
obj_best_frac = -Inf;
VOLL_saving_best = 0;

%% §6.7  主循环: Dinkelbach × 割平面
for dink_iter = 1:DINK_MAX_ITER

    fprintf('\n   ═══ Dinkelbach 迭代 %d (λ=%.6f) ═══\n', dink_iter, lambda_dink);

    % ── 清除上一轮 YALMIP 变量，防止内部注册表膨胀 ──
    yalmip('clear');

    % ── 创建 LP 松弛变量（sdpvar，对应 Python MC_Conv-C 连续松弛）──
    S_lp  = sdpvar(nB_all,  nScen, 'full');
    Q_lp  = sdpvar(nL,      nScen, 'full');
    Pf_lp = sdpvar(nB_all,  nScen, 'full');
    Qf_lp = sdpvar(nB_all,  nScen, 'full');
    V_lp  = sdpvar(num_nodes, nScen, 'full');
    Ev_lp = sdpvar(nB_all,  nScen, 'full');
    ZZ_lp = sdpvar(total_ZZ, nScen, 'full');
    L_lp  = sdpvar(nL,      nScen, 'full');

    delt_lp  = BdV*V_lp + 2*(Dr*Pf_lp + Dx*Qf_lp);
    Lshd_lp  = SEL_s * ZZ_lp;
    sw_cnt_lp= sum(sum(S_NO_mat.*(1-S_lp) + (1-S_NO_mat).*S_lp));

    % 基础约束集（LP 松弛版，S/Q/ZZ ∈ [0,1]）
    C_base_lp = [...
        0<=S_lp<=1, 0<=Q_lp<=1, 0<=ZZ_lp<=1,...
        V_lp(subs_idx,:) == V_src_sq,...
        V_lp(non_sub,:)  >= V_lower_sq - M_vn*(1-Q_lp),...
        V_lp(non_sub,:)  <= V_upper_sq + M_vn*(1-Q_lp),...
        -Cap*S_lp <= Pf_lp <= Cap*S_lp,...
        -Cap*S_lp <= Qf_lp <= Cap*S_lp,...
        A_free_all*Pf_lp == Dp*Q_lp - L_lp,...
        A_free_all*Qf_lp == Dq_m*Q_lp - TAN_PHI*L_lp,...
        Ev_lp >= 0,...
        delt_lp <= M_V*(1-S_lp) + Ev_lp,...
        delt_lp >= -M_V*(1-S_lp) - Ev_lp,...
        sum(S_lp,1) == sum(Q_lp,1),...
        S_lp(fault_lin_idx) == 0,...
        Q_lp >= 1 - p_feeder_d,...
        L_lp(shed_nodes_idx,:) == Lshd_lp,...
        ONESUM_s*ZZ_lp == 1,...
        L_lp >= 0, L_lp <= P_max_mat .* Q_lp];
    if any(~can_shed)
        C_base_lp = [C_base_lp, L_lp(~can_shed,:) == 0];
    end

    % 当前 Dinkelbach 线性目标（YALMIP 最小化负目标）
    % max VOLL_saving - λ·switch_cost
    % = max Σ_{k,s} [c_Q(k,s)·Q(k,s) + c_L(k,s)·L(k,s)] - λ·GAMMA·Σ sw_changes
    obj_lp_min = -(sum(sum(Q_obj_coef .* Q_lp)) ...
                 + sum(sum(L_obj_coef .* L_lp)) ...
                 - lambda_dink * GAMMA_SWITCH * sw_cnt_lp);

    % ── 从已有索引重建割平面约束（LP 变量版）──
    C_dyn_lp = [];
    for ci = 1:length(cut_type_arr)
        k_ci = cut_k_arr(ci); s_ci = cut_s_arr(ci); b_ci = cut_b_arr(ci);
        if cut_type_arr(ci) == 1
            % Type-1: Q(k,s) ≤ S(b,s)  — 路径连通性
            C_dyn_lp = [C_dyn_lp, Q_lp(k_ci,s_ci) <= S_lp(b_ci,s_ci)]; %#ok<AGROW>
        else
            % Type-2: Σ Q(zone,s) ≤ n_zone·S(t,s)  — 区域容量
            z = cut_zone_cell{ci};
            nz = length(z);
            C_dyn_lp = [C_dyn_lp, sum(Q_lp(z,s_ci)) <= nz * S_lp(b_ci,s_ci)]; %#ok<AGROW>
        end
    end

    % ──────────────────────────────────────────────────────────
    %  割平面循环 (K 轮)
    %  对应 Python RUN_WITH_SETTING() 中的 cut_round_limit 循环
    %  以及 run_callback.py 中 MIPNODE 回调内的割平面添加逻辑
    % ──────────────────────────────────────────────────────────
    for cut_round = 0:CUT_ROUND_LIMIT

        % 求解当前 LP 松弛
        sol_lp = optimize([C_base_lp; C_dyn_lp], obj_lp_min, opts_lp);

        if sol_lp.problem ~= 0
            fprintf('     [D%d/R%d] LP松弛失败: %s\n', dink_iter, cut_round, sol_lp.info);
            break;
        end
        Qh = value(Q_lp);
        Sh = value(S_lp);
        if any(isnan(Qh(:)))
            fprintf('     [D%d/R%d] LP解含NaN，跳过\n', dink_iter, cut_round);
            break;
        end

        if cut_round == CUT_ROUND_LIMIT
            break;   % 最后一轮：只求解 LP，不再添加割平面
        end

        % ── separate_oracle（适应版，对应 Python ToolFunctions.separate()）──
        %
        %  Python separate(i, xi, y0, y, u0, u) 的核心逻辑:
        %    S_star = argmax_{j≠i} y[j] ≥ y[i]   → 确定 B_less 凸包面
        %    T_star = argmax_{j≠i} y[j] ≥ y0-y[i] → 确定 B_greater 凸包面
        %    检验 (xi,y0,y) 是否满足对应不等式
        %
        %  可靠性适应版:
        %    xi  → Q_hat(k,s)   (节点恢复的 LP 松弛解)
        %    y0  → 1 (归一化)
        %    y[b]→ S_hat(b,s)   (开关状态的 LP 松弛解)
        %    u0,u→ 网络容量参数
        %
        %  Type-1 对应 B_less:  xi ≤ y[b] ← 路径瓶颈约束
        %  Type-2 对应 B_greater: Σxi ≤ n·y[t] ← 区域容量约束
        n_t1 = 0; n_t2 = 0;

        for s = 1:nScen
            Qs   = Qh(:,s);
            Ss   = Sh(:,s);
            aff  = find(p_mat_d(:,s) > 0.5);
            if isempty(aff), continue; end

            % ─ Type-1: 路径连通性割平面（对应 Python B_less 类型）─
            %  若节点 k 的恢复量 Q_hat(k,s) 超过其恢复路径上某分支的
            %  开关概率 S_hat(b,s)，则违反凸包约束。
            %  割平面: Q(k,s) ≤ S(b,s)
            for ki = 1:length(aff)
                k = aff(ki);
                if Qs(k) < SEP_TOL, continue; end
                pb = path_branches_cell{k,s};
                violated_b = -1;
                for bi = 1:length(pb)
                    b = pb(bi);
                    if Qs(k) > Ss(b) + SEP_TOL
                        violated_b = b; break;
                    end
                end
                if violated_b < 0, continue; end

                % 记录割平面索引
                cut_type_arr(end+1,1) = int32(1);
                cut_k_arr(end+1,1)    = int32(k);
                cut_s_arr(end+1,1)    = int32(s);
                cut_b_arr(end+1,1)    = int32(violated_b);
                cut_zone_cell{end+1,1}= [];
                % 向 LP 动态约束中添加
                C_dyn_lp = [C_dyn_lp, Q_lp(k,s) <= S_lp(violated_b,s)]; %#ok<AGROW>
                n_t1 = n_t1 + 1;
            end

            % ─ Type-2: 区域容量割平面（对应 Python B_greater 类型）─
            %  若某故障场景下受影响节点的 LP 恢复量之和超过任意联络线
            %  所能提供的最大转供量，则违反凸包约束。
            %  割平面: Σ_{k∈Aff} Q(k,s) ≤ |Aff|·S(t,s)
            sum_Qaff = sum(Qs(aff));
            naff = length(aff);
            for ti = 1:length(tie_branch_idx)
                t = tie_branch_idx(ti);
                if sum_Qaff > naff * Ss(t) + SEP_TOL * naff
                    cut_type_arr(end+1,1) = int32(2);
                    cut_k_arr(end+1,1)    = int32(0);
                    cut_s_arr(end+1,1)    = int32(s);
                    cut_b_arr(end+1,1)    = int32(t);
                    cut_zone_cell{end+1,1}= aff;
                    C_dyn_lp = [C_dyn_lp, sum(Q_lp(aff,s)) <= naff * S_lp(t,s)]; %#ok<AGROW>
                    n_t2 = n_t2 + 1;
                    break;   % 每场景每轮至多一个 Type-2 割平面
                end
            end
        end % 场景循环

        n_new = n_t1 + n_t2;
        fprintf('     [D%d/R%d] 新割平面: T1(路径)=%d, T2(容量)=%d (累计=%d)\n',...
            dink_iter, cut_round, n_t1, n_t2, length(cut_type_arr));

        if n_new == 0
            fprintf('     无新违反约束，提前终止割平面循环\n');
            break;
        end

    end % cut_round 循环

    % ──────────────────────────────────────────────────────────
    %  求解整数 MILP（含全部累积割平面）
    %  对应 Python MC_Conv-mo-soc-aC 的最终 MILP 求解阶段
    % ──────────────────────────────────────────────────────────
    fprintf('   [D%d] 求解 MILP (累积割平面=%d)...\n', dink_iter, length(cut_type_arr));
    yalmip('clear');

    % MILP 整数变量
    S_bv  = binvar(nB_all,   nScen, 'full');
    Q_bv  = binvar(nL,       nScen, 'full');
    Pf_bv = sdpvar(nB_all,   nScen, 'full');
    Qf_bv = sdpvar(nB_all,   nScen, 'full');
    V_bv  = sdpvar(num_nodes, nScen, 'full');
    Ev_bv = sdpvar(nB_all,   nScen, 'full');
    ZZ_bv = binvar(total_ZZ, nScen, 'full');
    L_bv  = sdpvar(nL,       nScen, 'full');

    delt_bv  = BdV*V_bv + 2*(Dr*Pf_bv + Dx*Qf_bv);
    Lshd_bv  = SEL_s * ZZ_bv;
    sw_cnt_bv= sum(sum(S_NO_mat.*(1-S_bv) + (1-S_NO_mat).*S_bv));

    C_milp = [...
        V_bv(subs_idx,:) == V_src_sq,...
        V_bv(non_sub,:)  >= V_lower_sq - M_vn*(1-Q_bv),...
        V_bv(non_sub,:)  <= V_upper_sq + M_vn*(1-Q_bv),...
        -Cap*S_bv <= Pf_bv <= Cap*S_bv,...
        -Cap*S_bv <= Qf_bv <= Cap*S_bv,...
        A_free_all*Pf_bv == Dp*Q_bv - L_bv,...
        A_free_all*Qf_bv == Dq_m*Q_bv - TAN_PHI*L_bv,...
        Ev_bv >= 0,...
        delt_bv <= M_V*(1-S_bv) + Ev_bv,...
        delt_bv >= -M_V*(1-S_bv) - Ev_bv,...
        sum(S_bv,1) == sum(Q_bv,1),...
        S_bv(fault_lin_idx) == 0,...
        Q_bv >= 1 - p_feeder_d,...
        L_bv(shed_nodes_idx,:) == Lshd_bv,...
        ONESUM_s*ZZ_bv == 1,...
        L_bv >= 0, L_bv <= P_max_mat .* Q_bv];
    if any(~can_shed)
        C_milp = [C_milp, L_bv(~can_shed,:) == 0];
    end

    % 将积累的割平面索引转化为 MILP 变量约束
    C_cuts_bv = [];
    for ci = 1:length(cut_type_arr)
        k_ci = cut_k_arr(ci); s_ci = cut_s_arr(ci); b_ci = cut_b_arr(ci);
        if cut_type_arr(ci) == 1
            C_cuts_bv = [C_cuts_bv, Q_bv(k_ci,s_ci) <= S_bv(b_ci,s_ci)]; %#ok<AGROW>
        else
            z  = cut_zone_cell{ci};
            nz = length(z);
            C_cuts_bv = [C_cuts_bv, sum(Q_bv(z,s_ci)) <= nz * S_bv(b_ci,s_ci)]; %#ok<AGROW>
        end
    end

    % Dinkelbach 线性目标（MILP 版本）
    obj_milp_min = -(sum(sum(Q_obj_coef .* Q_bv)) ...
                  +  sum(sum(L_obj_coef .* L_bv)) ...
                  -  lambda_dink * GAMMA_SWITCH * sw_cnt_bv);

    sol_m = optimize([C_milp; C_cuts_bv], obj_milp_min, opts_milp);

    if sol_m.problem == 0 && ~any(isnan(double(Q_bv(:))))
        Qv  = round(value(Q_bv));
        Sv  = round(value(S_bv));
        Lv  = max(value(L_bv), 0);
        Pfv = value(Pf_bv);
        Qfv = value(Qf_bv);
        Vmv = sqrt(max(value(V_bv), 0));
    else
        fprintf('   [警告] MILP求解失败 (D%d): %s\n', dink_iter, sol_m.info);
        break;
    end

    % ── 计算当前迭代的真实分式目标值 ──
    %  对应 Python 中 InfoReport 记录 ObjVal 的逻辑
    CID_tie_v  = (p_mat_d .* double(Qv))   * (TAU_TIE_SW .* lam_vec);
    CID_rep_v  = (p_mat_d .* double(1-Qv)) * (lam_vec .* trp_vec);
    L_ratio_v  = Lv ./ repmat(P_free_safe, 1, nScen);
    CID_shed_v = (L_ratio_v .* p_mat_d)    * (lam_vec .* max(trp_vec-TAU_TIE_SW, 0));
    CID_v      = CID_up_const + CID_tie_v + CID_rep_v + CID_shed_v;

    VOLL_loss_R2_v = sum(voll_Pa .* CID_v);
    VOLL_saving_v  = VOLL_loss_R1_val - VOLL_loss_R2_v;
    sw_cost_v      = GAMMA_SWITCH * sum(sum(abs(double(Sv) - S_NO_mat)));
    obj_frac_v     = VOLL_saving_v / (sw_cost_v + 1e-4);

    % Dinkelbach 间隙: |f(x) - λ·g(x)| （收敛判据）
    dink_gap = abs(VOLL_saving_v - lambda_dink * (sw_cost_v + 1e-4));

    fprintf('   [D%d] VOLL_saving=%.2f元/年, sw_cost=%.2f, 分式目标=%.4f, Dink_gap=%.2e\n',...
        dink_iter, VOLL_saving_v, sw_cost_v, obj_frac_v, dink_gap);

    % 保留历次迭代中分式目标值最高的解（最优解保证）
    if obj_frac_v > obj_best_frac
        obj_best_frac    = obj_frac_v;
        VOLL_saving_best = VOLL_saving_v;
        q_mat   = logical(Qv);
        L_res   = Lv;
        Pf_res  = Pfv;
        Qf_res  = Qfv;
        Vm_res  = Vmv;
        Sw_res  = Sv;
    end

    % 收敛性检验（Dinkelbach 定理：间隙→0 时达到全局最优）
    if dink_gap < DINK_TOL
        fprintf('   ✓ Dinkelbach 已收敛 (iter=%d, gap=%.2e < tol=%.1e)\n',...
            dink_iter, dink_gap, DINK_TOL);
        break;
    end

    % 更新 Dinkelbach 参数 λ = f(x*)/g(x*)
    lambda_dink = VOLL_saving_v / (sw_cost_v + 1e-4);

end % Dinkelbach 主循环

%% §6.8  后处理（与原§6后处理对齐，向§7提供所需变量）
yalmip('clear');

q_mat_d         = double(q_mat);
p_direct_d      = p_mat_d;
p_feeder_d_full = p_feeder_d;
SHED_THRESH     = 1e-4;
P_free_mat      = repmat(P_free, 1, nScen);

n_full  = full(sum(q_mat_d(:)>0.5 & L_res(:)<=SHED_THRESH & p_direct_d(:)>0.5));
n_part  = full(sum(q_mat_d(:)>0.5 & L_res(:)>SHED_THRESH  & p_direct_d(:)>0.5));
n_unrec = full(sum(q_mat_d(:)<0.5 & p_direct_d(:)>0.5));
n_aff   = full(sum(p_direct_d(:)>0));
aff_power = full(sum(sum(P_free_mat .* p_direct_d)));
net_rec   = full(sum(sum((P_free_mat - L_res) .* q_mat_d .* p_direct_d)));
rec_pct   = net_rec / max(aff_power, 1e-9) * 100;
total_shed= full(sum(sum(L_res .* q_mat_d .* p_direct_d)));
mask_L1 = false(nL,1); mask_L1(idx_L1)=true;
mask_L2 = false(nL,1); mask_L2(idx_L2)=true;
mask_L3 = false(nL,1); mask_L3(idx_L3)=true;
shed_lev = [sum(sum(L_res(mask_L1,:).*q_mat_d(mask_L1,:))),...
            sum(sum(L_res(mask_L2,:).*q_mat_d(mask_L2,:))),...
            sum(sum(L_res(mask_L3,:).*q_mat_d(mask_L3,:)))];
t_milp_elapsed = toc(t_milp);

fprintf('\n   IP+割平面+凸包求解完成 (%.1fs)\n', t_milp_elapsed);
fprintf('   最优分式目标: %.4f  (VOLL_saving=%.2f 元/年)\n', obj_best_frac, VOLL_saving_best);
fprintf('   割平面统计: 总数=%d (T1路径=%d, T2容量=%d)\n',...
    length(cut_type_arr), sum(cut_type_arr==1), sum(cut_type_arr==2));
fprintf('   恢复: 完全=%d, 部分=%d, 未恢复=%d / 受影响=%d, 功率基=%.1f%%\n',...
    n_full, n_part, n_unrec, n_aff, rec_pct);

%% §7  可靠性指标
fprintf('>> [7/8] 计算可靠性指标...\n');
lam=rel_branches(:,3); trp=rel_branches(:,4);
p_upstream_d=p_feeder_d_full-p_direct_d;
[~,c_row]=ismember(inv_map(load_nodes),t_cust.Node);
NC_r=zeros(nL,1); NC_r(c_row>0)=t_cust.NC(c_row(c_row>0));
total_cust=sum(NC_r);
P_free_safe2=max(P_free,1e-9);
shed_ratio=(L_res./repmat(P_free_safe2,1,nScen)).*q_mat_d.*p_direct_d;

CIF=p_feeder_d_full*lam;
CID_up=TAU_UP_SW*(p_upstream_d*lam);
CID_tie=TAU_TIE_SW*(p_direct_d.*q_mat_d)*lam;
CID_rep=(p_direct_d.*(1-q_mat_d))*(lam.*trp);
CID_shed=(shed_ratio.*p_direct_d.*q_mat_d)*(lam.*(trp-TAU_TIE_SW));
CID=CID_up+CID_tie+CID_rep+CID_shed;

SAIFI=(NC_r'*CIF)/total_cust; SAIDI=(NC_r'*CID)/total_cust;
EENS=(P_avg'*CID)/1e3; ASAI=1-SAIDI/8760;
SAIDI_up=(NC_r'*CID_up)/total_cust; SAIDI_tie=(NC_r'*CID_tie)/total_cust;
SAIDI_rep=(NC_r'*CID_rep)/total_cust; SAIDI_shed=(NC_r'*CID_shed)/total_cust;

CID_R1=TAU_UP_SW*(p_upstream_d*lam)+p_direct_d*(lam.*trp);
SAIDI_R1=(NC_r'*CID_R1)/total_cust; EENS_R1=(P_avg'*CID_R1)/1e3; ASAI_R1=1-SAIDI_R1/8760;

VOLL_loss_R2=sum(voll_vec.*P_avg.*CID);
VOLL_loss_R1=sum(voll_vec.*P_avg.*CID_R1);
VOLL_saving=VOLL_loss_R1-VOLL_loss_R2;

%% §8  结果输出
total_elapsed=toc(program_total);
fprintf('\n╔══════════════════════════════════════════╗\n');
fprintf('  系统: %-39s\n',sys_filename);
fprintf('  [Q1]负荷分级(累积%.0f%%/%.0f%%/其余): L1=%d, L2=%d, L3=%d\n',...
    RATIO_L1*100,RATIO_L2*100,nL1,nL2,nL3);
fprintf('  [§6]算法: IP+割平面+凸包 (Dinkelbach)✓\n');
fprintf('  [Q4]目标函数: VOLL_saving/Cost 分式形式✓\n');
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  [R2 含重构+VOLL切负荷]                   ║\n');
fprintf('║  SAIFI : %10.4f  次/(户·年)         ║\n',SAIFI);
fprintf('║  SAIDI : %10.4f  h/(户·年)          ║\n',SAIDI);
fprintf('║    ①上游开关  : %+8.4f h/(户·年)     \n',SAIDI_up);
fprintf('║    ②联络转供  : %+8.4f h/(户·年)     \n',SAIDI_tie);
fprintf('║    ③等待修复  : %+8.4f h/(户·年)     \n',SAIDI_rep);
fprintf('║    ④切负荷等待: %+8.4f h/(户·年)     \n',SAIDI_shed);
fprintf('║  EENS  : %10.2f  MWh/年             ║\n',EENS);
fprintf('║  ASAI  : %12.6f                   ║\n',ASAI);
fprintf('║  VOLL年损失: %10.2f 万元/年         ║\n',VOLL_loss_R2/1e4);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  [R1 不含重构]  SAIDI=%8.4f  EENS=%8.2f ║\n',SAIDI_R1,EENS_R1);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  SAIDI改善: %+10.4f h/(户·年)              \n',SAIDI_R1-SAIDI);
fprintf('║  EENS改善 : %+10.2f MWh/年                \n',EENS_R1-EENS);
fprintf('║  VOLL节约 : %+10.2f 万元/年                \n',VOLL_saving/1e4);
fprintf('║  功率基恢复率: %.1f%%(完全%d/部分%d/未%d)   \n',rec_pct,n_full,n_part,n_unrec);
fprintf('║  切负荷(L1/L2/L3): %.4f/%.4f/%.4f pu·场景 \n',shed_lev);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  分式目标最优值: %10.4f               \n', obj_best_frac);
fprintf('║  Dinkelbach割平面: T1=%d T2=%d 共%d   \n',...
    sum(cut_type_arr==1), sum(cut_type_arr==2), length(cut_type_arr));
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  §5 MCF : %7.1f 秒                    \n',t_mcf_elapsed);
fprintf('║  §6 优化: %7.1f 秒 (ZZ=%d档位)       \n',t_milp_elapsed,total_ZZ);
fprintf('║  总耗时 : %7.1f 秒                    \n',total_elapsed);
fprintf('╚══════════════════════════════════════════╝\n');

[~,rep_xy]=max(sum(p_direct_d,1));
fprintf('\n══ 代表性故障场景 %d（分支%d─%d）══\n',rep_xy,...
    inv_map(rel_branches(rep_xy,1)),inv_map(rel_branches(rep_xy,2)));
Vm_rep=Vm_res(:,rep_xy); Pf_rep=Pf_res(:,rep_xy); Qf_rep=Qf_res(:,rep_xy);
Sw_rep=Sw_res(:,rep_xy); qv_rep=q_mat(:,rep_xy);
pf_rep=full(p_feeder_d_full(:,rep_xy)); L_rep=L_res(:,rep_xy);

shed_rep=find(L_rep>SHED_THRESH&qv_rep);
if ~isempty(shed_rep)
    fprintf('\n  切负荷节点（低压分支开关操作）\n');
    fprintf('  %-8s %-4s %-5s %-8s %-10s %-10s %-8s\n','节点','级','n_br','VOLL','P/kW','L/kW','切除比');
    fprintf('  %s\n',repmat('─',1,58));
    for k=shed_rep'
        lvl=ternary(mask_L1(k),'L1',ternary(mask_L2(k),'L2','L3'));
        fprintf('  %-8d %-4s %-5d %-8.0f %-10.2f %-10.2f %-8.1f%%\n', ...
            inv_map(load_nodes(k)),lvl,n_br_vec(k),voll_vec(k)*1e3,...
            P_free(k)*1e3,L_rep(k)*1e3,L_rep(k)/P_free_safe2(k)*100);
    end
end

fprintf('\n  节点电压（pu）\n  %-8s %-10s %-4s %-16s\n','节点','V/pu','级','状态');
fprintf('  %s\n',repmat('─',1,42));
for si=1:length(subs_idx)
    fprintf('  %-8d %-10.4f %-4s 变电站\n',inv_map(subs_idx(si)),Vm_rep(subs_idx(si)),'─');
end
for k=1:nL
    if qv_rep(k)
        lvl=ternary(mask_L1(k),'L1',ternary(mask_L2(k),'L2','L3'));
        if pf_rep(k)>0&&L_rep(k)>SHED_THRESH; st=sprintf('转供(切%.1f%%)',L_rep(k)/P_free_safe2(k)*100);
        elseif pf_rep(k)>0; st='转供恢复'; else; st='正常供电'; end
        fprintf('  %-8d %-10.4f %-4s %s\n',inv_map(load_nodes(k)),Vm_rep(load_nodes(k)),lvl,st);
    end
end
n_dark=sum(~qv_rep&pf_rep>0);
if n_dark>0, fprintf('  （%d受影响节点未恢复略去）\n',n_dark); end

fprintf('\n  合路分支潮流（kW/kVar）\n  %-6s %-6s %-6s %-12s %-12s %-8s\n',...
    '分支#','From','To','P/kW','Q/kVar','类型');
fprintf('  %s\n',repmat('─',1,58));
P_total=0; Q_total=0;
for b=1:nB_all
    if Sw_rep(b)==1
        if ismember(all_branches(b,1),subs_idx); P_total=P_total+Pf_rep(b); Q_total=Q_total+Qf_rep(b);
        elseif ismember(all_branches(b,2),subs_idx); P_total=P_total-Pf_rep(b); Q_total=Q_total-Qf_rep(b); end
    end
end
fprintf('\n  汇总: 受影响=%d 恢复=%d 未=%d 切负荷=%.2fkW\n',sum(pf_rep),sum(qv_rep&pf_rep>0),sum(~qv_rep&pf_rep>0),sum(L_rep(qv_rep))*1e3);
fprintf('  变电站: P=%.2fkW Q=%.2fkVar\n',P_total*1e3,Q_total*1e3);

% ============ 输出混合算法统计 ============
fprintf('\n═══ IP+Cutting Plane+Convex Hull 算法统计 ═══\n');
fprintf('  总迭代次数: %d\n', cut_iter);
fprintf('  总切平面条数: %d\n', cut_count);
fprintf('  平均每次迭代切平面: %.2f 条\n', cut_count / max(cut_iter, 1));
fprintf('  最终目标函数值: %.6f\n', obj_hist(end));
if length(obj_hist) > 1
    fprintf('  目标函数改善: %.2f%%\n', (obj_hist(end) - obj_hist(1)) / (abs(obj_hist(1)) + 1e-9) * 100);
end
fprintf('════════════════════════════════════\n');

function out=ternary(cond,a,b)
    if cond; out=a; else; out=b; end
end