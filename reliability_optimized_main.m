%% ============================================================
%  配电网可靠性评估优化版 - 基于低压分支的离散切负荷与统一优化模型
%
%  优化改进：
%  [1] 负荷等级基于用户数和负荷占比确定（非随机）
%  [2] 基于低压分支数的真实切负荷档位（2^n种状态）
%  [3] MCF与MILP统一优化模型（单阶段求解）
%  [4] 量纲统一的目标函数（元）+ 开关动作成本
%  [5] 计算效率优化（稀疏化、预处理、并行化）
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
LAMBDA_TRF = 0.5;   % 变压器故障率

% ── 多阶段恢复时间（h）───────────────────────────────────────
TAU_UP_SW  = 0.3;   % 上游开关操作时间
TAU_TIE_SW = 0.5;   % 联络线切换时间

% ── [优化1] 负荷等级划分参数（基于实际占比，非随机）────────
%  等级划分权重：w1*用户占比 + w2*负荷占比
PRIORITY_WEIGHT_USER = 0.6;   % 用户数权重（社会影响）
PRIORITY_WEIGHT_LOAD = 0.4;   % 负荷量权重（经济影响）
NUM_PRIORITY_LEVELS = 5;      % 优先级等级数（1=最高）

% ── VOLL参数（元/kWh）─────────────────────────────────────────
VOLL_BY_PRIORITY = [200, 100, 50, 20, 10];  % 各优先级的VOLL
SHED_LIMIT_BY_PRIORITY = [0.0, 0.1, 0.25, 0.5, 1.0];  % 切负荷上限

% ── [优化2] 低压分支参数 ─────────────────────────────────────
%  实际台区通常有2-8条低压分支，根据用户数模拟
MIN_BRANCHES = 2;             % 最少分支数
MAX_BRANCHES = 8;             % 最多分支数
USERS_PER_BRANCH = 50;        % 平均每条分支服务用户数

% ── [优化4] 成本参数（统一量纲：元）─────────────────────────
%ELECTRICITY_PRICE = 0.6;      % 电价（元/kWh）
SWITCHING_COST = 100.0;       % 开关动作成本（元/次）
%NETWORK_LOSS_WEIGHT = 1.0;    % 网损成本权重

% ── 目标函数权重 ──────────────────────────────────────────────
WEIGHT_CID = 1000.0;          % CID惩罚权重（元/h）- 量纲统一
WEIGHT_VOLL = 1.0;            % VOLL权重
WEIGHT_SWITCHING = 1.0;       % 开关动作权重

% ── 电压约束与功率因数 ────────────────────────────────────────
V_UPPER = 1.05;   V_LOWER = 0.95;   V_SRC = 1.0;
PF = 0.9;

% ── [优化5] Gurobi求解器参数 ─────────────────────────────────
GUROBI_TIME_LIMIT = 300;      % 最大求解时间（秒）
GUROBI_MIP_GAP = 0.01;        % MIP最优性gap（1%）
GUROBI_THREADS = 8;           % 并行线程数
GUROBI_PRESOLVE = 2;          % 预处理级别（2=aggressive）
GUROBI_CUTS = 2;              % 切平面策略（2=aggressive）

% ============================================================

program_total = tic;

%% ================================================================
%  §1  Testbench 数据读取
% ================================================================
fprintf('>> [1/9] 读取 Testbench: Sheet="%s"\n', sys_sheet);

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
fprintf('>> [2/9] 读取可靠性参数: %s\n', sys_filename);

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
fprintf('>> [3/9] 生成潮流参数...\n');
R_KM=0.003151; X_KM=0.001526; TAN_PHI=tan(acos(PF));
V_src_sq=V_SRC^2; V_upper_sq=V_UPPER^2; V_lower_sq=V_LOWER^2;
fprintf('   R=%.4f, X=%.4f pu/km, V∈[%.2f,%.2f] pu\n', R_KM, X_KM, V_LOWER, V_UPPER);

%% ================================================================
%  §4  拓扑索引构建
% ================================================================
fprintf('>> [4/9] 构建拓扑索引...\n');
raw_nodes = unique([t_branch.From; t_branch.To; TIE_LINES_RAW(:)]);
num_nodes = length(raw_nodes);
node_map  = containers.Map(raw_nodes, 1:num_nodes);
inv_map   = raw_nodes;
subs_raw  = raw_nodes(~ismember(raw_nodes, t_cust.Node));
subs_idx  = arrayfun(@(s) node_map(s), subs_raw);
nB_norm = height(t_branch); nTie = size(TIE_LINES_RAW,1); nB_all = nB_norm+nTie;

