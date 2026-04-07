%% ============================================================
%  配电网可靠性评估 —— R2 版本（含故障后最优网络重构）
%  通用于 85 / 137 / 417 / 1080 节点测试系统
%
%  §1  Testbench 数据读取（联络线位置、容量）
%  §2  可靠性参数读取（故障率、停电时间、负荷、客户数）
%  §3  潮流参数生成（线路阻抗、电压约束）
%  §4  拓扑索引构建（关联矩阵，含联络线；区分设备类型故障率）
%  §5  MCF 路径识别 → p_mat / p_feeder_mat
%  §6  批量场景 MILP（LinDistFlow 最优重构，R2 Eq.2-13）
%  §7  可靠性指标计算（R2 Eq.28-29）
%  §8  结果输出（可靠性指标 + 重构后潮流信息）
%
%  参考文献:
%    [R1] Muñoz-Delgado et al., IEEE Trans. Smart Grid, 2018
%    [R2] Li et al., IEEE Trans. Power Syst., 2020
%  依赖: YALMIP + Gurobi
% =============================================================
clear; clc;

%% ============================================================
%  ★  用户配置区  ★
% ============================================================

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

% ── 变压器故障率（次/年/台）──────────────────────────────────
%
%  背景：
%    配电系统中"与变电站直接相连的分支"在本代码中被识别为变压器支路。
%    线路故障率：lambda_per_km × 长度（次/年），从数据文件读取。
%    变压器故障率：固定值（次/年/台），与长度无关。
%
%  LAMBDA_TRF = 0  → 变压器支路与线路统一用 lambda_per_km × 长度（默认行为）
%  LAMBDA_TRF > 0  → 变压器支路使用此固定故障率（单位：次/年/台）
%
%  ★ 重要提示（关于"加变压器后指标反而更好"的现象）：
%    85节点系统数据中，变压器支路的实测长度为 0.1~1.7 km，
%    按 lambda_per_km=0.4/km 计算，变压器支路故障率为 0.045~0.681 次/年/台。
%    若设置 LAMBDA_TRF=0.015，则远低于按长度计算的值（0.044~0.681），
%    导致"加入变压器故障率"后整体故障频率反而下降，指标反而改善。
%    这是参数设置问题，而非代码错误。
%
%    正确使用方式：LAMBDA_TRF 应大于等于该系统变压器支路的平均 per-km 折算值。
%    85节点系统变压器支路平均 per-km 折算值约为 0.314 次/年/台（len×λ）。
%    建议 LAMBDA_TRF 取 0.3~1.0 次/年/台，才能体现变压器比线路更不可靠的特性。
%LAMBDA_TRF = 0;       % 0 = 统一用线路公式；>0 = 变压器用此固定值
LAMBDA_TRF = 0.5;   % 示例：0.5 次/年/台（比按长度计算更高，指标会变差）

% ── 多阶段恢复时间参数 ────────────────────────────────────────
%  故障后恢复分为三个阶段：
%  阶段1 τ_UP_SW：隔离故障后，上游负荷通过本馈线开关操作恢复供电
%  阶段2 τ_TIE_SW：通过联络开关切换，向故障下游区域转供
%  阶段3 τ_RP：无法转供的故障下游节点等待设备修复后恢复
%
%  对应三类节点（每次故障 xy）：
%    ①p_feeder=1 且 p_direct=0（上游同馈线）：停电时长 = τ_UP_SW
%    ②p_direct=1 且 q=1（下游已重构转供）：   停电时长 = τ_TIE_SW
%    ③p_direct=1 且 q=0（下游无法转供）：      停电时长 = τ_RP（来自数据文件）
%
%  数据文件中 SW 列为历史混合估计值（含上游开关+联络开关），
%  本代码改为分别使用 τ_UP_SW 和 τ_TIE_SW，物理含义更清晰。
TAU_UP_SW  = 0.3;   % 上游开关操作恢复时间（h）
TAU_TIE_SW = 0.5;   % 联络开关切换转供时间（h）

% ── MCF 求解模式 ──────────────────────────────────────────────
%   'MCF'    → 多商品流 LP，一次建模（推荐）
%   'SINGLE' → 逐节点 LP + parfor（备用）
SOLVE_MODE = 'MCF';

