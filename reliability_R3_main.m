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

non_ref = setdiff((1:nb)', ref);   % column vector of non-root bus indices

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

% p_mat(k,xy)=1 ↔ 故障分支 xy 在节点 k 的供电路径上（仅下游节点）
% 即 R1 中 N_RP 贡献的节点集合 = "直接受影响节点 (p_direct)"
p_mat = f_res';   % nL×nB_norm（稀疏）

%% ── 计算 p_feeder_mat（馈线级停电指示矩阵）──────────────────────────
%
%  [为什么需要 p_feeder_mat]
%  当分支 xy 故障时，馈线出口断路器跳闸，整条馈线所有节点均暂时停电：
%    类型①  xy 下游节点（p_mat=1）:      τ=τ^RP，或经重构缩短 → 需 MILP 求解
%    类型②  xy 上游的同馈线节点（p_mat=0）: τ=τ^SW，开关操作后自动恢复
%
%  当前代码仅用 p_mat（下游）计算 CIF/CID：
%    CIF_R2(当前) = p_mat * λ = N_RP（缺少②类的 N_SW 贡献）
%    → CIF_R1 - CIF_R2 = N_SW  ← 与观测到的现象完全一致
%
%  修正：
%    p_feeder_mat → §7 中 CIF 和 CID 的 τ^SW 基础项（馈线级全部节点）
%    p_mat        → §6 MILP Eq(13)（确定哪些节点需要重构，保持不变）
%
%  p_feeder_mat(k,xy) = 1  ↔  节点 k 与分支 xy 在同一条馈线上

p_feeder_mat = false(nL, nB_norm);
for xy = 1:nB_norm
    % 找 xy 的任一下游节点，用来定位该故障属于哪条馈线
    dn_k = find(p_mat(:, xy), 1);
    if isempty(dn_k), continue; end

    % 沿供电路径找馈线出口分支（与变电站直接相连的那条分支）
    path_br = find(f_res(:, dn_k));
    cb_idx  = [];
    for bi = path_br'
        if ismember(rel_branches(bi,1), subs_idx) || ...
           ismember(rel_branches(bi,2), subs_idx)
            cb_idx = bi; break;
        end
    end
    if isempty(cb_idx), continue; end

    % 该出口分支服务的所有节点 = 同一馈线的全部负荷节点
    p_feeder_mat(:, xy) = full(any(f_res(cb_idx, :), 1))';
end
p_feeder_mat = sparse(p_feeder_mat);
fprintf('   p_direct nnz=%d  p_feeder nnz=%d  (差=%d = N_SW来源节点数)\n', ...
    nnz(p_mat), nnz(p_feeder_mat), nnz(p_feeder_mat)-nnz(p_mat));

t_mcf_elapsed = toc(t_mcf);
fprintf('   MCF+馈线指示矩阵完成，耗时 %.1f 秒\n', t_mcf_elapsed);

%% ================================================================
%  §6  批量场景 MILP — 参照 Distflow_linear_opf.m 重写 LinDistFlow 约束
%
%  变量（每列 = 一个故障场景，共 nScen=nB_norm 列，与 MCF 矩阵范式一致）:
%    S_mat  (nB_all×nScen) binary  分支开关状态（0=开路 / 1=合路）
%    Q_mat  (nL×nScen)     binary  负荷节点恢复状态
%    Pf_mat (nB_all×nScen) cont.   有功潮流（from→to 为正，可为负）
%    Qf_mat (nB_all×nScen) cont.   无功潮流（同上）
%    V_mat  (N×nScen)      cont.   节点电压平方 (pu²)
%
%  ── LinDistFlow 约束体系（严格对照 Distflow_linear_opf.m）──
%
%  [ref C4 / R2-Eq.4]  变电站电压固定:
%      V_mat(subs,:) = V_src²
%
%  [ref C3 / R2-Eq.5-6]  节点电压上下限（条件 Big-M，修正恢复率 0% 的 Bug）:
%      参考原型: Vmin² ≤ v ≤ Vmax²  （硬约束，reference 中所有节点均供电）
%      可靠性场景中 q=0 节点无供电，电压变量无物理意义，硬约束使重构路径不可行：
%        经联络线供电路径更长 → 电压降落更大 → v<V_lower → 约束违反 → q=0
%        → 这正是恢复率 0% 的根本原因
%      修正：仅对供电节点（q=1）施加电压限制，未供电节点（q=0）自动松弛:
%        v(j) ≥ V_lower² - M_vn·(1-q_j)   [q=1: 下限生效; q=0: 约束≥负数, 自动满足]
%        v(j) ≤ V_upper² + M_vn·(1-q_j)   [q=1: 上限生效; q=0: 约束≥2V_upper², 宽松]
%      取 M_vn = V_upper_sq 足以松弛 q=0 节点的约束
%
%  [ref C5/Eq.34-35 / R2-Eq.2]  有功/无功功率平衡（lossless，无 r·l/x·l 项）:
%      参考原型: A_bal * Pline = Pbus(non_ref)  其中 Pbus(j)=-Pd(j)（负荷节点）
%      等价形式（本代码 A_inc 符号约定：to 端=+1，from 端=-1）:
%        A_free_all * Pf_mat = Dp * Q_mat   （有功, nFree×nScen 矩阵等式）
%        A_free_all * Qf_mat = Dq * Q_mat   （无功）
%      其中 Dp = diag(P_free), Dq = diag(Q_free)；
%      Dp*Q_mat(i,xy) = P_free(i)*Q_mat(i,xy) 为线性乘积（常数×binvar）
%      验证等价性: A_inc(j,b)=+1 when to(b)=j → (flow_in - flow_out) = Pd·q ✓
%
%  [ref C5/Eq.36 / R2-Eq.3]  线性电压降落（无 (r²+x²)·l 二次项）:
%      参考原型（固定辐射树）: D_v·v + 2·(W_r·P + W_x·Q) = 0  （等式）
%      可重构拓扑（开关可变）: 改为 Big-M 不等式，s=0 时自动松弛
%        delta(b) = v(to_b) - v(from_b) + 2·(r_b·P_b + x_b·Q_b)
%        s_b=1: delta(b) ∈ [0,0]（电压降落方程成立）
%        s_b=0: delta(b) ∈ [-M_V, M_V]（松弛；P_b=Q_b=0 由容量约束保证）
%      矩阵形式: BdV·V_mat + 2·(Dr·Pf + Dx·Qf) ∈ [-M_V·(1-S), M_V·(1-S)]
%      其中 BdV = B_to_all - B_from_all（B_to(b,to(b))=1，B_from(b,from(b))=1）
%
%  [R2-Eq.7-10]  容量约束: -cap_b·s_b ≤ P_b ≤ cap_b·s_b（同 Q）
%  [R2-Eq.11]   辐射约束: Σ_b s_b = Σ_k q_k  (per scenario)
%  [R2-Eq.12]   故障断路: S_mat(xy,xy) = 0
%  [R2-Eq.13]   强制恢复: Q_mat ≥ 1 - p_mat_d  (p=0 → q≥1)
%  目标: max Σ_{xy,k} q^xy_k  ↔  min -sum(sum(Q_mat))
% ================================================================
fprintf('>> [6/8] 批量场景 MILP（%d 场景，参照 Distflow_linear_opf 建模）...\n', nB_norm);
t_milp = tic;

nScen    = nB_norm;
p_mat_d  = double(p_mat);   % nL×nScen，保留用于 Eq(13) 和 §7 τ^RP-τ^SW 项

%% 预计算稀疏对角矩阵（与 reference 中 W_r/W_x/A_bal 同功能，但对可重构拓扑更通用）
Dr  = spdiags(r_b_all,   0, nB_all, nB_all);   % 电阻对角阵（对应 ref W_r）
Dx  = spdiags(x_b_all,   0, nB_all, nB_all);   % 电抗对角阵（对应 ref W_x）
Dp  = spdiags(P_free,    0, nFree,  nFree);     % 有功需求对角阵
Dq_ = spdiags(Q_free,    0, nFree,  nFree);     % 无功需求对角阵
Cap = spdiags(cap_b_all, 0, nB_all, nB_all);   % 容量对角阵
BdV = B_to_all - B_from_all;                   % nB_all×N 电压差矩阵（对应 ref D_v 的分支维度版本）

M_vn = V_upper_sq;   % 节点电压条件约束的 Big-M 值（≥ V_upper_sq - V_lower_sq 即可）

%% 批量决策变量（列维度 = 场景，与 MCF 中 F_mat/Z_mat 相同范式）
S_mat  = binvar(nB_all,    nScen, 'full');   % 分支开关状态
Q_mat  = binvar(nL,        nScen, 'full');   % 负荷节点恢复状态
Pf_mat = sdpvar(nB_all,    nScen, 'full');   % 有功潮流（有符号）
Qf_mat = sdpvar(nB_all,    nScen, 'full');   % 无功潮流（有符号）
V_mat  = sdpvar(num_nodes, nScen, 'full');   % 节点电压平方

C = [];

%% [ref C4] 变电站电压固定（nSubs×nScen）
C = [C, V_mat(subs_idx, :) == V_src_sq];

%% [ref C3 修正] 节点电压条件约束（Big-M 松弛，仅对供电节点 q=1 生效）
%
%  关键：Q_mat(k,xy) 与 V_mat(non_sub(k),xy) 行对应一致
%  因为 load_nodes = free_nodes = non_sub（均为 setdiff(1:N, subs_idx)），nL=nFree
%
C = [C, V_mat(non_sub,:) >= V_lower_sq - M_vn*(1 - Q_mat)];  % 下限条件约束
C = [C, V_mat(non_sub,:) <= V_upper_sq + M_vn*(1 - Q_mat)];  % 上限条件约束
%  验证：q=1 → v ∈ [V_lower_sq, V_upper_sq]（正常电压限制）✓
%        q=0 → 下限 ≤ v（trivially satisfied, V_lower_sq - M_vn < 0）✓
%              v ≤ 2·V_upper_sq（宽松）✓

%% [R2-Eq.7-10] 容量约束（Cap 对角矩阵：Cap*S_mat(b,:) = cap_b * S_mat(b,:)）
C = [C, -Cap*S_mat <= Pf_mat <= Cap*S_mat];
C = [C, -Cap*S_mat <= Qf_mat <= Cap*S_mat];

% (C1) Bus injection definition
C = [C;  Pbus + Pd - Cg * Pg == 0];
C = [C;  Qbus + Qd - Cg * Qg == 0];

% (C2) Generator capacity limits
C = [C;  Pgmin <= Pg <= Pgmax];
C = [C;  Qgmin <= Qg <= Qgmax];

%% [ref C5/Eq.34 / R2-Eq.2a] 有功功率平衡（lossless, nFree×nScen）
%  A_free_all·Pf_mat = Dp·Q_mat
%  展开：∀节点 j，∀场景 xy:  flow_in(j) - flow_out(j) = P_free(j)·q(j,xy)
C = [C, A_free_all * Pf_mat == Pbus(non_ref) * Q_mat];

%% [ref C5/Eq.35 / R2-Eq.2b] 无功功率平衡（lossless）
C = [C, A_free_all * Qf_mat == Qbus(non_ref) * Q_mat];

is_ref_from   = (tree_from_bus == ref);
ref_child_ids = br(is_ref_from);

C = [C;  Pbus(ref) == sum(Pline(ref_child_ids))];   %#ok<AGROW>
C = [C;  Qbus(ref) == sum(Qline(ref_child_ids))];   %#ok<AGROW>

%% [ref C5/Eq.36 / R2-Eq.3] 线性电压降落 + Big-M（nB_all×nScen 矩阵不等式）
%  delta(b,xy) = v(to_b,xy) - v(from_b,xy) + 2·(r_b·P(b,xy) + x_b·Q(b,xy))
%  s=1: delta ∈ [-M_V·0, M_V·0] = 0 → 电压方程精确成立
%  s=0: delta ∈ [-M_V, M_V]         → 约束松弛（P=Q=0 由容量约束保证）
delta_mat = BdV*V_mat + 2*(Dr*Pf_mat + Dx*Qf_mat);   % nB_all×nScen
C = [C, delta_mat <=  M_V*(1 - S_mat)];
C = [C, delta_mat >= -M_V*(1 - S_mat)];

%% [R2-Eq.11] 辐射运行约束（每场景列：投入分支数 = 恢复节点数）
C = [C, sum(S_mat, 1) == sum(Q_mat, 1)];

%% [R2-Eq.12] 故障分支强制断开（批量：对角线元素）
%  场景 xy 中第 xy 条正常分支断开：S_mat(xy,xy)=0
%  线性索引：S_mat 按列优先存储，S_mat(i,j) 的线性索引 = (j-1)*nB_all + i
fault_lin_idx = (0:nB_norm-1)*nB_all + (1:nB_norm);   % 1×nB_norm
C = [C, S_mat(fault_lin_idx) == 0];

%% [R2-Eq.13] 未受影响节点强制恢复（下游外的节点，矩阵不等式）
%  p=0 → q ≥ 1；p=1 → 无额外约束（由优化器自由选择）
C = [C, Q_mat >= 1 - p_mat_d];

%% 求解
opts_milp = sdpsettings('solver','gurobi','verbose',0, ...
    'gurobi.MIPGap', 1e-3, 'gurobi.TimeLimit', 600);
sol = optimize(C, -sum(sum(Q_mat)), opts_milp);

if sol.problem == 0
    q_mat = logical(round(value(Q_mat)));   % nL×nScen
else
    warning('[§6] MILP 求解失败: %s，退化为 R1（q=未受影响节点）', sol.info);
    q_mat = logical(1 - p_mat_d);
end

t_milp_elapsed = toc(t_milp);
fprintf('   批量 MILP 完毕，耗时 %.1f 秒\n', t_milp_elapsed);

fprintf('>> [7/8] 计算可靠性指标...\n');

lam = rel_branches(:,3);   % nB_norm×1 故障率 (次/年)
trp = rel_branches(:,4);   % nB_norm×1 修复时间 τ^RP (h)
tsw = rel_branches(:,5);   % nB_norm×1 开关时间 τ^SW (h)

p_direct_d  = double(p_mat);        % nL×nB_norm 仅下游节点（来自 MCF）
p_feeder_d  = double(p_feeder_mat); % nL×nB_norm 馈线级全部节点（含上游同馈线）
q_mat_d     = double(q_mat);        % nL×nB_norm 重构恢复状态（来自 MILP）

%% [R2 Eq.28] CIF：中断频率（用馈线级指示 p_feeder，包含 τ^SW 型中断）
CIF = p_feeder_d * lam;   % nL×1

%% [R2 Eq.29] CID：中断持续时间（两项之和）
%
%  推导（分支 xy 故障时，节点 k 的停电时长贡献）：
%    p_feeder=1, p_direct=0 (上游同馈线): τ = τ^SW              → 仅第①项
%    p_feeder=1, p_direct=1, q=1 (重构恢复): τ = τ^SW            → 仅第①项
%    p_feeder=1, p_direct=1, q=0 (未恢复):  τ = τ^SW+(τ^RP-τ^SW) → 两项之和
%    p_feeder=0 (其他馈线): τ = 0
%
%  ①  τ^SW 基础项: p_feeder_d * (λ·τ^SW)          （所有馈线级停电节点）
%  ②  额外修复等待: p_direct_d.*(1-q)*(λ·(τ^RP-τ^SW))（仅下游且未恢复节点）
%
%  说明：原式 (p_mat_d - q_mat_d)*(λ·(τ^RP-τ^SW)) 存在两个 Bug：
%    Bug A: p_mat→p_direct 用于τ^SW项时，缺漏上游同馈线节点的 τ^SW 贡献
%    Bug B: p=0,q=1（Eq.13强制恢复）→ p-q = -1 → CID 出现负值

CID = p_feeder_d * (lam .* tsw) ...
    + (p_direct_d .* (1 - q_mat_d)) * (lam .* (trp - tsw));   % nL×1

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

%% R1 基准（无重构）
%  CIF_R1 = p_feeder_d * λ                （馈线级中断频率 = N_RP + N_SW）
%  CID_R1 = p_feeder_d*(λ·τ^SW) + p_direct_d*(λ·(τ^RP-τ^SW))
%         = R2 令 q≡0 时的退化情形（无任何重构恢复）
%  与原 R1 代码（N_RP+N_SW, D_RP+D_SW 循环）数值等价，但向量化实现更简洁
CIF_R1 = p_feeder_d * lam;
CID_R1 = p_feeder_d * (lam .* tsw) + p_direct_d * (lam .* (trp - tsw));

SAIFI_R1       = sum(NC_vec .* CIF_R1')  / total_cust;
SAIDI_R1    = sum(NC_vec .* CID_R1') / total_cust;
EENS_R1     = sum(P_avg_vec .* CID_R1') / 1e3;
ASAI_R1        = 1 - SAIDI_R1 / 8760;

%% 重构统计
%  n_affected  = p_direct=1 的节点-故障对总数（下游受直接影响，需要重构）
%  n_recovered = p_direct=1 且 q=1（成功经重构恢复）
n_affected  = full(sum(p_direct_d(:) > 0));
n_recovered = full(sum((p_direct_d(:) .* q_mat_d(:)) > 0));
rec_pct     = n_recovered / max(n_affected, 1) * 100;

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