% 构建分支数据
rel_branches = zeros(nB_norm,8);
is_trf_vec = false(nB_norm,1);
for b = 1:nB_norm
    u_raw=t_branch.From(b); v_raw=t_branch.To(b);
    u=node_map(u_raw); v=node_map(v_raw); len=t_branch.Length_km(b);
    match=(t_dur.From==u_raw&t_dur.To==v_raw)|(t_dur.From==v_raw&t_dur.To==u_raw);
    if ~any(match), error('分支(%d-%d)无停电时间',u_raw,v_raw); end
    is_trf=ismember(u,subs_idx)|ismember(v,subs_idx);
    is_trf_vec(b)=is_trf;
    cap_b=TRAN_CAP*is_trf+LINE_CAP*(~is_trf);
    lam_b=ternary(LAMBDA_TRF>0&&is_trf, LAMBDA_TRF, len*lambda_per_km);
    rel_branches(b,:)=[u,v,lam_b,t_dur.RP(match),t_dur.SW(match),R_KM*len,X_KM*len,cap_b];
end

% 构建完整分支列表（含联络线）
all_branches = [rel_branches(:,1:2); zeros(nTie,2)];
for ti = 1:nTie
    u_raw = TIE_LINES_RAW(ti,1); v_raw = TIE_LINES_RAW(ti,2);
    all_branches(nB_norm+ti,:) = [node_map(u_raw), node_map(v_raw)];
end

% 识别负荷节点
load_nodes = arrayfun(@(x) node_map(x), t_cust.Node);
nL = length(load_nodes);

fprintf('   节点=%d, 分支=%d(正常)+%d(联络), 负荷节点=%d\n', num_nodes, nB_norm, nTie, nL);

%% ================================================================
%  §5  [优化1] 负荷等级划分：基于用户数和负荷占比
% ================================================================
fprintf('>> [5/9] [优化1] 基于实际参数分配负荷等级...\n');

% 提取用户数和负荷
[~,c_row]=ismember(inv_map(load_nodes),t_cust.Node);
NC_vec=zeros(nL,1); NC_vec(c_row>0)=t_cust.NC(c_row(c_row>0));
[~,p_row]=ismember(inv_map(load_nodes),t_peak.Node);
P_peak_vec=zeros(nL,1); P_peak_vec(p_row>0)=t_peak.P_kW(p_row(p_row>0));

% 计算综合评分 = w1*用户占比 + w2*负荷占比
total_users = sum(NC_vec);
total_load = sum(P_peak_vec);
user_ratio = NC_vec / max(total_users, 1);
load_ratio = P_peak_vec / max(total_load, 1);
priority_score = PRIORITY_WEIGHT_USER * user_ratio + PRIORITY_WEIGHT_LOAD * load_ratio;

% 按评分降序排列，评分高的优先级高（数值小）
[~, sort_idx] = sort(priority_score, 'descend');
priority_level = zeros(nL, 1);
for k = 1:nL
    % 将节点均匀分配到NUM_PRIORITY_LEVELS个等级
    priority_level(sort_idx(k)) = min(NUM_PRIORITY_LEVELS, ceil(k * NUM_PRIORITY_LEVELS / nL));
end

% 分配VOLL和切负荷上限
voll_vec = zeros(nL, 1);
shed_limit_vec = zeros(nL, 1);
for k = 1:nL
    p = priority_level(k);
    voll_vec(k) = VOLL_BY_PRIORITY(p) / 1e3;  % 转换为元/kW
    shed_limit_vec(k) = SHED_LIMIT_BY_PRIORITY(p);
end

% 统计各等级节点数
priority_counts = histcounts(priority_level, 1:NUM_PRIORITY_LEVELS+1);
fprintf('   负荷等级分配完成（基于用户占比%.1f%% + 负荷占比%.1f%%）:\n', ...
    PRIORITY_WEIGHT_USER*100, PRIORITY_WEIGHT_LOAD*100);
for p = 1:NUM_PRIORITY_LEVELS
    fprintf('     等级%d: %d节点, VOLL=%.0f元/kWh, 切负荷上限=%.0f%%\n', ...
        p, priority_counts(p), VOLL_BY_PRIORITY(p), SHED_LIMIT_BY_PRIORITY(p)*100);
end

%% ================================================================
%  §6  [优化2] 生成基于低压分支的切负荷档位
% ================================================================
fprintf('>> [6/9] [优化2] 生成基于低压分支的离散切负荷状态...\n');

