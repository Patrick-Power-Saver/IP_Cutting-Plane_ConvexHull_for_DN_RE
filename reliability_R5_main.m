%% ============================================================
%  配电网可靠性评估 —— R2 版本（含故障后最优网络重构）
%  通用于 85 / 137 / 417 / 1080 节点测试系统
%
%  §1  Testbench 数据读取（联络线位置、容量）
%  §2  可靠性参数读取（故障率、停电时间、负荷、客户数）
%  §3  潮流参数生成（线路阻抗、电压约束）
%  §4  拓扑索引构建（关联矩阵，含联络线；区分设备类型故障率）
%  §5  MCF 路径识别 → p_mat / p_feeder_mat
%  §6  逐场景 MILP（LinDistFlow 最优重构，R2 Eq.2-13）
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
%  配电系统中存在两类主要设备：
%    线路：故障率 ∝ 长度（次/年·km），从数据文件读取 lambda_per_km
%    变压器：故障率固定、与长度无关（次/年/台）
%  代码自动将"与变电站直接相连"的分支识别为变压器支路。
%
%  LAMBDA_TRF = 0  → 所有支路统一用 lambda_per_km × 长度（原始行为）
%  LAMBDA_TRF > 0  → 变压器支路用此固定故障率，线路支路仍用 per-km 公式
%  若数据文件 Other data 表中有 "Transformer failure rate" 行，将自动读取。
LAMBDA_TRF = 0;

% ── MCF 求解模式 ──────────────────────────────────────────────
%   'MCF'    → 多商品流 LP，一次建模（推荐）
%   'SINGLE' → 逐节点 LP + parfor（备用）
SOLVE_MODE = 'MCF';

% ── 电压约束（pu）────────────────────────────────────────────
V_UPPER = 1.05;   V_LOWER = 0.95;   V_SRC = 1.0;

% ── 功率因数 ──────────────────────────────────────────────────
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

% 自动从数据文件读取变压器故障率（若存在对应行）
row_trf = find(contains(col1,'Transformer failure rate'), 1);
if ~isempty(row_trf) && LAMBDA_TRF == 0
    LAMBDA_TRF = str2double(string(t_other{row_trf, 2}));
    fprintf('   从数据文件读取变压器故障率: %.4f 次/年/台\n', LAMBDA_TRF);
end

fprintf('   lambda_line=%.4f/km, T_l=[%s]h, L_f=[%s]\n', ...
    lambda_per_km, num2str(T_l,'%g '), num2str(L_f,'%.2f '));

%% ================================================================
%  §3  潮流参数生成
% ================================================================
fprintf('>> [3/8] 生成潮流参数...\n');

R_KM    = 0.003151;         % pu/km（EFF&ERF 导线，SB=1 MVA）
X_KM    = 0.001526;         % pu/km
TAN_PHI = tan(acos(PF));    % Q/P ≈ 0.4843

V_src_sq   = V_SRC^2;
V_upper_sq = V_UPPER^2;
V_lower_sq = V_LOWER^2;
M_V  = (V_upper_sq - V_lower_sq) * 2;   % 电压降落 Big-M (pu²)
M_vn = V_upper_sq;                       % 节点电压条件约束 Big-M

fprintf('   R=%.4f pu/km, X=%.4f pu/km, V∈[%.2f,%.2f] pu\n', ...
    R_KM, X_KM, V_LOWER, V_UPPER);

%% ================================================================
%  §4  拓扑索引构建（区分线路/变压器设备类型故障率）
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

% ── 正常分支参数矩阵（逐支路查停电时间）──────────────────────────────────
% 列序: [u, v, lambda, tau_RP, tau_SW, r(pu), x(pu), cap(MVA)]
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

    % 故障率：变压器用固定值（若已配置），线路用 per-km 公式
    if LAMBDA_TRF > 0 && is_trf
        lam_b = LAMBDA_TRF;
    else
        lam_b = len * lambda_per_km;
    end

    rel_branches(b,:) = [u, v, lam_b, t_dur.RP(match), t_dur.SW(match), ...
                         R_KM*len, X_KM*len, cap_b];
end

% 设备类型标志（用于潮流输出标注）
is_trf_vec = ismember(rel_branches(:,1), subs_idx) | ...
             ismember(rel_branches(:,2), subs_idx);
