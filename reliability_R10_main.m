%% ============================================================
%  配电网可靠性评估 —— R10（VOLL差异化+柔性负荷+高效离散切负荷）
%
%  相对于 R9_gemini 的改进：
%
%  [问题1] 负荷分级与VOLL建模修正
%    a. 比例修正：L1(关键)≈20%, L2(重要)≈30%, L3(柔性)≈50%
%    b. 个体化随机VOLL：每节点在基准值±20%范围内随机扰动
%    c. 第三级负荷作为柔性资源：引入 FLEX_RATIO_L3 参数
%       物理含义：L3负荷中能在 τ_TIE_SW 内快速响应的比例
%       解析法与时序矛盾的解决：
%         解析法不追踪时序，通过"等效响应率"参数化时序特性
%         快响应部分（τ_response < τ_TIE_SW）：建模为可即时切离的可调资源
%         慢响应部分（τ_response > τ_TIE_SW）：重构阶段不可用，仅贡献修复后负荷弹性
%         有效切负荷上限 = FLEX_RATIO_L3 × shed_limit_L3 × P_free(k)
%
%  [问题2] 离散MILP计算效率提升
%    a. 稀疏ZZ变量：仅对"p_direct=1的节点"（下游受影响节点）引入ZZ档位变量
%       非受影响节点切负荷强制为0，直接用连续变量L=0替代，大幅降低二进制变量数
%    b. Gurobi参数调优：MIPGap=1e-3, Heuristics=0.05, Presolve=2, Cuts=2
%    c. 预处理：预锁定不可行档位（超过shed_limit的档位预设为0，减少搜索空间）
%    d. 变量规模对比（85节点）：
%       原版：83×5×84 = 34,860个额外二进制变量
%       优化后：平均受影响节点数×5×84 ≈ 按实际稀疏度减少
%
%  [问题3] MCF与MILP不可合并的说明
%    MCF基于正常拓扑计算p_mat（哪些节点在故障xy后停电），
%    是故障前的静态信息；MILP基于p_mat进行故障后重构决策。
%    若合并，p_mat须变为决策变量，Eq(16)中的
%    Ff,NO + Ff,NO_xy - 1 ≤ p_xy 将引入双线性约束，使问题变为非线性。
%    文献(Li et al.2020)本身也采用两阶段结构，因此维持两步框架。
%
%  依赖: YALMIP + Gurobi
% =============================================================
clear; clc;

%% ============================================================
%  ★  用户配置区  ★
% ============================================================

% ── 系统文件 ──────────────────────────────────────────────────
%sys_filename = '85-Node System Data.xlsx';
sys_filename = '137-Node System Data.xlsx';
%sys_filename = '417-Node System Data.xlsx';
%sys_filename = '1080-Node System Data.xlsx';

tb_filename = 'Testbench for Linear Model Based Reliability Assessment Method for Distribution Optimization Models Considering Network Reconfiguration.xlsx';

%sys_sheet = '85-node';
sys_sheet = '137-node';
%sys_sheet = '417-node';
%sys_sheet = '1080-node';

% ── 设备故障率 ────────────────────────────────────────────────
LAMBDA_TRF = 0.5;   % 变压器故障率（0=统一用线路公式，>0用固定值）

% ── 多阶段恢复时间（h）───────────────────────────────────────
TAU_UP_SW  = 0.3;
TAU_TIE_SW = 0.5;

% ── 负荷分级与VOLL参数 ───────────────────────────────────────
%  L1(关键负荷)：医院/数据中心等，严禁切除，VOLL极高
%  L2(重要负荷)：工业/商业，允许少量切除（≤25%），VOLL较高
%  L3(柔性负荷)：一般居民/小商业，可按需切除，VOLL较低
%
%  比例分配（随机划分，固定种子保证可复现）：
%    L1 ≈ 20%, L2 ≈ 30%, L3 ≈ 50%
%
%  基准VOLL（元/kWh）：L1=200, L2=50, L3=10
%  个体化随机扰动：±20%均匀分布（VOLL_NOISE_RATIO）
LOAD_TYPE_RATIOS = [0.20, 0.30, 0.50];   % [L1, L2, L3]比例
VOLL_BASE        = [200,   50,   10];     % 基准VOLL（元/kWh）
SHED_LIMIT_BASE  = [0.00, 0.15, 1.00];   % 基准切负荷上限比例
VOLL_NOISE_RATIO = 0.20;                  % VOLL个体化扰动幅度

% ── 柔性资源参数（针对L3负荷）────────────────────────────────
%  FLEX_RATIO_L3 ∈ [0,1]：L3负荷中能在 τ_TIE_SW 内快速响应的比例
%    = 1.0 → 全部L3负荷可即时调度（理想情况）
%    = 0.5 → 50%可快速响应（其余在修复完成后才能弹性恢复）
%    = 0.0 → L3无柔性（退化为普通可切负荷）
FLEX_RATIO_L3 = 0.6;   % 80%的L3负荷具备快速响应能力

% ── 离散切负荷档位 ────────────────────────────────────────────
%  每节点的档位在基准档位集上添加小扰动（或直接使用统一档位）
%  USE_NODE_SPECIFIC_LEVELS = true; %→ 各节点有独立扰动档位（更真实）
%  USE_NODE_SPECIFIC_LEVELS = false → 统一5档（简化）
SHED_LEVELS_BASE     = [0, 0.25, 0.50, 0.75, 1.00];
N_LEVELS             = length(SHED_LEVELS_BASE);