% 根据用户数模拟每个节点的低压分支数
num_branches = zeros(nL, 1);
for k = 1:nL
    % 分支数 = ceil(用户数 / 平均每分支用户数)，限制在[MIN_BRANCHES, MAX_BRANCHES]
    num_branches(k) = max(MIN_BRANCHES, min(MAX_BRANCHES, ceil(NC_vec(k) / USERS_PER_BRANCH)));
end

% 为每个节点生成切负荷状态
% shed_states{k} = 矩阵，每行代表一种状态：[状态ID, 切负荷比例, 受影响用户比例]
shed_states = cell(nL, 1);
max_states = 0;

for k = 1:nL
    n_br = num_branches(k);
    n_states = 2^n_br;  % 所有开关组合
    max_states = max(max_states, n_states);
    
    % 模拟每条分支的负荷和用户分布（使用Dirichlet分布确保真实性）
    alpha = ones(1, n_br);  % Dirichlet参数
    branch_dist = gamrnd(alpha, 1);
    branch_dist = branch_dist / sum(branch_dist);  % 归一化
    
    states = zeros(n_states, 3);
    for s = 0:n_states-1
        % 二进制编码：1表示该分支断开
        binary = de2bi(s, n_br);
        shed_ratio = sum(branch_dist .* binary);  % 切负荷比例
        user_ratio = sum(branch_dist .* binary);  % 受影响用户比例
        
        % 限制在允许的切负荷范围内
        shed_ratio = min(shed_ratio, shed_limit_vec(k));
        
        states(s+1, :) = [s, shed_ratio, user_ratio];
    end
    
    shed_states{k} = states;
end

fprintf('   低压分支配置:\n');
fprintf('     平均分支数: %.1f, 最大状态数: %d\n', mean(num_branches), max_states);
fprintf('     示例节点1: %d分支, %d种状态\n', num_branches(1), size(shed_states{1}, 1));

%% ================================================================
%  §7  [优化3+4+5] 统一优化模型求解
% ================================================================
fprintf('>> [7/9] [优化3-5] 构建并求解统一优化模型...\n');
t_opt = tic;

% 计算故障场景
lam = rel_branches(:,3);
nScen = nB_norm;

% 使用稀疏矩阵存储结果
L_res = sparse(nL, nScen);
Pf_res = sparse(nB_all, nScen);
Qf_res = sparse(nB_all, nScen);
Vm_res = sparse(num_nodes, nScen);
Sw_res = sparse(nB_all, nScen);
q_mat = sparse(nL, nScen);
switch_count = sparse(nL, nScen);  % 开关动作次数

% [优化5] 并行化处理（如果Parallel Computing Toolbox可用）
if license('test', 'Distrib_Computing_Toolbox')
    fprintf('   使用并行计算加速...\n');
    use_parallel = true;
    % 预分配并行变量
    L_res_cell = cell(1, nScen);
    Pf_res_cell = cell(1, nScen);
    Q_res_cell = cell(1, nScen);
    Vm_res_cell = cell(1, nScen);
    Sw_res_cell = cell(1, nScen);
    q_mat_cell = cell(1, nScen);
    switch_cell = cell(1, nScen);
else
    use_parallel = false;
end

fprintf('   求解%d个故障场景...\n', nScen);

if use_parallel
    parfor xy = 1:nScen
        [L_res_cell{xy}, Pf_res_cell{xy}, Qf_res_cell{xy}, Vm_res_cell{xy}, ...
         Sw_res_cell{xy}, q_mat_cell{xy}, switch_cell{xy}] = ...
            solve_single_scenario(xy, rel_branches, all_branches, load_nodes, ...
            shed_states, voll_vec, P_peak_vec, L_f, num_nodes, nB_norm, nB_all, ...
            subs_idx, V_src_sq, V_upper_sq, V_lower_sq, TAN_PHI, ...
            WEIGHT_CID, WEIGHT_VOLL, WEIGHT_SWITCHING, TAU_TIE_SW, ...
            SWITCHING_COST, GUROBI_TIME_LIMIT, GUROBI_MIP_GAP, ...
            GUROBI_THREADS, GUROBI_PRESOLVE, GUROBI_CUTS);
    end
    
    % 合并结果
    for xy = 1:nScen
        L_res(:,xy) = L_res_cell{xy};
        Pf_res(:,xy) = Pf_res_cell{xy};
        Qf_res(:,xy) = Qf_res_cell{xy};
        Vm_res(:,xy) = Vm_res_cell{xy};
        Sw_res(:,xy) = Sw_res_cell{xy};
        q_mat(:,xy) = q_mat_cell{xy};
        switch_count(:,xy) = switch_cell{xy};
    end