% ── 电压约束（pu）与功率因数 ────────────────────────────────
V_UPPER = 1.2;   V_LOWER = 0.8;   V_SRC = 1.0;
PF = 0.9;
% ============================================================

program_total = tic;

%% ================================================================
%  §1  Testbench 数据读取
% ================================================================
fprintf('>> [1/8] 读取 Testbench: Sheet="%s"\n', sys_sheet);

tb_cell  = readcell(tb_filename, 'Sheet', sys_sheet);
nrows_tb = size(tb_cell, 1);

hdr_row = 0;
for ri = 1:nrows_tb
    if ischar(tb_cell{ri,1}) && contains(tb_cell{ri,1}, 'Tie-Switch')
        hdr_row = ri; break;
    end
end
if hdr_row == 0
    error('Testbench Sheet "%s" 中未找到 Tie-Switch 表头行。', sys_sheet);
end

LINE_CAP = str2double(extractBefore(string(tb_cell{hdr_row+1, 4}), ' '));
TRAN_CAP = LINE_CAP;

TIE_LINES_RAW = [];
for ri = hdr_row+2 : nrows_tb
    v1 = tb_cell{ri,1};  v2 = tb_cell{ri,2};
    if isnumeric(v1) && ~isnan(v1) && isnumeric(v2) && ~isnan(v2)
        TIE_LINES_RAW(end+1,:) = [v1, v2]; %#ok<AGROW>
    end
end
fprintf('   线路容量=%.0f MW，联络线=%d 条\n', LINE_CAP, size(TIE_LINES_RAW,1));

%% ================================================================
%  §2  可靠性参数读取
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

lambda_per_km = str2double(string(t_other{find(contains(col1,'Failure rate'),1), 2}));

row_dur = find(contains(col1,'Duration'), 1);
T_l = [str2double(string(t_other{row_dur,  3})), ...
       str2double(string(t_other{row_dur+1,3})), ...
       str2double(string(t_other{row_dur+2,3}))];

row_lf = find(contains(col1,'Loading factors'), 1);
L_f = [str2double(string(t_other{row_lf,  3})), ...
       str2double(string(t_other{row_lf+1,3})), ...
       str2double(string(t_other{row_lf+2,3}))] / 100;

if LAMBDA_TRF > 0
    fprintf('   lambda_line=%.4f/km，lambda_trf=%.4f/台，T_l=[%s]h，L_f=[%s]\n', ...
        lambda_per_km, LAMBDA_TRF, num2str(T_l,'%g '), num2str(L_f,'%.2f '));
else
    fprintf('   lambda_line=%.4f/km（统一适用所有支路），T_l=[%s]h，L_f=[%s]\n', ...
        lambda_per_km, num2str(T_l,'%g '), num2str(L_f,'%.2f '));
end

%% ================================================================
%  §3  潮流参数生成
% ================================================================
fprintf('>> [3/8] 生成潮流参数...\n');

R_KM    = 0.003151;
X_KM    = 0.001526;
TAN_PHI = tan(acos(PF));

V_src_sq   = V_SRC^2;
V_upper_sq = V_UPPER^2;
V_lower_sq = V_LOWER^2;
M_V  = (V_upper_sq - V_lower_sq) * 2;
M_vn = V_upper_sq;

fprintf('   R=%.4f pu/km, X=%.4f pu/km, V∈[%.2f,%.2f] pu\n', ...
    R_KM, X_KM, V_LOWER, V_UPPER);
fprintf('   τ_UP_SW=%.2fh（上游开关操作），τ_TIE_SW=%.2fh（联络开关转供）\n', ...
    TAU_UP_SW, TAU_TIE_SW);

%% ================================================================
%  §4  拓扑索引构建（区分线路/变压器设备类型故障率）
%
%  识别规则：与变电站节点直接相连的分支 → 变压器支路
%  故障率赋值：
%    LAMBDA_TRF = 0  → 统一用 lambda_per_km × 长度
%    LAMBDA_TRF > 0  → 变压器用 LAMBDA_TRF，线路用 lambda_per_km × 长度
% ================================================================
fprintf('>> [4/8] 构建拓扑索引...\n');