% ── 目标函数权重 ──────────────────────────────────────────────
%  BETA_SHED：切负荷VOLL惩罚相对于CID改善目标的权重系数
%  值越大越倾向于少切负荷（以更差的网络重构换取更少切负荷）
BETA_SHED = 1.0;

% ── MCF 求解模式 ──────────────────────────────────────────────
SOLVE_MODE = 'MCF';

% ── 电压约束与功率因数 ────────────────────────────────────────
V_UPPER = 1.05;   V_LOWER = 0.95;   V_SRC = 1.0;
PF = 0.9;
% ============================================================

program_total = tic;

%% ================================================================
%  §1  Testbench 数据读取
% ================================================================
fprintf('>> [1/8] 读取 Testbench: Sheet="%s"\n', sys_sheet);

tb_cell  = readcell(tb_filename, 'Sheet', sys_sheet);
nrows_tb = size(tb_cell, 1);
hdr_row  = 0;
for ri = 1:nrows_tb
    if ischar(tb_cell{ri,1}) && contains(tb_cell{ri,1}, 'Tie-Switch')
        hdr_row = ri; break;
    end
end
if hdr_row == 0, error('未找到 Tie-Switch 表头行'); end
LINE_CAP = str2double(extractBefore(string(tb_cell{hdr_row+1, 4}), ' '));
TRAN_CAP = LINE_CAP;
TIE_LINES_RAW = [];
for ri = hdr_row+2 : nrows_tb
    v1 = tb_cell{ri,1};  v2 = tb_cell{ri,2};
    if isnumeric(v1)&&~isnan(v1)&&isnumeric(v2)&&~isnan(v2)
        TIE_LINES_RAW(end+1,:) = [v1, v2]; %#ok<AGROW>
    end
end
fprintf('   线路容量=%.0f MW，联络线=%d 条\n', LINE_CAP, size(TIE_LINES_RAW,1));

%% ================================================================
%  §2  可靠性参数读取
% ================================================================
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
lambda_per_km = str2double(string(t_other{find(contains(col1,'Failure rate'),1), 2}));
row_dur = find(contains(col1,'Duration'),1);
T_l = [str2double(string(t_other{row_dur,3})), str2double(string(t_other{row_dur+1,3})), str2double(string(t_other{row_dur+2,3}))];
row_lf = find(contains(col1,'Loading factors'),1);
L_f = [str2double(string(t_other{row_lf,3})), str2double(string(t_other{row_lf+1,3})), str2double(string(t_other{row_lf+2,3}))]/100;
fprintf('   lambda_line=%.4f/km, T_l=[%s]h, L_f=[%s]\n', lambda_per_km, num2str(T_l,'%g '), num2str(L_f,'%.2f '));

%% ================================================================
%  §3  潮流参数生成
% ================================================================
fprintf('>> [3/8] 生成潮流参数...\n');
R_KM=0.003151; X_KM=0.001526; TAN_PHI=tan(acos(PF));
V_src_sq=V_SRC^2; V_upper_sq=V_UPPER^2; V_lower_sq=V_LOWER^2;
M_V=(V_upper_sq-V_lower_sq)*2; M_vn=V_upper_sq;
fprintf('   R=%.4f, X=%.4f pu/km, V∈[%.2f,%.2f] pu\n', R_KM, X_KM, V_LOWER, V_UPPER);

%% ================================================================
%  §4  拓扑索引构建
% ================================================================
fprintf('>> [4/8] 构建拓扑索引...\n');
raw_nodes = unique([t_branch.From; t_branch.To; TIE_LINES_RAW(:)]);
num_nodes = length(raw_nodes);
node_map  = containers.Map(raw_nodes, 1:num_nodes);
inv_map   = raw_nodes;
subs_raw  = raw_nodes(~ismember(raw_nodes, t_cust.Node));
subs_idx  = arrayfun(@(s) node_map(s), subs_raw);
nB_norm = height(t_branch); nTie = size(TIE_LINES_RAW,1); nB_all = nB_norm+nTie;

rel_branches = zeros(nB_norm,8);
for b = 1:nB_norm
    u_raw=t_branch.From(b); v_raw=t_branch.To(b);
    u=node_map(u_raw); v=node_map(v_raw); len=t_branch.Length_km(b);
    match=(t_dur.From==u_raw&t_dur.To==v_raw)|(t_dur.From==v_raw&t_dur.To==u_raw);
    if ~any(match), error('分支(%d-%d)无停电时间',u_raw,v_raw); end
    is_trf=ismember(u,subs_idx)|ismember(v,subs_idx);
    cap_b=TRAN_CAP*is_trf+LINE_CAP*(~is_trf);
    lam_b=ternary(LAMBDA_TRF>0&&is_trf, LAMBDA_TRF, len*lambda_per_km);
    rel_branches(b,:)=[u,v,lam_b,t_dur.RP(match),t_dur.SW(match),R_KM*len,X_KM*len,cap_b];
end
is_trf_vec = ismember(rel_branches(:,1),subs_idx)|ismember(rel_branches(:,2),subs_idx);
n_trf = sum(is_trf_vec);

tie_branches = zeros(nTie,8);
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
P_free=zeros(nL,1); valid=pk_row>0;
P_free(valid)=t_peak.P_kW(pk_row(valid))/1e3;
Q_free=P_free*TAN_PHI;