else
    % 串行处理
    for xy = 1:nScen
        if mod(xy, 10) == 0
            fprintf('     场景 %d/%d...\n', xy, nScen);
        end
        
        [L_res(:,xy), Pf_res(:,xy), Qf_res(:,xy), Vm_res(:,xy), ...
         Sw_res(:,xy), q_mat(:,xy), switch_count(:,xy)] = ...
            solve_single_scenario(xy, rel_branches, all_branches, load_nodes, ...
            shed_states, voll_vec, P_peak_vec, L_f, num_nodes, nB_norm, nB_all, ...
            subs_idx, V_src_sq, V_upper_sq, V_lower_sq, TAN_PHI, ...
            WEIGHT_CID, WEIGHT_VOLL, WEIGHT_SWITCHING, TAU_TIE_SW, ...
            SWITCHING_COST, GUROBI_TIME_LIMIT, GUROBI_MIP_GAP, ...
            GUROBI_THREADS, GUROBI_PRESOLVE, GUROBI_CUTS);
    end
end

t_opt_elapsed = toc(t_opt);
fprintf('   优化求解完成（%.1f 秒）\n', t_opt_elapsed);

%% ================================================================
%  §8  可靠性指标计算
% ================================================================
fprintf('>> [8/9] 计算可靠性指标...\n');

% 计算平均负荷
P_avg_vec = P_peak_vec * sum(L_f .* (T_l/8760));
total_cust = sum(NC_vec);

