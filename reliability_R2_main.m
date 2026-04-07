%% ============================================================
%  配电网可靠性评估 —— R2 版本（含故障后最优网络重构）
%  通用于 85 / 137 / 417 / 1080 节点测试系统
%
%  代码结构:
%    §1  Testbench 数据读取（联络线位置、线路/变压器容量）
%    §2  可靠性参数读取（沿用 R1 reliability_universal_acc.m 格式）
%    §3  潮流参数生成（线路阻抗 r/x、负荷无功、电压上下限等）
%    §4  拓扑索引构建（节点-分支关联矩阵，含联络线）
%    §5  MCF 路径识别 → 确定受影响节点矩阵 p_mat（保留 R1 建模方式）
%    §6  逐故障 MILP（R2 Eq.2-13，DistFlow 潮流约束，向量化实现）
%    §7  可靠性指标计算（R2 Eq.28-33）
%    §8  结果输出（仿照 R1 格式）
%
%  参考文献:
%    [R1] Muñoz-Delgado et al., IEEE Trans. Smart Grid, 2018
%    [R2] Li et al., IEEE Trans. Power Syst., 2020
%
%  依赖: YALMIP + Gurobi
% =============================================================
clear; clc;

%% ============================================================
%  ★  用户配置区（仅需修改此处切换系统）  ★
% ============================================================
% 可靠性参数文件（与 R1 相同）
sys_filename = '85-Node System Data.xlsx';
%sys_filename = '137-Node System Data.xlsx';
%sys_filename = '417-Node System Data.xlsx';
%sys_filename = '1080-Node System Data.xlsx';

% Testbench 文件（联络线和容量数据）
tb_filename = ['Testbench for Linear Model Based Reliability Assessment Method for Distribution Optimization Models Considering Network Reconfiguration.xlsx'];

% 系统标识（对应 Testbench 中的 Sheet 名）
sys_sheet = '85-node';
%sys_sheet = '137-node';
%sys_sheet = '417-node';
%sys_sheet = '1080-node';

% 路径求解模式（§5 MCF 模块，与 R1 一致）
%   'MCF'    → 多商品流，一次性建模（推荐）
SOLVE_MODE = 'MCF';

% 电压约束（pu）— 参考 MATPOWER 标准配电测试系统设定
V_UPPER = 1.05;   % 上限（dist_opf_case33_ieee 典型值）
V_LOWER = 0.95;   % 下限
V_SRC   = 1.0;    % 变电站母线电压

% 功率因数假设（恒功率因数，与 R1 一致）
PF = 0.9;
% ============================================================

program_total = tic;

%% ================================================================
%  §1  Testbench 数据读取
%      来源: Testbench xlsx，各 Sheet 含联络线坐标和容量标注
%      使用 readcell 避免 readtable 对混合类型列自动转 double 的问题
% ================================================================
fprintf('>> [1/8] 读取 Testbench: Sheet="%s"\n', sys_sheet);

% readcell 始终返回元胞数组，不受列数据类型影响
tb_cell = readcell(tb_filename, 'Sheet', sys_sheet);
nrows_tb = size(tb_cell, 1);

% 定位表头行（首列含 'Tie-Switch' 字符串的行）
hdr_row = 0;
for ri = 1:nrows_tb
    val = tb_cell{ri, 1};
    if ischar(val) && contains(val, 'Tie-Switch')
        hdr_row = ri; break;
    end
end
if hdr_row == 0
    error('Testbench Sheet "%s" 中未找到 Tie-Switch 表头行。', sys_sheet);
end

% 读取容量标注（表头下一行第4列，格式 'X MW'）
cap_str  = string(tb_cell{hdr_row+1, 4});   % e.g. '5 MW'
LINE_CAP = str2double(extractBefore(cap_str, ' '));
TRAN_CAP = LINE_CAP;

% 读取联络线坐标（从表头+2行起，第1、2列为数字的行）
TIE_LINES_RAW = [];
for ri = hdr_row+2 : nrows_tb
    v1 = tb_cell{ri, 1};
    v2 = tb_cell{ri, 2};
    if isnumeric(v1) && ~isnan(v1) && isnumeric(v2) && ~isnan(v2)
        TIE_LINES_RAW(end+1, :) = [v1, v2]; %#ok<AGROW>
    end