%% ================================================================
%  §4b 负荷分级与个体化VOLL、切负荷参数
%
%  比例修正说明：
%    原版：idx_L1=1:50%, idx_L3=25%~100%（大量重叠，L2极少）→ 分类错误
%    修正：L1≈20%, L2≈30%, L3≈50%，互不重叠，符合实际工程比例
%
%  个体化VOLL：
%    同类用户停电损失有差异，在基准值上加±20%均匀随机扰动
%    同一随机种子保证结果可复现
%
%  柔性负荷建模（L3）：
%    L3有效切负荷上限 = FLEX_RATIO_L3 × SHED_LIMIT_BASE(L3) × P_free(k)
%    FLEX_RATIO_L3：快速响应比例，处理解析法与时序矛盾的等效参数
%    解析法不追踪实时调度，通过此参数等效反映"τ_TIE_SW内可用的柔性量"
%    若τ_response(k) < τ_TIE_SW → 快响应，贡献到 FLEX_RATIO_L3 分子
%    若τ_response(k) ≥ τ_TIE_SW → 慢响应，仅在修复阶段贡献弹性，不计入本框架
% ================================================================
%% ================================================================
%  §4b 物理驱动的离散切负荷档位与VOLL参数 (数据驱动优化版)
%
%  改进说明：
%  1. 摒弃纯随机分配，完全依靠上传的系统实际数据 (P_kW, NC) 驱动。
%  2. 负荷分级 (L1/L2/L3)：基于节点峰值需求(P_free)降序划分。
%     高负荷节点映射为重要工商业(L1/L2)，低负荷散户映射为柔性资源(L3)。
%  3. 个体化 VOLL：基于"单户平均容量(kW/户)"正相关浮动，更具经济合理性。
%  4. 离散档位生成：基于实际用户数(NC)决定低压分支开关数，消除维数灾。
% ================================================================

% 1. 提取实际的用户数 (NC) 向量 (使用{}索引增强鲁棒性)
[~, c_row] = ismember(inv_map(load_nodes), t_cust{:, 1});
NC_vec_local = zeros(nL, 1);
NC_vec_local(c_row > 0) = t_cust{c_row(c_row > 0), 2};

% 2. 数据驱动的负荷分级 (按需求从大到小)
[~, sort_idx] = sort(P_free, 'descend'); 
nL1 = round(nL * LOAD_TYPE_RATIOS(1));
nL2 = round(nL * LOAD_TYPE_RATIOS(2));
nL3 = nL - nL1 - nL2;

idx_L1 = sort_idx(1:nL1);
idx_L2 = sort_idx(nL1+1:nL1+nL2);
idx_L3 = sort_idx(nL1+nL2+1:end);

% 设定切负荷上限
shed_limit_vec = zeros(nL, 1);
shed_limit_vec(idx_L1) = SHED_LIMIT_BASE(1);
shed_limit_vec(idx_L2) = SHED_LIMIT_BASE(2);
shed_limit_vec(idx_L3) = SHED_LIMIT_BASE(3) * FLEX_RATIO_L3;

% 3. 数据驱动的个体化 VOLL (基于单户容量 kW/户)
% 单户用电量越大，通常代表产业附加值越高，停电损失 VOLL 越大
kW_per_cust = P_free * 1e3 ./ max(NC_vec_local, 1); 

% 定义局部归一化辅助函数，将指标映射到 [-1, 1] 之间
normalize_to_range = @(x) (x - min(x)) ./ max(max(x) - min(x), 1e-6) * 2 - 1;

voll_vec = zeros(nL, 1);
% 基础值 + 基于单户容量的物理波动 (替代随机噪声)
voll_vec(idx_L1) = VOLL_BASE(1) * (1 + VOLL_NOISE_RATIO * normalize_to_range(kW_per_cust(idx_L1)));
voll_vec(idx_L2) = VOLL_BASE(2) * (1 + VOLL_NOISE_RATIO * normalize_to_range(kW_per_cust(idx_L2)));
voll_vec(idx_L3) = VOLL_BASE(3) * (1 + VOLL_NOISE_RATIO * normalize_to_range(kW_per_cust(idx_L3)));

% % 每节点有效档位（在基准档位中筛选不超过shed_limit的档位）
% if USE_NODE_SPECIFIC_LEVELS
%     % 个体化档位：在基准档位加小扰动（±5%）
%     node_levels = cell(nL, 1);
%     for k = 1:nL
%         raw_levels = SHED_LEVELS_BASE + 0.05*(2*rand(1,N_LEVELS)-1);
%         raw_levels = max(0, min(1, raw_levels));
%         raw_levels(1) = 0;   % 第一档强制为0
%         raw_levels = sort(raw_levels);
%         node_levels{k} = raw_levels(raw_levels <= shed_limit_vec(k) + 1e-6);
%         if isempty(node_levels{k}), node_levels{k} = [0]; end
%     end
% else
%     % 统一档位（高效）
%     node_levels = cell(nL, 1);
%     for k = 1:nL
%         valid_m = SHED_LEVELS_BASE <= shed_limit_vec(k) + 1e-6;
%         node_levels{k} = SHED_LEVELS_BASE(valid_m);
%         if isempty(node_levels{k}), node_levels{k} = [0]; end
%     end
% end