n_trf = sum(is_trf_vec);
if LAMBDA_TRF > 0
    fprintf('   设备类型: %d 条变压器 (λ=%.4f/台), %d 条线路 (λ=%.4f/km)\n', ...
        n_trf, LAMBDA_TRF, nB_norm-n_trf, lambda_per_km);
end

% ── 联络线（lambda=0，不参与可靠性统计）──────────────────────────────────
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
non_sub = load_nodes;   % 非变电站节点（用于电压约束）

% ── 节点-分支关联矩阵（to=+1, from=-1）──────────────────────────────────
A_inc_norm = sparse(rel_branches(:,2), (1:nB_norm)', +1, num_nodes, nB_norm) + ...
             sparse(rel_branches(:,1), (1:nB_norm)', -1, num_nodes, nB_norm);
A_inc_all  = sparse(branch_to,   (1:nB_all)', +1, num_nodes, nB_all) + ...
             sparse(branch_from, (1:nB_all)', -1, num_nodes, nB_all);
A_free_norm = A_inc_norm(load_nodes, :);
A_free_all  = A_inc_all (load_nodes, :);

% ── 电压差投影矩阵 ────────────────────────────────────────────────────────
B_to_all   = sparse((1:nB_all)', branch_to,   1, nB_all, num_nodes);
B_from_all = sparse((1:nB_all)', branch_from, 1, nB_all, num_nodes);
BdV = B_to_all - B_from_all;

% ── 节点峰值负荷（pu，向量化）────────────────────────────────────────────
[~, pk_row] = ismember(inv_map(load_nodes), t_peak.Node);
P_free = zeros(nL, 1);
valid  = pk_row > 0;
P_free(valid) = t_peak.P_kW(pk_row(valid)) / 1e3;   % kW → pu (SB=1MVA)
Q_free = P_free * TAN_PHI;

fprintf('   正常分支=%d（含变压器%d条），联络线=%d，负荷节点=%d\n', ...
    nB_norm, n_trf, nTie, nL);

%% ================================================================
%  §5  MCF 路径识别
%
%  输出：
%    f_res(b,k)=1  → 正常分支 b 在节点 k 的供电路径上
%    p_mat         → nL×nB_norm，仅下游节点（"p_direct"）
%    p_feeder_mat  → nL×nB_norm，馈线级全部节点（含上游同馈线节点）
%
%  p_mat     用途：§6 MILP Eq(13) + §7 CID 的 τ^RP-τ^SW 项
%  p_feeder  用途：§7 CIF 和 CID 的 τ^SW 基础项（正确覆盖全部停电节点）
%
%  p_feeder 与 p_mat 的差异 = R1 中的"N_SW 贡献节点"：
%    故障触发时馈线断路器跳闸，上游同馈线节点也暂时停电（τ^SW 后恢复），
%    这部分贡献若仅用 p_mat 则被遗漏，导致 CIF_R2 < CIF_R1（缺少 N_SW 项）。
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
        f_k = sdpvar(nB_norm,1);  z_k = sdpvar(nB_norm,1);  g_k = sdpvar(nSub,1);
        d_k = sparse(load_nodes(k),1,1,num_nodes,1) - E_sub*g_k;
        C_k = [-z_k<=f_k, f_k<=z_k, z_k>=0, 0<=g_k<=1, sum(g_k)==1, A_inc_norm*f_k==d_k];
        optimize(C_k, sum(z_k), opts_sp);
        f_res(:,k) = abs(value(f_k)) > 0.5;
    end
    f_res = sparse(f_res);
end

p_mat = f_res';   % nL×nB_norm，下游受影响指示（p_direct）

% ── p_feeder_mat：馈线级停电指示 ─────────────────────────────────────────
is_outlet = ismember(rel_branches(:,1), subs_idx) | ...
            ismember(rel_branches(:,2), subs_idx);

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
%  §6  逐场景 MILP — LinDistFlow 最优重构（R2 Eq.2-13）
%
%  对每个故障场景 xy 独立求解一个小 MILP，决策变量：
%    sv (nB_all×1) binary   分支开关状态
%    qv (nL×1)     binary   负荷节点恢复状态
%    Pv (nB_all×1) cont.    有功潮流
%    Qv (nB_all×1) cont.    无功潮流
%    Vv (N×1)      cont.    节点电压平方（pu²）
%    ev (nB_all×1) cont.≥0  电压降落松弛量
%
%  LinDistFlow 约束（对照 Distflow_linear_opf.m）：
%    [C4]    Vv(subs) = V_src²
%    [C3]    Vv(j) ∈ [Vl²-M_vn(1-q), Vu²+M_vn(1-q)]  （q=0时松弛）
%    [7-10]  -cap·sv ≤ Pv/Qv ≤ cap·sv
%    [34-35] A_free_all·Pv = diag(P_free)·qv           （功率平衡，lossless）
%    [36]    BdV·Vv+2(Dr·Pv+Dx·Qv) ∈ [-M_V(1-sv)-ev, M_V(1-sv)+ev]
%    [11]    sum(sv) = sum(qv)                          （辐射约束）
%    [12]    sv(xy) = 0                                 （故障分支断开）
%    [13]    qv ≥ 1 - p_feeder(·,xy)                   （非馈线节点强制恢复）
%  目标: min -sum(qv) + alpha·sum(ev)
%
%  松弛量 ev 的作用：
%    联络线路径更长，电压降落可能超出合法范围，无松弛时约束不可行；
%    ev 以极小权重 alpha 进入目标函数，确保可行同时不影响最大化恢复主目标。
%
%  Eq(13) 使用 p_feeder 而非 p_direct：
%    p_feeder=0 的节点（其他馈线）强制 q=1；
%    p_feeder=1 的节点（本馈线，含上下游）由优化器自由决定是否恢复。
%    若用 p_direct，将有大量"上游同馈线节点"被强制 q=1，
%    与辐射约束 sum(sv)=sum(qv) 冲突 → Infeasible（已确认的 Bug 根因）。
%
%  SAIFI_R2 = SAIFI_R1（物理正确，非 Bug）：
%    重构只能缩短停电时长，无法阻止故障触发时断路器已跳的中断事件。
% ================================================================
fprintf('>> [6/8] 批量场景 MILP（%d 场景）...\n', nB_norm);
t_milp = tic;

nScen      = nB_norm;
p_mat_d    = double(p_mat);
p_feeder_d = double(p_feeder_mat);

%% ── 预计算稀疏对角矩阵 ─────────────────────────────────────────────────────
Dr  = spdiags(r_b_all,  0, nB_all, nB_all);
Dx  = spdiags(x_b_all,  0, nB_all, nB_all);
Dp  = spdiags(P_free,   0, nL,     nL);
Dq_ = spdiags(Q_free,   0, nL,     nL);
Cap = spdiags(cap_b_all,0, nB_all, nB_all);
BdV = B_to_all - B_from_all;
M_vn = V_upper_sq;

%% ── 批量决策变量（列 = 场景）────────────────────────────────────────────────
S_mat   = binvar(nB_all,    nScen, 'full');
Q_mat   = binvar(nL,        nScen, 'full');
Pf_mat  = sdpvar(nB_all,    nScen, 'full');
Qf_mat  = sdpvar(nB_all,    nScen, 'full');
V_mat   = sdpvar(num_nodes, nScen, 'full');
E_vdrop = sdpvar(nB_all,    nScen, 'full');   % 电压降松弛量（≥0）

%% ── 约束 ────────────────────────────────────────────────────────────────────
delta_mat = BdV*V_mat + 2*(Dr*Pf_mat + Dx*Qf_mat);   % nB_all×nScen

fault_lin_idx = (0:nB_norm-1)*nB_all + (1:nB_norm);  % S_mat(xy,xy) 线性索引

C = [V_mat(subs_idx,:)  == V_src_sq,                        ... % [C4] 子站电压
     V_mat(non_sub,:)   >= V_lower_sq - M_vn*(1-Q_mat),     ... % [C3] 条件电压下限
     V_mat(non_sub,:)   <= V_upper_sq + M_vn*(1-Q_mat),     ... % [C3] 条件电压上限
     -Cap*S_mat         <= Pf_mat <= Cap*S_mat,              ... % [7-10] 容量约束
     -Cap*S_mat         <= Qf_mat <= Cap*S_mat,              ...
     A_free_all*Pf_mat  == Dp *Q_mat,                       ... % [34] 有功平衡
     A_free_all*Qf_mat  == Dq_*Q_mat,                       ... % [35] 无功平衡
     E_vdrop            >= 0,                               ...
     delta_mat          <=  M_V*(1-S_mat) + E_vdrop,        ... % [36] 电压降落+松弛
     delta_mat          >= -M_V*(1-S_mat) - E_vdrop,        ...
     sum(S_mat,1)       == sum(Q_mat,1),                    ... % [11] 辐射约束
     S_mat(fault_lin_idx) == 0,                             ... % [12] 故障分支断开
     Q_mat              >= 1 - p_feeder_d];                     % [13] 非馈线节点强制恢复

%% ── 求解 ────────────────────────────────────────────────────────────────────
alpha_vdrop = 1e-4;   % 松弛惩罚权重（远小于 1，不影响最大化恢复主目标）
opts_milp   = sdpsettings('solver','gurobi','verbose',0,'gurobi.MIPGap',1e-6);
sol = optimize(C, -sum(sum(Q_mat)) + alpha_vdrop*sum(E_vdrop(:)), opts_milp);

if sol.problem == 0
    Qv = value(Q_mat);
    if any(isnan(Qv(:)))
        warning('[§6] Q_mat 含 NaN，退化为无重构');
        q_mat = logical(1 - p_mat_d);
        Pf_res = zeros(nB_all, nScen);
        Qf_res = zeros(nB_all, nScen);
        Vm_res = repmat(V_src_sq, num_nodes, nScen);
        Sw_res = zeros(nB_all, nScen);
    else
        q_mat  = logical(round(Qv));
        Pf_res = value(Pf_mat);
        Qf_res = value(Qf_mat);
        Vm_res = sqrt(max(value(V_mat), 0));   % 电压幅值（pu）
        Sw_res = round(value(S_mat));
    end
else
    warning('[§6] MILP 求解失败: %s，退化为无重构', sol.info);
    q_mat  = logical(1 - p_mat_d);
    Pf_res = zeros(nB_all, nScen);
    Qf_res = zeros(nB_all, nScen);
    Vm_res = repmat(V_src_sq, num_nodes, nScen);
    Sw_res = zeros(nB_all, nScen);
end

%% ── 重构统计 ────────────────────────────────────────────────────────────────
n_affected  = full(sum(p_feeder_d(:) > 0));
n_recovered = full(sum(sum(q_mat & (full(p_feeder_d) > 0))));
rec_pct     = n_recovered / max(n_affected, 1) * 100;

t_milp_elapsed = toc(t_milp);
fprintf('   MILP 完成（%.1f 秒），重构恢复率=%.1f%% (%d/%d)\n', ...
    t_milp_elapsed, rec_pct, n_recovered, n_affected);

%% ================================================================
%  §7  可靠性指标计算（R2 Eq.28-29，向量化）
%
%  CIF(k) = Σ_xy λ_xy · p_feeder(k,xy)
%  CID(k) = Σ_xy λ_xy·τ_SW · p_feeder(k,xy)
%          + Σ_xy λ_xy·(τ_RP-τ_SW) · p_direct(k,xy)·(1-q(k,xy))
%
%  CIF_R1 = CIF_R2（R2 中 SAIFI 不变，物理正确）
%  CID_R1 = CID 令 q≡0（无重构退化）
% ================================================================
fprintf('>> [7/8] 计算可靠性指标...\n');

lam = rel_branches(:,3);
trp = rel_branches(:,4);
tsw = rel_branches(:,5);

p_direct_d = double(p_mat);
q_mat_d    = double(q_mat);

% 客户数与年平均功率（向量化）
[~, c_row] = ismember(inv_map(load_nodes), t_cust.Node);
NC_vec = zeros(1, nL);
NC_vec(c_row>0) = t_cust.NC(c_row(c_row>0))';

[~, p_row] = ismember(inv_map(load_nodes), t_peak.Node);
P_avg_vec = zeros(1, nL);
P_avg_vec(p_row>0) = t_peak.P_kW(p_row(p_row>0))' .* sum(L_f .* (T_l/8760));

total_cust = sum(NC_vec);

% R2 指标（含重构）
CIF = p_feeder_d * lam;
CID = p_feeder_d * (lam .* tsw) + (p_direct_d .* (1-q_mat_d)) * (lam .* (trp-tsw));
SAIFI = sum(NC_vec .* CIF') / total_cust;
SAIDI = sum(NC_vec .* CID') / total_cust;
EENS  = sum(P_avg_vec .* CID') / 1e3;
ASAI  = 1 - SAIDI / 8760;

% R1 基准（无重构）
CIF_R1 = p_feeder_d * lam;
CID_R1 = p_feeder_d * (lam .* tsw) + p_direct_d * (lam .* (trp-tsw));
SAIFI_R1 = sum(NC_vec .* CIF_R1') / total_cust;
SAIDI_R1 = sum(NC_vec .* CID_R1') / total_cust;
EENS_R1  = sum(P_avg_vec .* CID_R1') / 1e3;
ASAI_R1  = 1 - SAIDI_R1 / 8760;

%% ================================================================
%  §8  结果输出（可靠性指标 + 重构后潮流）
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
fprintf('║  SAIDI 改善: %+10.4f h/(户·年)             \n', SAIDI_R1-SAIDI);
fprintf('║  EENS  改善: %+10.2f MWh/年               \n', EENS_R1-EENS);
fprintf('║  重构恢复率: %.1f%% (%d/%d)                \n', rec_pct, n_recovered, n_affected);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  联络线=%d 条  容量=%.0f MW                \n', nTie, LINE_CAP);
fprintf('║  负荷节点=%d  故障场景=%d                  \n', nL, nB_norm);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  §5 MCF : %7.1f 秒                    \n', t_mcf_elapsed);
fprintf('║  §6 MILP: %7.1f 秒                    \n', t_milp_elapsed);
fprintf('║  总耗时 : %7.1f 秒                    \n', total_elapsed);
fprintf('╚══════════════════════════════════════════╝\n');

% ── 重构后潮流信息 ────────────────────────────────────────────────────────
%  选取下游受影响节点最多的故障场景作为代表展示
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
pf_rep = full(p_feeder_d(:, rep_xy));   % 转为稠密向量，避免 fprintf 稀疏报错

% 节点电压表
fprintf('\n  节点电压幅值（pu，SB=1 MVA）\n');
fprintf('  %-10s  %-10s  %-12s\n', '节点编号', '电压/pu', '状态');
fprintf('  %s\n', repmat('─',1,36));
for si = 1:length(subs_idx)
    fprintf('  %-10d  %-10.4f  变电站（源）\n', inv_map(subs_idx(si)), Vm_rep(subs_idx(si)));
end
for k = 1:nL
    if qv_rep(k)
        if pf_rep(k) > 0
            st = '重构后恢复';
        else
            st = '正常供电';
        end
        fprintf('  %-10d  %-10.4f  %s\n', inv_map(load_nodes(k)), Vm_rep(load_nodes(k)), st);
    end
end
n_dark = sum(~qv_rep & pf_rep > 0);
if n_dark > 0
    fprintf('  （注：%d 个受影响节点未恢复供电，电压变量无意义，已略去）\n', n_dark);
end

% 分支潮流表
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

% 汇总行
subs_branch_mask = ismember(all_branches(:,1),subs_idx) | ismember(all_branches(:,2),subs_idx);
P_total = sum(Pf_rep(Sw_rep==1 & subs_branch_mask)) * 1e3;
Q_total = sum(Qf_rep(Sw_rep==1 & subs_branch_mask)) * 1e3;
n_aff = sum(pf_rep);
n_rec = sum(qv_rep & pf_rep>0);
fprintf('\n  场景汇总：受影响=%d节点，重构恢复=%d节点，未恢复=%d节点\n', ...
    n_aff, n_rec, n_aff-n_rec);
fprintf('  变电站总出力：P=%.2f kW，Q=%.2f kVar\n', P_total, Q_total);

%% ── 辅助内联函数 ─────────────────────────────────────────────────────────
function out = ternary(cond, a, b)
    if cond, out = a; else, out = b; end
end