% 计算停电影响矩阵（基于优化结果）
p_mat = sparse(nL, nScen);
for xy = 1:nScen
    % 如果节点有供电或被恢复，则p_mat=1
    supplied = full(sum(Sw_res(:,xy) .* (all_branches(:,2) == load_nodes')', 1))' > 0;
    p_mat(:,xy) = supplied;
end

% 三阶段CID计算（包含切负荷修正）
trp = rel_branches(:,4);
P_free_safe = max(P_peak_vec, 1e-9);
shed_ratio = (L_res ./ repmat(P_free_safe, 1, nScen)) .* q_mat .* p_mat;

CIF = p_mat * lam;
CID_tieline = TAU_TIE_SW * (p_mat .* q_mat) * lam;
CID_repair = (p_mat .* (1-q_mat)) * (lam .* trp);
CID_shed_add = (shed_ratio .* p_mat .* q_mat) * (lam .* (trp - TAU_TIE_SW));
CID = CID_tieline + CID_repair + CID_shed_add;

% 可靠性指标
SAIFI = (NC_vec' * CIF) / total_cust;
SAIDI = (NC_vec' * CID) / total_cust;
EENS = (P_avg_vec' * CID) / 1e3;
ASAI = 1 - SAIDI / 8760;

% 总开关动作次数
total_switches = full(sum(switch_count(:)));

% 总成本分析（基于优化目标函数）
total_voll_cost = full(sum(sum(L_res .* repmat(voll_vec, 1, nScen) .* q_mat)));
total_switch_cost = total_switches * SWITCHING_COST;
total_cid_cost = SAIDI * total_cust * WEIGHT_CID;

fprintf('   SAIFI = %.4f 次/(户·年)\n', SAIFI);
fprintf('   SAIDI = %.4f h/(户·年)\n', SAIDI);
fprintf('   EENS  = %.2f MWh/年\n', EENS);
fprintf('   ASAI  = %.6f\n', ASAI);
fprintf('   总开关动作: %d 次\n', total_switches);

%% ================================================================
%  §9  结果输出与对比
% ================================================================
total_elapsed = toc(program_total);

fprintf('\n╔══════════════════════════════════════════╗\n');
fprintf('║  优化版配电网可靠性评估结果              ║\n');
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  系统规模: %d节点, %d负荷节点            \n', num_nodes, nL);
fprintf('║  负荷等级: %d级（基于实际占比）          \n', NUM_PRIORITY_LEVELS);
fprintf('║  切负荷档位: 基于%d-%d条低压分支         \n', MIN_BRANCHES, MAX_BRANCHES);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  可靠性指标:                              ║\n');
fprintf('║    SAIFI = %.4f 次/(户·年)              ║\n', SAIFI);
fprintf('║    SAIDI = %.4f h/(户·年)               ║\n', SAIDI);
fprintf('║    EENS  = %.2f MWh/年                  ║\n', EENS);
fprintf('║    ASAI  = %.6f                        ║\n', ASAI);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  成本分析（统一量纲：元）:                ║\n');
fprintf('║    VOLL成本    = %.2f 元                \n', total_voll_cost);
fprintf('║    开关成本    = %.2f 元                \n', total_switch_cost);
fprintf('║    CID惩罚成本 = %.2f 元                \n', total_cid_cost);
fprintf('║    总成本      = %.2f 元                \n', total_voll_cost+total_switch_cost+total_cid_cost);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  计算效率:                                ║\n');
fprintf('║    优化求解 = %.1f 秒                   \n', t_opt_elapsed);
fprintf('║    总耗时   = %.1f 秒                   \n', total_elapsed);
fprintf('║    平均每场景 = %.2f 秒                 \n', t_opt_elapsed/nScen);
fprintf('╚══════════════════════════════════════════╝\n');

%% ================================================================
%  子函数：求解单个故障场景的统一优化模型
% ================================================================
function [L_opt, Pf_opt, Qf_opt, Vm_opt, Sw_opt, q_opt, switch_count] = ...
    solve_single_scenario(xy, rel_branches, all_branches, load_nodes, ...
    shed_states, voll_vec, P_peak_vec, L_f, num_nodes, nB_norm, nB_all, ...
    subs_idx, V_src_sq, V_upper_sq, V_lower_sq, TAN_PHI, ...
    WEIGHT_CID, WEIGHT_VOLL, WEIGHT_SWITCHING, TAU_TIE_SW, ...
    SWITCHING_COST, TIME_LIMIT, MIP_GAP, THREADS, PRESOLVE, CUTS)
    
    % 初始化
    nL = length(load_nodes);
    P_free = P_peak_vec .* (L_f(1) + L_f(2) + L_f(3)) / 3;  % 平均负荷
    
    % 故障分支
    fault_branch = xy;
    
    % [优化3] 统一优化模型：同时优化网络重构和切负荷
    
    % 决策变量
    Pf = sdpvar(nB_all, 1);  % 有功潮流
    Qf = sdpvar(nB_all, 1);  % 无功潮流
    Vm = sdpvar(num_nodes, 1);  % 电压平方
    Sw = binvar(nB_all, 1);  % 开关状态（二进制）
    L_shed = sdpvar(nL, 1);  % 切负荷量（连续）
    
    % 切负荷状态变量（二进制）：Z{k}(s) = 1表示节点k选择状态s
    Z = cell(nL, 1);
    for k = 1:nL
        n_states = size(shed_states{k}, 1);
        Z{k} = binvar(n_states, 1);
    end
    
    % 约束条件
    Constraints = [];
    
    % 1. 辐射状约束：开关数 = 节点数 - 变电站数
    Constraints = [Constraints, sum(Sw) == num_nodes - length(subs_idx)];
    
    % 2. 故障分支强制断开
    Constraints = [Constraints, Sw(fault_branch) == 0];
    
    % 3. 潮流平衡约束（考虑切负荷）
    for k = 1:nL
        node = load_nodes(k);
        % 流入该节点的分支
        in_branches = find(all_branches(:,2) == node);
        % 流出该节点的分支
        out_branches = find(all_branches(:,1) == node);
        
        % 有功平衡：流入 - 流出 = 需求 - 切负荷
        P_in = sum(Pf(in_branches));
        P_out = sum(Pf(out_branches));
        Constraints = [Constraints, P_in - P_out == P_free(k) - L_shed(k)];
        
        % 无功平衡
        Q_in = sum(Qf(in_branches));
        Q_out = sum(Qf(out_branches));
        Constraints = [Constraints, Q_in - Q_out == (P_free(k) - L_shed(k)) * TAN_PHI];
    end
    
    % 4. 电压约束
    Constraints = [Constraints, Vm >= V_lower_sq, Vm <= V_upper_sq];
    for si = 1:length(subs_idx)
        Constraints = [Constraints, Vm(subs_idx(si)) == V_src_sq];
    end
    
    % 5. 电压降约束（Big-M方法）
    M_large = 10;  % Big-M常数
    for b = 1:nB_all
        if b <= nB_norm
            i = all_branches(b,1);
            j = all_branches(b,2);
            R = rel_branches(b,6);
            X = rel_branches(b,7);
            
            % Vm(j) = Vm(i) - 2*(R*Pf + X*Qf) (when Sw=1)
            Constraints = [Constraints, ...
                Vm(j) <= Vm(i) - 2*(R*Pf(b) + X*Qf(b)) + M_large*(1-Sw(b)), ...
                Vm(j) >= Vm(i) - 2*(R*Pf(b) + X*Qf(b)) - M_large*(1-Sw(b))];
        end
    end
    
    % 6. 潮流-开关耦合（Big-M方法）
    for b = 1:nB_all
        cap = 100;  % 容量上限
        if b <= nB_norm
            cap = rel_branches(b,8);
        end
        Constraints = [Constraints, ...
            Pf(b) <= cap * Sw(b), ...
            Pf(b) >= -cap * Sw(b), ...
            Qf(b) <= cap * Sw(b), ...
            Qf(b) >= -cap * Sw(b)];
    end
    
    % 7. 切负荷状态约束
    for k = 1:nL
        states = shed_states{k};
        n_states = size(states, 1);
        
        % 唯一性约束：每个节点只能选择一种状态
        Constraints = [Constraints, sum(Z{k}) == 1];
        
        % 切负荷量等于所选状态的切负荷量
        shed_amount = 0;
        for s = 1:n_states
            shed_ratio = states(s, 2);
            shed_amount = shed_amount + Z{k}(s) * shed_ratio * P_free(k);
        end
        Constraints = [Constraints, L_shed(k) == shed_amount];
        
        % 非负约束
        Constraints = [Constraints, L_shed(k) >= 0, L_shed(k) <= P_free(k)];
    end
    
    % [优化4] 统一量纲的目标函数（元）
    
    % 成本1：VOLL成本（元）= VOLL(元/kW) × 切负荷(kW) × 时间(h)
    voll_cost = sum(voll_vec .* L_shed) * TAU_TIE_SW;
    
    % 成本2：CID惩罚成本（元）= 权重(元/h) × CID(h)
    % 简化：未恢复节点的CID更高
    cid_penalty = 0;
    for k = 1:nL
        node = load_nodes(k);
        is_supplied = sum(Sw .* (all_branches(:,2) == node));
        % 如果未供电，惩罚更大
        cid_penalty = cid_penalty + WEIGHT_CID * (1 - is_supplied) * TAU_TIE_SW;
    end
    
    % 成本3：开关动作成本（元）
    % 简化：统计闭合的联络线数量（假设正常状态全为0）
    switch_cost = SWITCHING_COST * sum(Sw(nB_norm+1:end));
    
    % 总目标函数
    Objective = WEIGHT_VOLL * voll_cost + cid_penalty + WEIGHT_SWITCHING * switch_cost;
    
    % [优化5] Gurobi参数优化
    options = sdpsettings('solver', 'gurobi', 'verbose', 0);
    options.gurobi.TimeLimit = TIME_LIMIT;
    options.gurobi.MIPGap = MIP_GAP;
    options.gurobi.Threads = THREADS;
    options.gurobi.Presolve = PRESOLVE;
    options.gurobi.Cuts = CUTS;
    options.gurobi.Heuristics = 0.05;
    options.gurobi.MIPFocus = 1;  % 侧重可行解
    
    % 求解
    sol = optimize(Constraints, Objective, options);
    
    % 提取结果
    if sol.problem == 0 || sol.problem == 3  % 成功或达到时间限制
        L_opt = value(L_shed);
        Pf_opt = value(Pf);
        Qf_opt = value(Qf);
        Vm_opt = value(Vm);
        Sw_opt = value(Sw);
        
        % 判断节点是否恢复（有供电）
        q_opt = zeros(nL, 1);
        for k = 1:nL
            node = load_nodes(k);
            is_supplied = sum(Sw_opt .* (all_branches(:,2) == node));
            q_opt(k) = (is_supplied > 0.5);
        end
        
        % 统计开关动作
        switch_count = sum(Sw_opt(nB_norm+1:end) > 0.5);
    else
        % 求解失败，返回空结果
        L_opt = zeros(nL, 1);
        Pf_opt = zeros(nB_all, 1);
        Qf_opt = zeros(nB_all, 1);
        Vm_opt = ones(num_nodes, 1) * V_src_sq;
        Sw_opt = zeros(nB_all, 1);
        q_opt = zeros(nL, 1);
        switch_count = 0;
    end
end

%% ── 辅助内联函数 ─────────────────────────────────────────────
function out = ternary(cond, a, b)
    if cond, out = a; else, out = b; end
end