raw_nodes = unique([t_branch.From; t_branch.To; TIE_LINES_RAW(:)]);
num_nodes = length(raw_nodes);
node_map  = containers.Map(raw_nodes, 1:num_nodes);
inv_map   = raw_nodes;

subs_raw = raw_nodes(~ismember(raw_nodes, t_cust.Node));
subs_idx = arrayfun(@(s) node_map(s), subs_raw);
fprintf('   节点总数=%d, 变电站=%s\n', num_nodes, mat2str(subs_raw'));

nB_norm = height(t_branch);
nTie    = size(TIE_LINES_RAW, 1);
nB_all  = nB_norm + nTie;

rel_branches = zeros(nB_norm, 8);
for b = 1:nB_norm
    u_raw = t_branch.From(b);  v_raw = t_branch.To(b);
    u = node_map(u_raw);       v = node_map(v_raw);
    len = t_branch.Length_km(b);

    match = (t_dur.From==u_raw & t_dur.To==v_raw) | ...
            (t_dur.From==v_raw & t_dur.To==u_raw);
    if ~any(match)
        error('找不到分支(%d-%d)的停电时间数据。', u_raw, v_raw);
    end

    is_trf = ismember(u, subs_idx) | ismember(v, subs_idx);
    cap_b  = TRAN_CAP*is_trf + LINE_CAP*(~is_trf);

    % 故障率：变压器用固定值（若配置），线路用 per-km 公式
    if LAMBDA_TRF > 0 && is_trf
        lam_b = LAMBDA_TRF;
    else
        lam_b = len * lambda_per_km;
    end

    rel_branches(b,:) = [u, v, lam_b, t_dur.RP(match), t_dur.SW(match), ...
                         R_KM*len, X_KM*len, cap_b];
end

is_trf_vec = ismember(rel_branches(:,1), subs_idx) | ismember(rel_branches(:,2), subs_idx);
n_trf = sum(is_trf_vec);
if LAMBDA_TRF > 0
    lam_trf_len = rel_branches(is_trf_vec, 3);   % 此处已是 LAMBDA_TRF
    lam_line_eq = t_branch.Length_km(is_trf_vec) * lambda_per_km;
    fprintf('   设备类型: %d 条变压器 (λ_设定=%.4f/台, λ_等效长度=%.3f~%.3f/台)\n', ...
        n_trf, LAMBDA_TRF, min(lam_line_eq), max(lam_line_eq));
    fprintf('   注: λ_设定 %s λ_等效长度 → 变压器故障率%s\n', ...
        ternary(LAMBDA_TRF < min(lam_line_eq), '<', ternary(LAMBDA_TRF > max(lam_line_eq),'>','≈')), ...
        ternary(LAMBDA_TRF < min(lam_line_eq),'被低估（指标改善非真实效果）','被正确建模'));
    fprintf('   %d 条线路 (λ=%.4f/km)\n', nB_norm-n_trf, lambda_per_km);
end

% 联络线
tie_branches = zeros(nTie, 8);
for t = 1:nTie
    u = node_map(TIE_LINES_RAW(t,1));  v = node_map(TIE_LINES_RAW(t,2));
    tie_branches(t,:) = [u, v, 0, 0, 0, R_KM*0.1, X_KM*0.1, LINE_CAP];
end

all_branches = [rel_branches; tie_branches];
branch_from  = all_branches(:,1);
branch_to    = all_branches(:,2);
r_b_all      = all_branches(:,6);
x_b_all      = all_branches(:,7);
cap_b_all    = all_branches(:,8);

load_nodes = setdiff(1:num_nodes, subs_idx);
nL     = length(load_nodes);
non_sub = load_nodes;

A_inc_norm = sparse(rel_branches(:,2), (1:nB_norm)', +1, num_nodes, nB_norm) + ...
             sparse(rel_branches(:,1), (1:nB_norm)', -1, num_nodes, nB_norm);
A_inc_all  = sparse(branch_to,   (1:nB_all)', +1, num_nodes, nB_all) + ...
             sparse(branch_from, (1:nB_all)', -1, num_nodes, nB_all);
A_free_all = A_inc_all(load_nodes, :);

B_to_all   = sparse((1:nB_all)', branch_to,   1, nB_all, num_nodes);
B_from_all = sparse((1:nB_all)', branch_from, 1, nB_all, num_nodes);
BdV = B_to_all - B_from_all;

[~, pk_row] = ismember(inv_map(load_nodes), t_peak.Node);
P_free = zeros(nL, 1);
valid  = pk_row > 0;
P_free(valid) = t_peak.P_kW(pk_row(valid)) / 1e3;
Q_free = P_free * TAN_PHI;

fprintf('   正常分支=%d（含变压器%d条），联络线=%d，负荷节点=%d\n', ...
    nB_norm, n_trf, nTie, nL);

%% ================================================================
%  §5  MCF 路径识别
%
%  p_mat(k,xy)       → 节点 k 在故障 xy 下游（p_direct，仅下游）
%  p_feeder_mat(k,xy) → 节点 k 与故障 xy 在同一馈线（含上游同馈线节点）
%
%  p_feeder 与 p_mat 的差 = R1 中 N_SW 贡献的上游节点：
%    故障时馈线断路器跳闸，上游同馈线节点亦停电（τ^SW 后恢复）；
%    若仅用 p_mat 计算 CIF，则漏掉 N_SW 贡献，CIF_R2 < CIF_R1（错误）。
% ================================================================
fprintf('>> [5/8] MCF 路径识别 (模式: %s)...\n', SOLVE_MODE);
t_mcf = tic;

nSub  = length(subs_idx);
E_sub = sparse(subs_idx, 1:nSub, 1, num_nodes, nSub);

if strcmp(SOLVE_MODE, 'MCF')
    E_load = sparse(load_nodes, 1:nL, 1, num_nodes, nL);
    F_mat  = sdpvar(nB_norm, nL, 'full');
    Z_mat  = sdpvar(nB_norm, nL, 'full');
    Gss    = sdpvar(nSub,    nL, 'full');
    C_mcf  = [-Z_mat <= F_mat, F_mat <= Z_mat, Z_mat >= 0, ...
               0 <= Gss <= 1, sum(Gss,1) == 1, ...
               A_inc_norm * F_mat == E_load - E_sub*Gss];
    sol = optimize(C_mcf, sum(sum(Z_mat)), sdpsettings('solver','gurobi','verbose',0));
    if sol.problem ~= 0
        error('MCF 路径识别失败: %s', sol.info);
    end
    f_res = sparse(abs(value(F_mat)) > 0.5);
else
    f_res   = false(nB_norm, nL);
    opts_sp = sdpsettings('solver','gurobi','verbose',0);
    parfor k = 1:nL
        f_k = sdpvar(nB_norm,1); z_k = sdpvar(nB_norm,1); g_k = sdpvar(nSub,1);
        d_k = sparse(load_nodes(k),1,1,num_nodes,1) - E_sub*g_k;
        C_k = [-z_k<=f_k, f_k<=z_k, z_k>=0, 0<=g_k<=1, sum(g_k)==1, A_inc_norm*f_k==d_k];
        optimize(C_k, sum(z_k), opts_sp);
        f_res(:,k) = abs(value(f_k)) > 0.5;
    end
    f_res = sparse(f_res);
end

p_mat = f_res';   % nL×nB_norm，下游受影响（p_direct）

is_outlet = ismember(rel_branches(:,1), subs_idx) | ismember(rel_branches(:,2), subs_idx);
p_feeder_mat = sparse(nL, nB_norm);
for xy = 1:nB_norm
    dn_k = find(p_mat(:,xy), 1);
    if isempty(dn_k), continue; end
    for bi = find(f_res(:, dn_k))'
        if is_outlet(bi)
            p_feeder_mat(:,xy) = f_res(bi,:)';
            break;
        end
    end
end
p_feeder_mat = sparse(p_feeder_mat);

t_mcf_elapsed = toc(t_mcf);
fprintf('   MCF 完成（%.1f 秒），p_direct nnz=%d，p_feeder nnz=%d\n', ...
    t_mcf_elapsed, nnz(p_mat), nnz(p_feeder_mat));

%% ================================================================
%  §6  批量场景 MILP — LinDistFlow 最优重构（R2 Eq.2-13）
%
%  批量矩阵 MILP：所有 nB_norm 个故障场景同时建模，一次求解。
%  变量（列 = 场景）：
%    S_mat   (nB_all×nScen) binary  分支开关状态
%    Q_mat   (nL×nScen)     binary  负荷节点恢复状态
%    Pf_mat  (nB_all×nScen) cont.   有功潮流
%    Qf_mat  (nB_all×nScen) cont.   无功潮流
%    V_mat   (N×nScen)      cont.   节点电压平方（pu²）
%    E_vdrop (nB_all×nScen) cont.≥0 电压降落方程松弛量
%
%  Eq(13) 使用 p_feeder_d：
%    p_feeder=0 → 非本馈线节点，强制 q=1（确保其恢复）
%    p_feeder=1 → 本馈线节点，由优化器决定是否重构恢复
%    （若误用 p_mat/p_direct，上游同馈线节点被强制 q=1，
%     与辐射约束 sum(S)=sum(Q) 冲突 → Infeasible）
%
%  E_vdrop 松弛：联络线路径长、电压降落大，硬约束可能不可行；
%  以极小权重 alpha_vdrop 进入目标函数，既保证可行又不影响最大化恢复。
% ================================================================
fprintf('>> [6/8] 批量场景 MILP（%d 场景）...\n', nB_norm);
t_milp = tic;

nScen      = nB_norm;
p_mat_d    = double(p_mat);
p_feeder_d = double(p_feeder_mat);

Dr  = spdiags(r_b_all,  0, nB_all, nB_all);
Dx  = spdiags(x_b_all,  0, nB_all, nB_all);
Dp  = spdiags(P_free,   0, nL,     nL);
Dq_ = spdiags(Q_free,   0, nL,     nL);
Cap = spdiags(cap_b_all,0, nB_all, nB_all);

S_mat   = binvar(nB_all,    nScen, 'full');
Q_mat   = binvar(nL,        nScen, 'full');
Pf_mat  = sdpvar(nB_all,    nScen, 'full');
Qf_mat  = sdpvar(nB_all,    nScen, 'full');
V_mat   = sdpvar(num_nodes, nScen, 'full');
E_vdrop = sdpvar(nB_all,    nScen, 'full');

delta_mat     = BdV*V_mat + 2*(Dr*Pf_mat + Dx*Qf_mat);
fault_lin_idx = (0:nB_norm-1)*nB_all + (1:nB_norm);

C = [V_mat(subs_idx,:)    == V_src_sq,                       ...
     V_mat(non_sub,:)     >= V_lower_sq - M_vn*(1-Q_mat),   ...
     V_mat(non_sub,:)     <= V_upper_sq + M_vn*(1-Q_mat),   ...
     -Cap*S_mat           <= Pf_mat <= Cap*S_mat,            ...
     -Cap*S_mat           <= Qf_mat <= Cap*S_mat,            ...
     A_free_all*Pf_mat    == Dp *Q_mat,                      ...
     A_free_all*Qf_mat    == Dq_*Q_mat,                      ...
     E_vdrop              >= 0,                              ...
     delta_mat            <=  M_V*(1-S_mat) + E_vdrop,       ...
     delta_mat            >= -M_V*(1-S_mat) - E_vdrop,       ...
     sum(S_mat,1)         == sum(Q_mat,1),                   ...
     S_mat(fault_lin_idx) == 0,                              ...
     Q_mat                >= 1 - p_feeder_d];

alpha_vdrop = 1e-4;
opts_milp   = sdpsettings('solver','gurobi','verbose',0,'gurobi.MIPGap',1e-3);
sol = optimize(C, -sum(sum(Q_mat)) + alpha_vdrop*sum(E_vdrop(:)), opts_milp);

if sol.problem == 0
    Qv = value(Q_mat);
    if any(isnan(Qv(:)))
        warning('[§6] Q_mat 含 NaN，退化为无重构');
        q_mat  = logical(1 - p_feeder_d);
        Pf_res = zeros(nB_all, nScen);
        Qf_res = zeros(nB_all, nScen);
        Vm_res = repmat(V_src_sq, num_nodes, nScen);
        Sw_res = zeros(nB_all, nScen);
    else
        q_mat  = logical(round(Qv));
        Pf_res = value(Pf_mat);
        Qf_res = value(Qf_mat);
        Vm_res = sqrt(max(value(V_mat), 0));
        Sw_res = round(value(S_mat));
    end
else
    warning('[§6] MILP 求解失败: %s，退化为无重构', sol.info);
    q_mat  = logical(1 - p_feeder_d);   % 退化：非馈线节点恢复，馈线内不恢复
    Pf_res = zeros(nB_all, nScen);
    Qf_res = zeros(nB_all, nScen);
    Vm_res = repmat(V_src_sq, num_nodes, nScen);
    Sw_res = zeros(nB_all, nScen);
end

% 重构恢复统计（基于下游直接受影响节点 p_direct，与 Gemini R6 一致）
%  分母：p_direct=1 的节点-故障对数（故障下游、须靠重构才能恢复的节点）
%  分子：其中 q=1 的数量（重构实际恢复的节点）
%  上游同馈线节点在 τ^SW 后自动恢复、不依赖重构，不应计入此统计。
n_affected  = full(sum(p_mat_d(:) > 0));
n_recovered = full(sum(sum(logical(p_mat_d) & q_mat)));
rec_pct     = n_recovered / max(n_affected, 1) * 100;

t_milp_elapsed = toc(t_milp);
fprintf('   MILP 完成（%.1f 秒），重构恢复率=%.1f%% (%d/%d)\n', ...
    t_milp_elapsed, rec_pct, n_recovered, n_affected);

%% ================================================================
%  §7  可靠性指标计算（三阶段恢复模型）
%
%  三类节点的停电时长（每次故障 xy）：
%    ①上游同馈线（p_feeder=1, p_direct=0）: τ = τ_UP_SW
%       故障隔离后通过本馈线开关操作即可恢复，无需联络线
%    ②下游已转供恢复（p_direct=1, q=1）:   τ = τ_TIE_SW
%       通过联络开关切换转供恢复，时间比上游开关操作更长
%    ③下游无法转供（p_direct=1, q=0）:     τ = τ_RP（逐支路修复时间）
%       既无法通过本馈线隔离恢复，又无法通过联络线转供，须等待修复
%    ④其他馈线节点（p_feeder=0）:          τ = 0
%
%  CIF(k) = Σ_xy λ_xy · p_feeder(k,xy)                           [所有受影响节点]
%
%  CID(k) = Σ_xy λ_xy · τ_UP_SW  · p_feeder(k,xy)·(1-p_direct(k,xy))   [①上游]
%          + Σ_xy λ_xy · τ_TIE_SW · p_direct(k,xy)·q(k,xy)              [②转供]
%          + Σ_xy λ_xy · τ_RP(xy) · p_direct(k,xy)·(1-q(k,xy))          [③修复]
%
%  与旧两阶段公式的差异：
%    旧: CID = p_feeder·(λ·τ_SW) + p_direct·(1-q)·λ·(τ_RP-τ_SW)
%        → 将上游节点和转供节点的恢复时间都用同一个 τ_SW（数据文件值）
%    新: 上游节点用 τ_UP_SW=0.3h，转供节点用 τ_TIE_SW=0.5h，物理含义更准确
% ================================================================
fprintf('>> [7/8] 计算可靠性指标（三阶段恢复模型）...\n');

lam = rel_branches(:,3);
trp = rel_branches(:,4);   % τ_RP：逐支路修复时间（来自数据文件）

p_direct_d = double(p_mat);
q_mat_d    = double(q_mat);

% 上游节点指示矩阵（p_feeder=1 但 p_direct=0）
p_upstream_d = full(p_feeder_d) - p_direct_d;   % nL×nB_norm，仅上游同馈线节点

[~, c_row] = ismember(inv_map(load_nodes), t_cust.Node);
NC_vec = zeros(1, nL);
NC_vec(c_row>0) = t_cust.NC(c_row(c_row>0))';

[~, p_row] = ismember(inv_map(load_nodes), t_peak.Node);
P_avg_vec = zeros(1, nL);
P_avg_vec(p_row>0) = t_peak.P_kW(p_row(p_row>0))' .* sum(L_f .* (T_l/8760));

total_cust = sum(NC_vec);

% ── R2 指标（含重构，三阶段）──────────────────────────────────────────────
CIF = p_feeder_d * lam;
CID = TAU_UP_SW  * (p_upstream_d * lam) ...             % ①上游节点：τ_UP_SW
    + TAU_TIE_SW * (p_direct_d .* q_mat_d) * lam ...    % ②转供恢复：τ_TIE_SW
    + (p_direct_d .* (1-q_mat_d)) * (lam .* trp);       % ③等待修复：τ_RP

SAIFI = sum(NC_vec .* CIF') / total_cust;
SAIDI = sum(NC_vec .* CID') / total_cust;
EENS  = sum(P_avg_vec .* CID') / 1e3;
ASAI  = 1 - SAIDI / 8760;

% ── R1 基准（无重构，q≡0，两阶段退化）────────────────────────────────────
%  无重构时不存在联络线转供，下游节点要么等待修复（τ_RP）
%  上游节点仍通过本馈线开关恢复（τ_UP_SW）
CIF_R1 = p_feeder_d * lam;
CID_R1 = TAU_UP_SW * (p_upstream_d * lam) ...   % ①上游节点
       + p_direct_d * (lam .* trp);              % ③全部下游等待修复（无重构）

SAIFI_R1 = sum(NC_vec .* CIF_R1') / total_cust;
SAIDI_R1 = sum(NC_vec .* CID_R1') / total_cust;
EENS_R1  = sum(P_avg_vec .* CID_R1') / 1e3;
ASAI_R1  = 1 - SAIDI_R1 / 8760;

%% ================================================================
%  §8  结果输出（可靠性指标 + 重构后潮流信息）
% ================================================================
total_elapsed = toc(program_total);

% ── 可靠性评估结果 ────────────────────────────────────────────────────────
fprintf('\n╔══════════════════════════════════════════╗\n');
fprintf('  系统: %-39s\n', sys_filename);
if LAMBDA_TRF > 0
    fprintf('  设备: 线路λ=%.4f/km，变压器λ=%.4f/台\n', lambda_per_km, LAMBDA_TRF);
else
    fprintf('  设备: 线路λ=%.4f/km（统一适用所有支路）\n', lambda_per_km);
end
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  [R2 含重构]                              ║\n');
fprintf('║  SAIFI : %10.4f  次/(户·年)         ║\n', SAIFI);
fprintf('║  SAIDI : %10.4f  h/(户·年)          ║\n', SAIDI);
fprintf('║  EENS  : %10.2f  MWh/年             ║\n', EENS);
fprintf('║  ASAI  : %12.6f                   ║\n', ASAI);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  [R1 不含重构]                            ║\n');
fprintf('║  SAIFI : %10.4f  次/(户·年)         ║\n', SAIFI_R1);
fprintf('║  SAIDI : %10.4f  h/(户·年)          ║\n', SAIDI_R1);
fprintf('║  EENS  : %10.2f  MWh/年             ║\n', EENS_R1);
fprintf('║  ASAI  : %12.6f                   ║\n', ASAI_R1);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  SAIFI 改善: %+10.4f 次/(户·年)           \n', SAIFI_R1-SAIFI);
fprintf('║  注：SAIFI_R2=SAIFI_R1 为物理正确。         \n');
fprintf('║      重构仅缩短停电时长，不减少中断次数。    \n');
fprintf('║  注：τ_UP_SW=%.2fh，τ_TIE_SW=%.2fh（三阶段）  \n', TAU_UP_SW, TAU_TIE_SW);
fprintf('║  SAIDI 改善: %+10.4f h/(户·年)             \n', SAIDI_R1-SAIDI);
fprintf('║  EENS  改善: %+10.2f MWh/年               \n', EENS_R1-EENS);
fprintf('║  重构恢复率: %.1f%% (%d/%d)                \n', rec_pct, n_recovered, n_affected);
if rec_pct == 0
    fprintf('║  !! 恢复率为0%%：联络线路径电压降落超 V_lower  \n');
    fprintf('║     可尝试降低 V_LOWER（如0.90）以允许更多恢复  \n');
end
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  联络线=%d 条  容量=%.0f MW                \n', nTie, LINE_CAP);
fprintf('║  负荷节点=%d  故障场景=%d                  \n', nL, nB_norm);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  §5 MCF : %7.1f 秒                    \n', t_mcf_elapsed);
fprintf('║  §6 MILP: %7.1f 秒                    \n', t_milp_elapsed);
fprintf('║  总耗时 : %7.1f 秒                    \n', total_elapsed);
fprintf('╚══════════════════════════════════════════╝\n');

% ── 重构后潮流信息 ────────────────────────────────────────────────────────
[~, rep_xy] = max(sum(p_direct_d, 1));

fprintf('\n══════════════════════════════════════════════\n');
fprintf('  重构后潮流（代表性故障场景 %d：分支 %d─%d 故障）\n', ...
    rep_xy, inv_map(rel_branches(rep_xy,1)), inv_map(rel_branches(rep_xy,2)));
fprintf('══════════════════════════════════════════════\n');

Vm_rep = Vm_res(:, rep_xy);
Pf_rep = Pf_res(:, rep_xy);
Qf_rep = Qf_res(:, rep_xy);
Sw_rep = Sw_res(:, rep_xy);
qv_rep = q_mat(:, rep_xy);
pf_rep = full(p_feeder_d(:, rep_xy));

fprintf('\n  节点电压幅值（pu，SB=1 MVA）\n');
fprintf('  %-10s  %-10s  %-12s\n', '节点编号', '电压/pu', '状态');
fprintf('  %s\n', repmat('─',1,36));
for si = 1:length(subs_idx)
    fprintf('  %-10d  %-10.4f  变电站（源）\n', inv_map(subs_idx(si)), Vm_rep(subs_idx(si)));
end
for k = 1:nL
    if qv_rep(k)
        st = ternary(pf_rep(k)>0, '重构后恢复', '正常供电');
        fprintf('  %-10d  %-10.4f  %s\n', inv_map(load_nodes(k)), Vm_rep(load_nodes(k)), st);
    end
end
n_dark = sum(~qv_rep & pf_rep > 0);
if n_dark > 0
    fprintf('  （注：%d 个受影响节点未恢复供电，电压变量无意义，已略去）\n', n_dark);
end

fprintf('\n  合路分支潮流（SB=1 MVA，单位：kW / kVar）\n');
fprintf('  %-6s  %-6s  %-6s  %-12s  %-12s  %-8s\n', ...
    '分支#', 'From', 'To', 'P/kW', 'Q/kVar', '设备类型');
fprintf('  %s\n', repmat('─',1,62));
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

% --- 修复后的变电站出力统计逻辑 ---
P_total = 0; Q_total = 0;
for b = 1:nB_all
    if Sw_rep(b) == 1
        % 如果变电站是 From 端，功率流出变电站，取正号
        if ismember(all_branches(b,1), subs_idx)
            P_total = P_total + Pf_rep(b);
            Q_total = Q_total + Qf_rep(b);
        % 如果变电站是 To 端，功率流出变电站代表反向流动，取负号
        elseif ismember(all_branches(b,2), subs_idx)
            P_total = P_total - Pf_rep(b);
            Q_total = Q_total - Qf_rep(b);
        end
    end
end
P_total = P_total * 1e3;
Q_total = Q_total * 1e3;

% subs_branch_mask = ismember(all_branches(:,1),subs_idx) | ismember(all_branches(:,2),subs_idx);
% P_total = sum(Pf_rep(Sw_rep==1 & subs_branch_mask)) * 1e3;
% Q_total = sum(Qf_rep(Sw_rep==1 & subs_branch_mask)) * 1e3;

n_aff = sum(pf_rep);
n_rec = sum(qv_rep & pf_rep>0);
fprintf('\n  场景汇总：受影响=%d节点，重构恢复=%d节点，未恢复=%d节点\n', ...
    n_aff, n_rec, n_aff-n_rec);
fprintf('  变电站总出力：P=%.2f kW，Q=%.2f kVar\n', P_total, Q_total);

%% ── 辅助内联函数 ─────────────────────────────────────────────────────────
function out = ternary(cond, a, b)
    if cond, out = a; else, out = b; end
end