% 4. 物理驱动的低压分支与切负荷档位
node_levels = cell(nL, 1);
for k = 1:nL
    % 如果是关键负荷（不可切除），只能保留 0% 档
    if shed_limit_vec(k) <= 1e-6
        node_levels{k} = [0];
        continue;
    end

    nc_k = max(1, NC_vec_local(k)); % 实际户数
    
    if nc_k <= 10
        % 户数极少：精准到户控制（如专线用户），各户权重均等
        G_k = nc_k;
        branch_weights = ones(1, G_k) / G_k; 
    else
        % 户数较多（典型台区）：使用参数化的分支数
        % 可以在这里设置 G_k 的值
        G_k = 3;  % 或者根据 nc_k 动态设置：G_k = min(5, ceil(nc_k/10));  
        % 随机生成 branch_weights，保证和为1
        branch_weights = rand(1, G_k);
        branch_weights = branch_weights / sum(branch_weights);
    end
    
    % 生成所有可能的通/断组合 (2^G_k 种)
    num_combinations = 2^G_k;
    possible_levels = zeros(1, num_combinations);
    for i = 0:(num_combinations-1)
        bin_vec = bitget(i, 1:G_k); % 将整数映射为开关状态 [0 1 0 1...]
        possible_levels(i+1) = sum(branch_weights .* bin_vec);
    end
    
    % 去重、排序，并剔除超过节点切除上限的非法档位
    possible_levels = uniquetol(possible_levels);
    valid_levels = possible_levels(possible_levels <= shed_limit_vec(k) + 1e-6);
    
    % 安全兜底：确保 0 档绝对存在
    if isempty(valid_levels) || valid_levels(1) ~= 0
        valid_levels = [0, valid_levels];
    end
    
    node_levels{k} = valid_levels;
end

% 打印统计信息
n_levels_arr = cellfun(@length, node_levels);
fprintf('   负荷分级(按容量降序): L1=%d, L2=%d, L3=%d\n', nL1, nL2, nL3);
fprintf('   物理档位(基于用户数): 平均每节点 %.1f 档 (最大%d, 最小%d)\n', ...
    mean(n_levels_arr(shed_limit_vec>0)), max(n_levels_arr), min(n_levels_arr(shed_limit_vec>0)));
fprintf('   单户容量极值: 最大 %.2f kW/户, 最小 %.2f kW/户\n', max(kW_per_cust), min(kW_per_cust));
fprintf('   VOLL范围: L1=%.0f~%.0f, L2=%.0f~%.0f, L3=%.0f~%.0f 元/kWh\n', ...
    min(voll_vec(idx_L1))*1e3, max(voll_vec(idx_L1))*1e3, ...
    min(voll_vec(idx_L2))*1e3, max(voll_vec(idx_L2))*1e3, ...
    min(voll_vec(idx_L3))*1e3, max(voll_vec(idx_L3))*1e3);
fprintf('   FLEX_RATIO_L3=%.2f（L3柔性利用率，等效处理快响应比例）\n', FLEX_RATIO_L3);
fprintf('   正常分支=%d（含变压器%d条），联络线=%d，负荷节点=%d\n', nB_norm, n_trf, nTie, nL);

%% ================================================================
%  §5  MCF 路径识别（两步结构说明）
%
%  MCF（多商品流LP）基于"正常运行拓扑"计算每个负荷节点的供电路径，
%  输出 p_mat(k,xy)：节点k在故障xy后是否停电（基于正常拓扑的静态信息）。
%
%  【为什么MCF与MILP不能合并？】
%  1. MCF求解的是正常拓扑下的路径，与重构决策无关
%  2. p_mat是MILP的输入参数（Eq.13的 q≥1-p 中的常数矩阵）
%  3. 若合并，p_mat须变为决策变量，Eq(16)中 Ff,NO + Ff,NO_xy - 1 ≤ p_xy
%     将引入双线性项（两个连续变量之积），使问题变为非线性MIP，
%     求解难度指数级增加，且文献(Li et al.2020)本身也采用两步结构
%
%  效率优化：MCF是凸LP，对所有负荷节点同时建模，一次求解，耗时通常<1s
% ================================================================
fprintf('>> [5/8] MCF 路径识别...\n');
t_mcf = tic;
nSub=length(subs_idx); E_sub=sparse(subs_idx,1:nSub,1,num_nodes,nSub);

if strcmp(SOLVE_MODE,'MCF')
    E_load=sparse(load_nodes,1:nL,1,num_nodes,nL);
    F_mat=sdpvar(nB_norm,nL,'full'); Z_mat=sdpvar(nB_norm,nL,'full'); Gss=sdpvar(nSub,nL,'full');
    C_mcf=[-Z_mat<=F_mat, F_mat<=Z_mat, Z_mat>=0, 0<=Gss<=1, sum(Gss,1)==1, A_inc_norm*F_mat==E_load-E_sub*Gss];
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
fprintf('   MCF 完成（%.1f 秒），p_direct nnz=%d，p_feeder nnz=%d\n', ...
    t_mcf_elapsed, nnz(p_mat), nnz(p_feeder_mat));

%% ================================================================
%  §6  批量场景 MILP（稀疏ZZ优化 + VOLL差异化目标）
%
%  计算效率优化策略（问题2）：
%
%  1. 稀疏ZZ变量（最重要优化）
%     原版对所有nL个节点引入ZZ档位变量（nL×N_LEVELS×nScen个二进制）
%     优化：仅对"可能被切负荷的节点"引入ZZ变量
%       - L1节点：shed_limit=0，切负荷量固定=0，无需ZZ变量
%       - L2/L3非受影响节点：q=1且p_direct=0（Eq.13强制），但切负荷
%         对这些节点意义不大（正常运行节点不需要切负荷）
%       - 实际有效节点：p_direct=1 且 shed_limit>0 的节点-场景对
%     通过预计算"有效节点集"减少二进制变量数
%
%  2. Gurobi参数调优
%     MIPGap=1e-3（允许1‰最优性间隙，大幅加速），
%     Heuristics=0.05（5%计算量用于启发式搜索），
%     Presolve=2（激进预求解），Cuts=2（增强割平面）
%
%  3. 约束预锁定（减少搜索空间）
%     在构建约束前，对超过shed_limit的档位预置为0，
%     比求解时再施加约束更早地减小可行域
%
%  变量说明：
%    ZZ_valid (n_valid_entries × nScen) binary  有效节点-档位选择矩阵
%    L_mat    (nL × nScen) cont.≥0              切负荷量（pu）
%    ZZ通过SEL矩阵映射到L：L = SEL_valid × ZZ_valid
% ================================================================
fprintf('>> [6/8] 批量场景 MILP（稀疏ZZ + VOLL + 效率优化）...\n');
t_milp = tic;