end

fprintf('   线路容量=%.0f MW，联络线=%d 条\n', LINE_CAP, size(TIE_LINES_RAW,1));

%% ================================================================
%  §2  可靠性参数读取（完整保留 R1 代码的数据读取逻辑）
% ================================================================
fprintf('>> [2/8] 读取可靠性参数: %s\n', sys_filename);

t_branch = readtable(sys_filename, 'Sheet', 'Branch Lengths (km)');
t_branch = t_branch(:,1:3);
t_branch.Properties.VariableNames = {'From','To','Length_km'};
t_branch = t_branch(~isnan(t_branch.From), :);

t_dur = readtable(sys_filename, 'Sheet', 'Interruption durations (h)', 'HeaderLines', 3);
t_dur = t_dur(:,1:4);
t_dur.Properties.VariableNames = {'From','To','RP','SW'};
t_dur = t_dur(~isnan(t_dur.From), :);

t_cust = readtable(sys_filename, 'Sheet', 'Numbers of customers per node');
t_cust = t_cust(:,1:2);
t_cust.Properties.VariableNames = {'Node','NC'};
t_cust = t_cust(~isnan(t_cust.Node), :);

t_peak = readtable(sys_filename, 'Sheet', 'Peak Nodal Demands (kW)');
t_peak = t_peak(:,1:2);
t_peak.Properties.VariableNames = {'Node','P_kW'};
t_peak = t_peak(~isnan(t_peak.Node), :);

t_other = readtable(sys_filename, 'Sheet', 'Other data', 'ReadVariableNames', false);

col1 = cellfun(@(x) string(x), t_other{:,1}, 'UniformOutput', true);

row_fail      = find(contains(col1,'Failure rate'), 1);
lambda_per_km = str2double(string(t_other{row_fail, 2}));

row_dur_idx = find(contains(col1,'Duration'), 1);
T_l = [str2double(string(t_other{row_dur_idx,   3})), ...
       str2double(string(t_other{row_dur_idx+1, 3})), ...
       str2double(string(t_other{row_dur_idx+2, 3}))];

row_load = find(contains(col1,'Loading factors'), 1);
L_f = [str2double(string(t_other{row_load,   3})), ...
       str2double(string(t_other{row_load+1, 3})), ...
       str2double(string(t_other{row_load+2, 3}))] / 100;

fprintf('   lambda=%.4f, T_l=[%s]h, L_f=[%s]\n', ...
    lambda_per_km, num2str(T_l,'%g '), num2str(L_f,'%.2f '));

%% ================================================================
%  §3  潮流参数生成
%
%  导线型号 EFF & ERF（从 'Datos Líneas' 提取，统一适用四个系统）:
%    R_KM = 0.003151 pu/km，X_KM = 0.001526 pu/km
%    （已按各系统基准电压 VB 归一化，SB=1 MVA）
%  参考 MATPOWER dist_opf_case33_ieee 等标准配电测试系统:
%    电压约束: 0.95~1.05 pu
%    功率因数: 0.9（恒功率因数）
%    负荷无功: Q = P × tan(acos(0.9))
% ================================================================
fprintf('>> [3/8] 生成潮流参数...\n');

R_KM    = 0.003151;             % pu/km（实测自 Datos Líneas，EFF&ERF 导线）
X_KM    = 0.001526;             % pu/km
TAN_PHI = tan(acos(PF));        % Q/P ≈ 0.4843

V_src_sq   = V_SRC^2;
V_upper_sq = V_UPPER^2;
V_lower_sq = V_LOWER^2;
M_V = (V_upper_sq - V_lower_sq) * 2;   % 电压 Big-M (pu²)

fprintf('   R_km=%.4f, X_km=%.4f pu/km, tan(φ)=%.4f\n', R_KM, X_KM, TAN_PHI);
fprintf('   V∈[%.2f, %.2f] pu, LINE_CAP=%.0f MVA\n', V_LOWER, V_UPPER, LINE_CAP);