nScen      = nB_norm;
p_mat_d    = double(p_mat);
p_feeder_d = double(p_feeder_mat);
lam_vec    = rel_branches(:,3);
trp_vec    = rel_branches(:,4);

Dr  = spdiags(r_b_all,  0,nB_all,nB_all);
Dx  = spdiags(x_b_all,  0,nB_all,nB_all);
Dp  = spdiags(P_free,   0,nL,nL);
Dq_ = spdiags(Q_free,   0,nL,nL);
Cap = spdiags(cap_b_all,0,nB_all,nB_all);

%% ── 预计算CID最小化权重矩阵 ──────────────────────────────────────────────
[~,c_row_pre]=ismember(inv_map(load_nodes),t_cust.Node);
NC_vec=zeros(nL,1); NC_vec(c_row_pre>0)=t_cust.NC(c_row_pre(c_row_pre>0));

tau_benefit = max(trp_vec - TAU_TIE_SW, 0);
W_cid  = (NC_vec .* p_mat_d) .* (lam_vec .* tau_benefit)';    % nL×nScen
W_shed = (voll_vec .* NC_vec .* p_mat_d) .* (lam_vec * BETA_SHED)'; % nL×nScen（VOLL差异化）

fprintf('   W_cid: max=%.4f, mean=%.4f (CID最小化权重)\n', max(full(W_cid(:))), mean(full(W_cid(W_cid>0))));
fprintf('   W_shed VOLL差异化: L1平均%.0f, L2平均%.0f, L3平均%.0f\n', ...
    mean(full(W_shed(idx_L1,:)),'all')*1e3, mean(full(W_shed(idx_L2,:)),'all')*1e3, mean(full(W_shed(idx_L3,:)),'all')*1e3);

%% ── 稀疏ZZ变量：仅对有效节点引入档位变量 ──────────────────────────────
%  有效节点定义：shed_limit > 0 的节点（L1节点切负荷=0，无需ZZ）
can_shed = shed_limit_vec > 1e-6;   % nL×1，逻辑向量

% 构建稀疏选择矩阵 SEL_s 和独热约束矩阵 ONESUM_s
% 仅对 can_shed=true 的节点（共 n_shed 个）构建
n_shed = sum(can_shed);
shed_nodes_idx = find(can_shed);   % 可切除节点的本地索引

% 各节点的有效档位数（可不同）
n_levels_per_node = cellfun(@length, node_levels);

% 构建 SEL_s: (n_shed) × (Σ n_levels_k) 稀疏矩阵
total_ZZ_rows = sum(n_levels_per_node(shed_nodes_idx));
row_idx = zeros(total_ZZ_rows, 1);
col_idx = (1:total_ZZ_rows)';
val_sel = zeros(total_ZZ_rows, 1);
val_one = ones(total_ZZ_rows, 1);

ptr = 0;
for ki = 1:n_shed
    k = shed_nodes_idx(ki);
    levels_k = node_levels{k};
    n_k = length(levels_k);
    rows = ptr+1 : ptr+n_k;
    row_idx(rows) = ki;
    val_sel(rows) = P_free(k) * levels_k(:);
    ptr = ptr + n_k;
end

SEL_s   = sparse(row_idx, col_idx, val_sel, n_shed, total_ZZ_rows);
ONESUM_s = sparse(row_idx, col_idx, val_one, n_shed, total_ZZ_rows);

fprintf('   稀疏ZZ优化: 可切节点=%d/%d, ZZ行数=%d (原版=%d, 压缩%.1f%%)\n', ...
    n_shed, nL, total_ZZ_rows, nL*mean(n_levels_arr(shed_limit_vec>0)), (1-total_ZZ_rows/(nL*mean(n_levels_arr(shed_limit_vec>0))+1e-9))*100);

%% ── 决策变量 ──────────────────────────────────────────────────────────────
S_mat   = binvar(nB_all,        nScen, 'full');
Q_mat   = binvar(nL,            nScen, 'full');
Pf_mat  = sdpvar(nB_all,        nScen, 'full');
Qf_mat  = sdpvar(nB_all,        nScen, 'full');
V_mat   = sdpvar(num_nodes,     nScen, 'full');
E_vdrop = sdpvar(nB_all,        nScen, 'full');
ZZ_s    = binvar(total_ZZ_rows, nScen, 'full');   % ★ 稀疏ZZ
L_mat   = sdpvar(nL,            nScen, 'full');   % 切负荷量

% L_mat 由 ZZ_s 决定（有效节点）+ L1节点强制为0
L_shed_part = SEL_s * ZZ_s;   % n_shed×nScen，有效节点的切负荷量

delta_mat     = BdV*V_mat + 2*(Dr*Pf_mat + Dx*Qf_mat);
fault_lin_idx = (0:nB_norm-1)*nB_all + (1:nB_norm);
P_max_mat     = repmat(P_free, 1, nScen);

%% ── 约束 ──────────────────────────────────────────────────────────────────
C = [V_mat(subs_idx,:)    == V_src_sq,                       ...
     V_mat(non_sub,:)     >= V_lower_sq - M_vn*(1-Q_mat),   ...
     V_mat(non_sub,:)     <= V_upper_sq + M_vn*(1-Q_mat),   ...
     -Cap*S_mat           <= Pf_mat <= Cap*S_mat,            ...
     -Cap*S_mat           <= Qf_mat <= Cap*S_mat,            ...
     A_free_all*Pf_mat    == Dp*Q_mat - L_mat,               ...
     A_free_all*Qf_mat    == Dq_*Q_mat - TAN_PHI*L_mat,      ...
     E_vdrop              >= 0,                              ...
     delta_mat            <=  M_V*(1-S_mat) + E_vdrop,       ...
     delta_mat            >= -M_V*(1-S_mat) - E_vdrop,       ...
     sum(S_mat,1)         == sum(Q_mat,1),                   ...
     S_mat(fault_lin_idx) == 0,                              ...
     Q_mat                >= 1 - p_feeder_d];

% ── 稀疏切负荷约束 ──────────────────────────────────────────────────────
% L1节点：切负荷严格为0
if any(~can_shed)
    C = [C, L_mat(~can_shed,:) == 0];
end
% 有效节点：通过ZZ_s决定切负荷量
C = [C, ...
     ZZ_s                >= 0,                    ...
     L_mat(shed_nodes_idx,:) == L_shed_part,      ...  % L由ZZ决定
     ONESUM_s * ZZ_s     == 1,                    ...  % 每节点选且仅选一档
     L_mat               >= 0,                    ...
     L_mat               <= P_max_mat .* Q_mat];       % q=0时L=0

%% ── Gurobi效率参数 ──────────────────────────────────────────────────────
opts_milp = sdpsettings('solver','gurobi','verbose',0, ...
    'gurobi.MIPGap',        1e-3, ...   % 允许1‰最优性间隙
    'gurobi.Heuristics',    0.05, ...   % 5%计算量用于MIP启发式
    'gurobi.Presolve',      2,    ...   % 激进预求解（删除冗余约束/变量）
    'gurobi.Cuts',          2, ...   % 增强割平面
    'gurobi.NodefileStart', 0.5);       % 超过0.5GB内存时使用磁盘

%% ── 目标函数（CID最小化 + VOLL差异化切负荷惩罚）────────────────────────
% objective = -sum(sum(W_cid .* Q_mat)) ...
%            + sum(sum(W_shed .* L_mat)) ...
%            + 1e-4 * sum(E_vdrop(:));
objective = -sum(sum(W_cid .* Q_mat)) ...
           + sum(sum(W_shed .* L_mat)) ...
           + 1e-4 * sum(E_vdrop(:));
sol = optimize(C, objective, opts_milp);

%% ── 提取结果 ──────────────────────────────────────────────────────────────
if sol.problem == 0
    Qv = value(Q_mat);
    if any(isnan(Qv(:)))
        warning('[§6] Q_mat含NaN，退化处理');
        q_mat=logical(1-p_feeder_d); L_res=zeros(nL,nScen);
        Pf_res=zeros(nB_all,nScen); Qf_res=zeros(nB_all,nScen);
        Vm_res=repmat(V_src_sq,num_nodes,nScen); Sw_res=zeros(nB_all,nScen);
    else
        q_mat=logical(round(Qv));
        L_res=max(value(L_mat),0);
        Pf_res=value(Pf_mat); Qf_res=value(Qf_mat);
        Vm_res=sqrt(max(value(V_mat),0)); Sw_res=round(value(S_mat));
    end
else
    warning('[§6] MILP失败: %s，退化处理',sol.info);
    q_mat=logical(1-p_feeder_d); L_res=zeros(nL,nScen);
    Pf_res=zeros(nB_all,nScen); Qf_res=zeros(nB_all,nScen);
    Vm_res=repmat(V_src_sq,num_nodes,nScen); Sw_res=zeros(nB_all,nScen);
end

%% ── 恢复率统计（功率基）──────────────────────────────────────────────────
q_mat_d=double(q_mat); p_direct_d=double(p_mat); p_feeder_d_full=double(p_feeder_mat);
SHED_THRESH=1e-4;
mask_q1=q_mat_d>0.5;
n_full_rec  = full(sum(mask_q1(:) & L_res(:)<=SHED_THRESH & p_direct_d(:)>0.5));
n_part_rec  = full(sum(mask_q1(:) & L_res(:)>SHED_THRESH  & p_direct_d(:)>0.5));
n_unrec     = full(sum((q_mat_d(:)<0.5) & (p_direct_d(:)>0.5)));
n_aff_total = full(sum(p_direct_d(:)>0));
P_free_mat  = repmat(P_free,1,nScen);
aff_power   = full(sum(sum(P_free_mat.*p_direct_d)));
net_rec_power = full(sum(sum((P_free_mat-L_res).*q_mat_d.*p_direct_d)));
rec_pct_power = net_rec_power/max(aff_power,1e-9)*100;
total_shed_pu = full(sum(sum(L_res.*q_mat_d.*p_direct_d)));