%% ================================================================
%  §4  节点/分支索引与拓扑构建
% ================================================================
fprintf('>> [4/8] 构建拓扑索引...\n');

raw_nodes = unique([t_branch.From; t_branch.To; TIE_LINES_RAW(:)]);
num_nodes = length(raw_nodes);
node_map  = containers.Map(raw_nodes, 1:num_nodes);
inv_map   = raw_nodes;

subs_raw = raw_nodes(~ismember(raw_nodes, t_cust.Node));
subs_idx = arrayfun(@(s) node_map(s), subs_raw);
fprintf('   节点总数=%d, 变电站=%s\n', num_nodes, mat2str(subs_raw'));

% ── 正常分支参数矩阵（8列）──
% [u_int, v_int, lambda_b, t_rp, t_sw, r_b(pu), x_b(pu), cap_b(MVA)]
nB_norm = height(t_branch);
nTie    = size(TIE_LINES_RAW, 1);
nB_all  = nB_norm + nTie;

rel_branches = zeros(nB_norm, 8);
for b = 1:nB_norm
    u_raw = t_branch.From(b); v_raw = t_branch.To(b);
    u = node_map(u_raw);      v = node_map(v_raw);
    len = t_branch.Length_km(b);
    match = (t_dur.From==u_raw & t_dur.To==v_raw) | ...
            (t_dur.From==v_raw & t_dur.To==u_raw);
    if ~any(match)
        error('找不到分支(%d-%d)的停电时间数据。', u_raw, v_raw);
    end
    is_trf = ismember(u, subs_idx) | ismember(v, subs_idx);
    cap_b  = TRAN_CAP*is_trf + LINE_CAP*(~is_trf);
    rel_branches(b,:) = [u, v, len*lambda_per_km, ...
                         t_dur.RP(match), t_dur.SW(match), ...
                         R_KM*len, X_KM*len, cap_b];
end

% ── 联络线附加行（lambda=0，不参与可靠性统计）──
tie_branches = zeros(nTie, 8);
for t = 1:nTie
    u = node_map(TIE_LINES_RAW(t,1)); v = node_map(TIE_LINES_RAW(t,2));
    len_tie = 0.1;   % 缺省联络线长度（km），对容量约束无影响
    tie_branches(t,:) = [u, v, 0, 0, 0, R_KM*len_tie, X_KM*len_tie, LINE_CAP];
end

all_branches = [rel_branches; tie_branches];
branch_from  = all_branches(:,1);   % nB_all×1
branch_to    = all_branches(:,2);
r_b_all      = all_branches(:,6);
x_b_all      = all_branches(:,7);
cap_b_all    = all_branches(:,8);

load_nodes = setdiff(1:num_nodes, subs_idx);
nL = length(load_nodes);
free_nodes = setdiff(1:num_nodes, subs_idx);
nFree      = length(free_nodes);
non_sub    = free_nodes;   % 非变电站节点（别名，用于电压约束）

% ── 节点-分支关联矩阵 ──
%    A_inc(i,b)=+1 → 节点 i 是分支 b 的 to 端（流入）
%               =-1 → 节点 i 是分支 b 的 from 端（流出）
A_inc_norm = sparse(rel_branches(:,2), 1:nB_norm, +1, num_nodes, nB_norm) + ...
             sparse(rel_branches(:,1), 1:nB_norm, -1, num_nodes, nB_norm);
A_inc_all  = sparse(branch_to, 1:nB_all, +1, num_nodes, nB_all) + ...
             sparse(branch_from, 1:nB_all, -1, num_nodes, nB_all);

A_free_norm = A_inc_norm(free_nodes, :);
A_free_all  = A_inc_all(free_nodes, :);

% ── 分支-节点投影矩阵（向量化电压方程的核心）──
%    B_to(b, to(b)) = 1;  B_from(b, from(b)) = 1
%    delta_V = (B_to-B_from)*v + 2*(r.*P+x.*Q)：对所有分支一次性建立
B_to_all   = sparse(1:nB_all, branch_to,   1, nB_all, num_nodes);
B_from_all = sparse(1:nB_all, branch_from, 1, nB_all, num_nodes);

% ── 节点有功/无功需求（峰值，pu）──
P_demand_node = zeros(num_nodes, 1);
Q_demand_node = zeros(num_nodes, 1);
for k = 1:nL
    id = inv_map(load_nodes(k));
    idx_p = find(t_peak.Node == id, 1);
    if ~isempty(idx_p) && ~isnan(t_peak.P_kW(idx_p))
        p_pu = t_peak.P_kW(idx_p) / 1e3;
        P_demand_node(load_nodes(k)) = p_pu;
        Q_demand_node(load_nodes(k)) = p_pu * TAN_PHI;
    end
end
P_free = P_demand_node(free_nodes);   % nFree×1
Q_free = Q_demand_node(free_nodes);

% free_nodes 中各负荷节点的行位置（供 D_mat 和 rhs 构造）
[~, target_in_free] = ismember(load_nodes, free_nodes);

fprintf('   正常分支=%d, 联络线=%d, 负荷节点=%d\n', nB_norm, nTie, nL);

%% ================================================================
%  §5  MCF 路径识别（保留 R1 的多商品流建模方式）
%
%  求解仅针对正常分支（nB_norm 条），与 R1 完全一致
%  f_res(b,k)=1 → 正常分支 b 位于节点 k 的供电路径上
%  p_mat = f_res'  → p_mat(k,xy)=1 ↔ 节点 k 受故障 xy 影响
% ================================================================
fprintf('>> [5/8] MCF 路径识别 (模式: %s)...\n', SOLVE_MODE);
t_mcf = tic;

D_mat = sparse(target_in_free, 1:nL, 1, nFree, nL);

if strcmp(SOLVE_MODE, 'MCF')
    F_mat = sdpvar(nB_norm, nL, 'full');
    Z_mat = sdpvar(nB_norm, nL, 'full');
    C_mcf = [-Z_mat <= F_mat, F_mat <= Z_mat, Z_mat >= 0, ...
              A_free_norm * F_mat == D_mat];
    opts_mcf = sdpsettings('solver','cplex','verbose',0);
    sol = optimize(C_mcf, sum(sum(Z_mat)), opts_mcf);
    if sol.problem ~= 0, warning('MCF 求解异常: %s', sol.info); end
    f_res = sparse(abs(value(F_mat)) > 0.5);

else  % SINGLE + parfor
    f_res    = false(nB_norm, nL);
    opts_sp  = sdpsettings('solver','cplex','verbose',0);
    parfor k = 1:nL
        d_k = sparse(target_in_free(k), 1, 1, nFree, 1);
        f_k = sdpvar(nB_norm, 1);
        z_k = sdpvar(nB_norm, 1);
        C_k = [-z_k <= f_k, f_k <= z_k, z_k >= 0, A_free_norm*f_k == d_k];
        optimize(C_k, sum(z_k), opts_sp);
        f_res(:,k) = abs(value(f_k)) > 0.5;
    end
    f_res = sparse(f_res);
end

% p_mat(k,xy)=1 ↔ 故障分支 xy 在节点 k 的供电路径上
p_mat = f_res';   % nL×nB_norm（稀疏）
t_mcf_elapsed = toc(t_mcf);
fprintf('   MCF 完成，耗时 %.1f 秒\n', t_mcf_elapsed);

%% ================================================================
%  §6  逐故障 MILP — R2 Eq.(2)-(13) DistFlow 潮流约束
%
%  对每条正常分支 xy 发生故障，求解最大化可恢复负荷 MILP
%  变量: s(nB_all×1)二进制，q(nL×1)二进制，P/Q(nB_all×1)，v(N×1)
%
%  ── DistFlow 潮流约束（向量化，优化自原框架逐节点 for 循环）──
%
%  [Eq.2]  功率平衡（向量化关联矩阵形式）
%          原框架 Distflow_linear_opf 逐节点调用 SearchNodeConnection
%          → 用 A_free_all 一次性表达所有非变电站节点的平衡方程
%          A_free_all * P = P_free .* q_ext  （有功）
%          A_free_all * Q = Q_free .* q_ext  （无功）
%          其中 q_ext(pos_k) = q(k)（负荷节点），= 0（转供中间节点）
%
%  [Eq.3]  线性化电压降落（向量化投影矩阵形式）
%          原框架约束(1.5): v_j=v_i-2(R·P+X·Q)+(R²+X²)·i²  含 i² 项
%          → R2 线性化：去掉 i² 项，改 Big-M 不等式对
%          原框架逐分支 for 循环 + find_line_num_adapted 索引
%          → 用 B_to_all-B_from_all 投影矩阵一次性对所有 nB_all 条分支建立
%          delta(b)=(B_to-B_from)(b,:)*v + 2*(r_b*P_b+x_b*Q_b) ∈ [-M*(1-s_b), M*(1-s_b)]
%
%  [Eq.4-6]  电压约束（变电站固定 + 节点上下限）
%  [Eq.7-10] 支路容量约束（Big-M 耦合开关状态）
%  [Eq.11]   辐射约束: sum(s) = sum(q)
%  [Eq.12]   故障分支强制断开: s(xy)=0
%  [Eq.13]   未受影响节点强制恢复: q(k)=1 ∀ p(k)=0
% ================================================================
fprintf('>> [6/8] 批量场景 MILP（%d 场景，矩阵建模）...\n', nB_norm);
t_milp = tic;

nScen   = nB_norm;
p_mat_d = double(p_mat);   % nL×nScen（§5 已计算）

%% 预计算对角矩阵（稀疏，避免密集矩阵乘法）
Dr  = spdiags(r_b_all,   0, nB_all, nB_all);   % 电阻对角阵
Dx  = spdiags(x_b_all,   0, nB_all, nB_all);   % 电抗对角阵
Dp  = spdiags(P_free,    0, nFree,  nFree);     % 有功需求对角阵
Dq_ = spdiags(Q_free,    0, nFree,  nFree);     % 无功需求对角阵
Cap = spdiags(cap_b_all, 0, nB_all, nB_all);   % 容量对角阵
BdV = B_to_all - B_from_all;                   % nB_all×N 电压差矩阵

%% 批量决策变量（列 = 场景，与 MCF 中 F_mat/Z_mat 相同范式）
S_mat  = binvar(nB_all,    nScen, 'full');   % 分支开关
Q_mat  = binvar(nL,        nScen, 'full');   % 节点恢复
Pf_mat = sdpvar(nB_all,    nScen, 'full');   % 有功潮流
Qf_mat = sdpvar(nB_all,    nScen, 'full');   % 无功潮流
V_mat  = sdpvar(num_nodes, nScen, 'full');   % 节点电压平方

C = [];

%% Eq(4): 变电站电压固定（对所有场景列）
C = [C, V_mat(subs_idx, :) == V_src_sq];

%% Eq(5)(6): 节点电压上下限（对所有场景列）
C = [C, V_lower_sq <= V_mat(non_sub, :) <= V_upper_sq];

%% Eq(7-10): 容量约束 + Big-M（Cap 对角矩阵逐行缩放，等价于 cap_b.*s 逐元素）
C = [C, -Cap*S_mat <= Pf_mat <= Cap*S_mat];
C = [C, -Cap*S_mat <= Qf_mat <= Cap*S_mat];

%% Eq(2): LinDistFlow 有功功率平衡
%  A_free_all*Pf_mat: 各场景各节点的净有功流入
%  Dp*Q_mat:          各场景各节点的恢复需求（P_free(i)*Q_mat(i,xy)）
C = [C, A_free_all * Pf_mat == Dp  * Q_mat];

%% Eq(3): LinDistFlow 无功功率平衡
C = [C, A_free_all * Qf_mat == Dq_ * Q_mat];

%% Eq(4): 线性化电压降落 + Big-M（nB_all×nScen 矩阵不等式）
%  delta_mat(b,xy) = v_{to(b),xy}-v_{from(b),xy} + 2*(r_b*P_{b,xy}+x_b*Q_{b,xy})
delta_mat = BdV*V_mat + 2*(Dr*Pf_mat + Dx*Qf_mat);
C = [C, delta_mat <=  M_V*(1 - S_mat)];
C = [C, delta_mat >= -M_V*(1 - S_mat)];


%% Eq(11): 辐射运行约束（列和：各场景投入分支数 = 恢复节点数）
C = [C, sum(S_mat, 1) == sum(Q_mat, 1)];

%% Eq(12): 故障分支强制断开（对角线元素）
%  场景 xy 中第 xy 条正常分支断开: S_mat(xy,xy)=0
%  线性索引: (xy-1)*nB_all + xy，与 sub2ind([nB_all,nScen],1:nB_norm,1:nB_norm) 等价
fault_lin_idx = (0:nB_norm-1)*nB_all + (1:nB_norm);   % 1×nB_norm
C = [C, S_mat(fault_lin_idx) == 0];

%% Eq(13): 未受影响节点强制恢复（矩阵不等式，p=0→q≥1，p=1→无额外约束）
C = [C, Q_mat >= 1 - p_mat_d];

%% 求解（目标: 最大化所有场景恢复节点总数）
opts_milp = sdpsettings('solver','cplex','verbose',0);
sol = optimize(C, -sum(sum(Q_mat)), opts_milp);

if sol.problem == 0
    q_mat = logical(round(value(Q_mat)));   % nL×nScen
else
    warning('[§6] 批量 MILP 失败: %s，退化为 R1（无重构）', sol.info);
    q_mat = logical(1 - p_mat_d);          % 保守退化：仅未受影响节点标为恢复
end

t_milp_elapsed = toc(t_milp);
fprintf('   批量 MILP 完毕，耗时 %.1f 秒\n', t_milp_elapsed);

fprintf('>> [7/8] 计算可靠性指标...\n');

lam = rel_branches(:,3);
trp = rel_branches(:,4);
tsw = rel_branches(:,5);

p_mat_d  = double(p_mat);
q_mat_d  = double(q_mat);

CIF = p_mat_d * lam;                                    % nL×1 [Eq.28]
CID = p_mat_d * (lam .* tsw) ...
    + (p_mat_d .* (1 - q_mat_d)) * (lam .* (trp - tsw)); % nL×1 [Eq.29]
%
%  修正说明: 原式 (p_mat_d - q_mat_d) 会在 p=0,q=1（Eq.13 强制恢复）
%  的位置产生 -1，导致 CID 出现负值。
%  正确形式 p_mat_d .* (1-q_mat_d) 仅统计"受影响(p=1)且未恢复(q=0)"
%  的节点-故障对，p=0 的位置结果恒为 0，物理含义准确。

%% 客户数与平均功率
NC_vec    = zeros(1, nL);
P_avg_vec = zeros(1, nL);

%  R2可靠性指标
for k = 1:nL
    id    = inv_map(load_nodes(k));
    idx_c = find(t_cust.Node == id, 1);
    if ~isempty(idx_c), NC_vec(k) = t_cust.NC(idx_c); end

    idx_p = find(t_peak.Node == id, 1);
    if ~isempty(idx_p)
        pp = t_peak.P_kW(idx_p);
        if ~isnan(pp)
            P_avg_vec(k) = pp * sum(L_f .* (T_l / 8760));
        end
    end
end

total_cust  = sum(NC_vec);
SAIFI       = sum(NC_vec .* CIF')  / total_cust;
SAIDI       = sum(NC_vec .* CID')  / total_cust;
System_EENS = sum(P_avg_vec .* CID') / 1e3;   % kWh/年 → MWh/年
ASAI        = 1 - SAIDI / 8760;

%  R1可靠性指标 
N_RP      = p_mat_d * lam;   % 1×nL  修复中断频率
D_RP = p_mat_d * (lam .* trp);
D_SW_path = p_mat_d * (lam.*tsw);   % 1×nL  路径开关时间（中间量）

N_SW = zeros(nL,1);
D_SW = zeros(nL,1);

for k = 1:nL
    % 找节点 k 路径上连接变电站的出口分支
    path_br = find(f_res(:,k));
    cb_idx  = [];
    for bi = path_br'
        if ismember(rel_branches(bi,1), subs_idx) || ismember(rel_branches(bi,2), subs_idx)
            cb_idx = bi; break;
        end
    end
    if isempty(cb_idx), continue; end

    feeder_mask = any(f_res(cb_idx, :), 1);            % 1×nL logical：哪些节点共享此出口
    feeder_br   = any(f_res(:, feeder_mask), 2);       % B×1 logical：馈线上的所有分支

    N_SW(k) = sum(lam(feeder_br))                  - N_RP(k);
    D_SW(k) = sum(lam(feeder_br) .* tsw(feeder_br)) - D_SW_path(k);
end

CIF_R1 = N_RP + N_SW;
CID_R1 = D_RP + D_SW;

SAIFI_R1       = sum(NC_vec .* CIF_R1')  / total_cust;
SAIDI_R1    = sum(NC_vec .* CID_R1') / total_cust;
EENS_R1     = sum(P_avg_vec .* CID_R1') / 1e3;
ASAI_R1        = 1 - SAIDI_R1 / 8760;

%% 重构统计
n_affected  = full(sum(p_mat_d(:) > 0));
n_recovered = sum((q_mat_d(:) - (1-p_mat_d(:))) > 0);
rec_pct     = n_recovered / max(n_affected,1) * 100;

%% ================================================================
%  §8  结果输出（仿照 R1 reliability_universal_acc.m 格式）
% ================================================================
total_elapsed = toc(program_total);
fprintf('\n╔══════════════════════════════════════╗\n');
fprintf('  系统文件: %-27s \n', sys_filename);
fprintf('║  配电网可靠性评估结果 [R2 含重构]     ║\n');
fprintf('╠══════════════════════════════════════╣\n');
fprintf('║  [R2] SAIFI : %10.4f  次/(户·年)║\n', SAIFI);
fprintf('║  [R2] SAIDI : %10.4f  h/(户·年) ║\n', SAIDI);
fprintf('║  [R2] EENS  : %10.2f  MWh/年    ║\n', System_EENS);
fprintf('║  [R2] ASAI  : %12.6f          ║\n', ASAI);
fprintf('║  配电网可靠性评估结果 [R1 不含重构]     ║\n');
fprintf('╠══════════════════════════════════════╣\n');
fprintf('║  [R2] SAIFI : %10.4f  次/(户·年)║\n', SAIFI_R1);
fprintf('║  [R1] SAIDI : %10.4f  h/(户·年)║\n', SAIDI_R1);
fprintf('║  [R1] EENS  : %10.2f  MWh/年║\n', EENS_R1);
fprintf('║  [R2] ASAI  : %12.6f          ║\n', ASAI_R1);
fprintf('╠══════════════════════════════════════╣\n');
fprintf('║  SAIFI改善  : %10.4f 次/(户·年)        \n', SAIFI_R1-SAIFI);
fprintf('║  SAIDI改善  : %10.4f h/(户·年)      \n', SAIDI_R1-SAIDI);
fprintf('║  EENS改善   : %10.2f MWh/yr      \n', EENS_R1-System_EENS);
fprintf('║  重构恢复率 : %.1f%% (%d/%d)        \n', rec_pct, n_recovered, n_affected);
fprintf('╠══════════════════════════════════════╣\n');
fprintf('║  联络线数量 : %-5d 容量: %-6.0f MW  \n', nTie, LINE_CAP);
fprintf('║  负荷节点数 : %-5d 故障场景: %-6d   \n', nL, nB_norm);
fprintf('╠══════════════════════════════════════╣\n');
fprintf('║  §5 MCF路径识别: %7.1f 秒         \n', t_mcf_elapsed);
fprintf('║  §6 MILP重构  : %7.1f 秒         \n', t_milp_elapsed);
fprintf('║  总运行时间   : %7.1f 秒         \n', total_elapsed);
fprintf('╚══════════════════════════════════════╝\n');
fprintf('   求解模式: %s\n', SOLVE_MODE);