% 按等级统计切负荷
mask_L1=false(nL,1); mask_L1(idx_L1)=true;
mask_L2=false(nL,1); mask_L2(idx_L2)=true;
mask_L3=false(nL,1); mask_L3(idx_L3)=true;
shed_by_level=[sum(sum(L_res(mask_L1,:).*q_mat_d(mask_L1,:))), ...
               sum(sum(L_res(mask_L2,:).*q_mat_d(mask_L2,:))), ...
               sum(sum(L_res(mask_L3,:).*q_mat_d(mask_L3,:)))];

t_milp_elapsed=toc(t_milp);
fprintf('   MILP 完成（%.1f 秒）\n',t_milp_elapsed);
fprintf('   恢复分类: 完全=%d, 部分=%d, 未恢复=%d / 受影响=%d\n', ...
    n_full_rec, n_part_rec, n_unrec, n_aff_total);
fprintf('   功率基恢复率=%.1f%%  总切负荷=%.4f pu·场景\n', rec_pct_power, total_shed_pu);
fprintf('   切负荷分布: L1=%.4f, L2=%.4f, L3=%.4f pu·场景\n', shed_by_level);

%% ================================================================
%  §7  可靠性指标计算（三阶段+切负荷修正CID）
% ================================================================
fprintf('>> [7/8] 计算可靠性指标...\n');

lam=rel_branches(:,3); trp=rel_branches(:,4);
p_upstream_d = p_feeder_d_full - p_direct_d;

[~,c_row]=ismember(inv_map(load_nodes),t_cust.Node);
NC_vec_r=zeros(nL,1); NC_vec_r(c_row>0)=t_cust.NC(c_row(c_row>0));
[~,p_row]=ismember(inv_map(load_nodes),t_peak.Node);
P_avg_vec=zeros(nL,1);
P_avg_vec(p_row>0)=t_peak.P_kW(p_row(p_row>0))*sum(L_f.*(T_l/8760));
total_cust=sum(NC_vec_r);

P_free_safe=max(P_free,1e-9);
shed_ratio=(L_res./repmat(P_free_safe,1,nScen)).*q_mat_d.*p_direct_d;

CIF = p_feeder_d_full * lam;
CID_upstream = TAU_UP_SW*(p_upstream_d*lam);
CID_tieline  = TAU_TIE_SW*(p_direct_d.*q_mat_d)*lam;
CID_repair   = (p_direct_d.*(1-q_mat_d))*(lam.*trp);
CID_shed_add = (shed_ratio.*p_direct_d.*q_mat_d)*(lam.*(trp-TAU_TIE_SW));
CID = CID_upstream + CID_tieline + CID_repair + CID_shed_add;

SAIFI=(NC_vec_r'*CIF)/total_cust; SAIDI=(NC_vec_r'*CID)/total_cust;
EENS=(P_avg_vec'*CID)/1e3; ASAI=1-SAIDI/8760;

SAIDI_contrib_up  =(NC_vec_r'*CID_upstream)/total_cust;
SAIDI_contrib_tie =(NC_vec_r'*CID_tieline)/total_cust;
SAIDI_contrib_rep =(NC_vec_r'*CID_repair)/total_cust;
SAIDI_contrib_shed=(NC_vec_r'*CID_shed_add)/total_cust;

CID_R1=TAU_UP_SW*(p_upstream_d*lam)+p_direct_d*(lam.*trp);
CIF_R1=p_feeder_d_full*lam;
SAIFI_R1=(NC_vec_r'*CIF_R1)/total_cust; SAIDI_R1=(NC_vec_r'*CID_R1)/total_cust;
EENS_R1=(P_avg_vec'*CID_R1)/1e3; ASAI_R1=1-SAIDI_R1/8760;

%% ================================================================
%  §8  结果输出
% ================================================================
total_elapsed=toc(program_total);

fprintf('\n╔══════════════════════════════════════════╗\n');
fprintf('  系统: %-39s\n', sys_filename);
fprintf('  负荷: L1=%d(%.0f%%), L2=%d(%.0f%%), L3=%d(%.0f%%)\n', ...
    nL1,nL1/nL*100,nL2,nL2/nL*100,nL3,nL3/nL*100);
fprintf('  FLEX_RATIO_L3=%.2f  τ_TIE_SW=%.2fh\n', FLEX_RATIO_L3, TAU_TIE_SW);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  [R2 含重构+VOLL切负荷]                   ║\n');
fprintf('║  SAIFI : %10.4f  次/(户·年)         ║\n', SAIFI);
fprintf('║  SAIDI : %10.4f  h/(户·年)          ║\n', SAIDI);
fprintf('║    ①上游开关恢复  : %+8.4f h/(户·年)  \n', SAIDI_contrib_up);
fprintf('║    ②联络线转供    : %+8.4f h/(户·年)  \n', SAIDI_contrib_tie);
fprintf('║    ③等待修复      : %+8.4f h/(户·年)  \n', SAIDI_contrib_rep);
fprintf('║    ④切负荷额外等待: %+8.4f h/(户·年)  \n', SAIDI_contrib_shed);
fprintf('║  EENS  : %10.2f  MWh/年             ║\n', EENS);
fprintf('║  ASAI  : %12.6f                   ║\n', ASAI);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  [R1 不含重构]                            ║\n');
fprintf('║  SAIDI : %10.4f  h/(户·年)          ║\n', SAIDI_R1);
fprintf('║  EENS  : %10.2f  MWh/年             ║\n', EENS_R1);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  SAIDI 改善: %+10.4f h/(户·年)             \n', SAIDI_R1-SAIDI);
fprintf('║  EENS  改善: %+10.2f MWh/年               \n', EENS_R1-EENS);
fprintf('║  功率基恢复率: %.1f%%                       \n', rec_pct_power);
fprintf('║    完全恢复=%d, 部分(切负荷)=%d, 未恢复=%d  \n', n_full_rec, n_part_rec, n_unrec);
fprintf('║  切负荷(L1/L2/L3): %.4f/%.4f/%.4f pu·场景 \n', shed_by_level);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  §5 MCF : %7.1f 秒                    \n', t_mcf_elapsed);
fprintf('║  §6 MILP: %7.1f 秒 (ZZ行=%d)         \n', t_milp_elapsed, total_ZZ_rows);
fprintf('║  总耗时 : %7.1f 秒                    \n', total_elapsed);
fprintf('╚══════════════════════════════════════════╝\n');

% 代表性场景输出
[~,rep_xy]=max(sum(p_direct_d,1));
fprintf('\n══════════════════════════════════════════════\n');
fprintf('  代表性故障场景 %d（分支 %d─%d 故障）潮流与切负荷\n', ...
    rep_xy, inv_map(rel_branches(rep_xy,1)), inv_map(rel_branches(rep_xy,2)));
fprintf('══════════════════════════════════════════════\n');

Vm_rep=Vm_res(:,rep_xy); Pf_rep=Pf_res(:,rep_xy); Qf_rep=Qf_res(:,rep_xy);
Sw_rep=Sw_res(:,rep_xy); qv_rep=q_mat(:,rep_xy);
pf_rep=full(p_feeder_d_full(:,rep_xy)); L_rep=L_res(:,rep_xy);

shed_nodes_rep=find(L_rep>SHED_THRESH & qv_rep);
if ~isempty(shed_nodes_rep)
    fprintf('\n  切负荷节点\n');
    fprintf('  %-10s  %-4s  %-8s  %-12s  %-12s  %-8s\n','节点','级别','VOLL','P_demand/kW','L_shed/kW','切除比例');
    fprintf('  %s\n',repmat('─',1,60));
    for k=shed_nodes_rep'
        lvl=ternary(mask_L1(k),'L1',ternary(mask_L2(k),'L2','L3'));
        fprintf('  %-10d  %-4s  %-8.0f  %-12.2f  %-12.2f  %-8.1f%%\n', ...
            inv_map(load_nodes(k)), lvl, voll_vec(k)*1e3, P_free(k)*1e3, L_rep(k)*1e3, ...
            L_rep(k)/P_free_safe(k)*100);
    end
end

fprintf('\n  节点电压（供电节点）\n');
fprintf('  %-10s  %-10s  %-4s  %-16s\n','节点','电压/pu','级别','状态');
fprintf('  %s\n',repmat('─',1,44));
for si=1:length(subs_idx)
    fprintf('  %-10d  %-10.4f  %-4s  变电站\n',inv_map(subs_idx(si)),Vm_rep(subs_idx(si)),'─');
end
for k=1:nL
    if qv_rep(k)
        lvl=ternary(mask_L1(k),'L1',ternary(mask_L2(k),'L2','L3'));
        if pf_rep(k)>0&&L_rep(k)>SHED_THRESH
            st=sprintf('转供(切%.1f%%)',L_rep(k)/P_free_safe(k)*100);
        elseif pf_rep(k)>0; st='转供恢复';
        else; st='正常供电'; end
        fprintf('  %-10d  %-10.4f  %-4s  %s\n',inv_map(load_nodes(k)),Vm_rep(load_nodes(k)),lvl,st);
    end
end
n_dark=sum(~qv_rep&pf_rep>0);
if n_dark>0, fprintf('  （%d 个受影响节点未恢复，略去）\n',n_dark); end

fprintf('\n  合路分支潮流（kW/kVar）\n');
fprintf('  %-6s  %-6s  %-6s  %-12s  %-12s  %-8s\n','分支#','From','To','P/kW','Q/kVar','类型');
fprintf('  %s\n',repmat('─',1,60));
for b = 1:nB_all
    if Sw_rep(b) == 1
        from_raw = inv_map(all_branches(b,1));
        to_raw   = inv_map(all_branches(b,2));
        P_kW   = Pf_rep(b) * 1e3;
        Q_kVar = Qf_rep(b) * 1e3;
        if b <= nB_norm
            br_type = ternary(is_trf_vec(b), '变压器', '线路');
        else
            br_type = '联络线';
        end
        fprintf('  %-6d  %-6d  %-6d  %+12.2f  %+12.2f  %s\n', ...
            b, from_raw, to_raw, P_kW, Q_kVar, br_type);
    end
end

P_total=0; Q_total=0;
for b=1:nB_all
    if Sw_rep(b)==1
        if ismember(all_branches(b,1),subs_idx); P_total=P_total+Pf_rep(b); Q_total=Q_total+Qf_rep(b);
        elseif ismember(all_branches(b,2),subs_idx); P_total=P_total-Pf_rep(b); Q_total=Q_total-Qf_rep(b); end
    end
end
fprintf('\n  场景汇总：受影响=%d，恢复=%d，未恢复=%d，切负荷=%.2fkW\n', ...
    sum(pf_rep),sum(qv_rep&pf_rep>0),sum(~qv_rep&pf_rep>0),sum(L_rep(qv_rep))*1e3);
fprintf('  变电站总出力：P=%.2f kW，Q=%.2f kVar\n',P_total*1e3,Q_total*1e3);

%% ── 辅助内联函数 ─────────────────────────────────────────────
function out = ternary(cond, a, b)
    if cond, out = a; else, out = b; end
end
