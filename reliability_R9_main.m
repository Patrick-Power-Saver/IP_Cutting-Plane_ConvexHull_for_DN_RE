%% ============================================================
%  配电网可靠性评估 —— R2 版本（CID最小化目标 + 连续切负荷）
%  通用于 85 / 137 / 417 / 1080 节点测试系统
%
%  §1  Testbench 数据读取
%  §2  可靠性参数读取
%  §3  潮流参数生成
%  §4  拓扑索引构建（区分设备类型故障率）
%  §5  MCF 路径识别 → p_mat / p_feeder_mat
%  §6  批量场景 MILP（CID最小化目标 + 连续切负荷）
%  §7  可靠性指标计算（含切负荷修正的三阶段模型）
%  §8  结果输出
%
%  ─── 目标函数说明（问题1）─────────────────────────────────────
%  原始目标 max Σ q(k,xy) 的缺陷：
%    所有节点等权（100kW = 1MW）、所有场景等权（λ=0.001 = λ=0.5）、
%    τ_RP不影响权重（修复时间2h = 10h），与SAIDI改善无直接对应关系。
%
%  文献（Li et al. 2020, Eq.1）目标 min SAIDI：
%    展开三阶段CID中与q有关的部分，等价于：
%      max Σ_{k,xy} W_cid(k,xy) · q(k,xy)
%    其中权重矩阵：
%      W_cid(k,xy) = NC_k · λ_xy · p_direct(k,xy) · (τ_RP(xy) - τ_TIE_SW)
%    三维差异：
%      NC_k          → 客户数多的节点权重高（重要用户优先恢复）
%      λ_xy          → 故障率高的场景权重高（频发故障优先优化）
%      τ_RP-τ_TIE_SW → 修复时间长的场景权重高（重构效益大的场景优先）
%
%  ─── 切负荷设计（问题2）──────────────────────────────────────
%  引入连续切负荷变量 L_mat(k,xy) ∈ [0, P_free(k)]（q=0时强制=0）：
%    功率平衡：A_free·Pf = Dp·Q - L_mat
%    无功平衡：A_free·Qf = Dq·Q - TAN_PHI·L_mat
%  目标函数含切负荷惩罚：min -Σ W_cid·Q + β·Σ W_shed·L_mat + α·Σ E_vdrop
%    W_shed(k,xy) = NC_k · λ_xy · p_direct(k,xy)（切负荷权重，与NC和λ成正比）
%
%  ─── SAIDI与恢复率修正（问题3）────────────────────────────────
%  切负荷节点(q=1, L>0)的停电时长：
%    t∈[0, τ_TIE_SW]: 全部负荷停电
%    t∈[τ_TIE_SW, τ_RP]: 切除部分L继续停电，(P-L)部分恢复
%  修正CID：
%    ④切负荷额外等待项：Σ_xy λ·(τ_RP-τ_TIE_SW)·p_direct·q·(L/P_free)
%  修正恢复率（功率基）：
%    rec_pct = Σ(P_free-L)·q·p_direct / Σ P_free·p_direct × 100%
%
%  参考文献: Li et al., IEEE Trans. Power Syst., 2020
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

% ── 变压器故障率（次/年/台，0=统一用线路公式）──────────────
LAMBDA_TRF = 0.5;

% ── 多阶段恢复时间参数（h）───────────────────────────────────
TAU_UP_SW  = 0.3;   % 上游开关操作恢复时间
TAU_TIE_SW = 0.5;   % 联络开关切换转供时间

% ── 切负荷惩罚权重（相对于CID最小化目标）───────────────────
%  beta_shed：切负荷惩罚系数，应远小于CID改善量以保证可行性优先
%  建议取值：1e-2～1e-1（越大越倾向于少切负荷，但可能影响收敛）
BETA_SHED = 2;

% ── MCF 求解模式 ──────────────────────────────────────────────
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

fprintf('   lambda_line=%.4f/km, T_l=[%s]h, L_f=[%s]\n', ...
    lambda_per_km, num2str(T_l,'%g '), num2str(L_f,'%.2f '));

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

fprintf('   R=%.4f, X=%.4f pu/km, V∈[%.2f,%.2f] pu\n', R_KM, X_KM, V_LOWER, V_UPPER);
fprintf('   τ_UP_SW=%.2fh, τ_TIE_SW=%.2fh, BETA_SHED=%.3f\n', TAU_UP_SW, TAU_TIE_SW, BETA_SHED);

%% ================================================================
%  §4  拓扑索引构建
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
    fprintf('   %d 条变压器 (λ=%.4f/台), %d 条线路 (λ=%.4f/km)\n', ...
        n_trf, LAMBDA_TRF, nB_norm-n_trf, lambda_per_km);
end

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
    if sol.problem ~= 0, error('MCF 失败: %s', sol.info); end
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
%  §6  批量场景 MILP（CID最小化目标 + 连续切负荷）
%
%  变量（列 = 场景）：
%    S_mat   (nB_all×nScen) binary   分支开关状态
%    Q_mat   (nL×nScen)     binary   负荷节点恢复状态
%    Pf_mat  (nB_all×nScen) cont.    有功潮流
%    Qf_mat  (nB_all×nScen) cont.    无功潮流
%    V_mat   (N×nScen)      cont.    节点电压平方（pu²）
%    E_vdrop (nB_all×nScen) cont.≥0  电压降落方程松弛量
%    L_mat   (nL×nScen)     cont.≥0  切负荷量（pu）【新增】
%
%  目标函数（CID最小化，等价形式）：
%    min  -Σ_{k,xy} W_cid(k,xy)·Q_mat(k,xy)
%       + β·Σ_{k,xy} W_shed(k,xy)·L_mat(k,xy)
%       + α·Σ E_vdrop
%
%    W_cid(k,xy) = NC_k · λ_xy · p_direct(k,xy) · (τ_RP(xy) - τ_TIE_SW)
%    W_shed(k,xy) = NC_k · λ_xy · p_direct(k,xy)
%
%    说明：
%    - W_cid 来自CID对q的偏导，最小化CID等价于最大化Σ W_cid·q
%    - W_shed 惩罚切负荷：NC_k和λ_xy大的节点切负荷代价更高
%    - BETA_SHED应远小于1，使切负荷惩罚不压过主目标
%
%  修改的约束（含切负荷）：
%    [34] 有功平衡：A_free·Pf = Dp·Q - L_mat
%    [35] 无功平衡：A_free·Qf = Dq·Q - TAN_PHI·L_mat
%    [新] L_mat ≥ 0
%    [新] L_mat ≤ P_max·Q_mat（q=0时L=0；q=1时L∈[0,P_demand]）
% ================================================================
fprintf('>> [6/8] 批量场景 MILP（%d 场景，CID最小化+切负荷）...\n', nB_norm);
t_milp = tic;

nScen      = nB_norm;
p_mat_d    = double(p_mat);
p_feeder_d = double(p_feeder_mat);

lam_vec = rel_branches(:,3);   % nB_norm×1，故障率
trp_vec = rel_branches(:,4);   % nB_norm×1，τ_RP

Dr  = spdiags(r_b_all,  0, nB_all, nB_all);
Dx  = spdiags(x_b_all,  0, nB_all, nB_all);
Dp  = spdiags(P_free,   0, nL,     nL);
Dq_ = spdiags(Q_free,   0, nL,     nL);
Cap = spdiags(cap_b_all,0, nB_all, nB_all);

%% ── 预计算 CID 目标权重矩阵 W_cid（nL×nScen）────────────────────────────
%  W_cid(k,xy) = NC_k · λ_xy · p_direct(k,xy) · (τ_RP(xy) - τ_TIE_SW)
%  推导：min CID = min Σ_k NC_k·[τ_UP·Σ_xy λ·p_up + τ_TIE·Σ_xy λ·p_dir·q
%                                + Σ_xy λ·τ_RP·p_dir·(1-q)]
%    与q无关的项为常数，对q取偏导后只需最大化：
%      Σ_{k,xy} NC_k·λ_xy·p_dir(k,xy)·(τ_RP(xy)-τ_TIE_SW)·q(k,xy)

[~, c_row_pre] = ismember(inv_map(load_nodes), t_cust.Node);
NC_vec = zeros(1, nL);
NC_vec(c_row_pre>0) = t_cust.NC(c_row_pre(c_row_pre>0))';

% W_cid(k,xy) = NC_k * lam_xy * p_direct(k,xy) * max(trp_xy - TAU_TIE_SW, 0)
tau_benefit = max(trp_vec - TAU_TIE_SW, 0);   % nB_norm×1，重构效益时长
W_cid = (NC_vec' .* p_mat_d) .* (lam_vec .* tau_benefit)';   % nL×nScen

% 切负荷惩罚权重 W_shed(k,xy) = NC_k * lam_xy * p_direct(k,xy)
W_shed = (NC_vec' .* p_mat_d) .* lam_vec';   % nL×nScen

fprintf('   W_cid: max=%.4f, mean=%.4f, nnz=%d\n', ...
    full(max(W_cid(:))), ...
    full(sum(W_cid(:))/max(nnz(W_cid), 1)), ...
    full(nnz(W_cid)));
fprintf('   (相比等权目标，CID最小化对高客户数/高故障率/长修复时间节点优先恢复)\n');

%% ── 批量决策变量 ──────────────────────────────────────────────────────────
S_mat   = binvar(nB_all,    nScen, 'full');
Q_mat   = binvar(nL,        nScen, 'full');
Pf_mat  = sdpvar(nB_all,    nScen, 'full');
Qf_mat  = sdpvar(nB_all,    nScen, 'full');
V_mat   = sdpvar(num_nodes, nScen, 'full');
E_vdrop = sdpvar(nB_all,    nScen, 'full');
L_mat   = sdpvar(nL,        nScen, 'full');   % ★ 切负荷量（pu）

delta_mat     = BdV*V_mat + 2*(Dr*Pf_mat + Dx*Qf_mat);
fault_lin_idx = (0:nB_norm-1)*nB_all + (1:nB_norm);

% 切负荷上界矩阵（q=1 时 L ≤ P_free，q=0 时 L ≤ 0）
P_max_mat = 0.1*repmat(P_free, 1, nScen);   % nL×nScen

%% ── 约束 ──────────────────────────────────────────────────────────────────
C = [V_mat(subs_idx,:)    == V_src_sq,                       ...  % [C4] 子站电压
     V_mat(non_sub,:)     >= V_lower_sq - M_vn*(1-Q_mat),   ...  % [C3] 条件电压下限
     V_mat(non_sub,:)     <= V_upper_sq + M_vn*(1-Q_mat),   ...  % [C3] 条件电压上限
     -Cap*S_mat           <= Pf_mat <= Cap*S_mat,            ...  % [7-10] 容量约束
     -Cap*S_mat           <= Qf_mat <= Cap*S_mat,            ...
     A_free_all*Pf_mat    == Dp*Q_mat - L_mat,               ...  % [34] 有功平衡（含切负荷）
     A_free_all*Qf_mat    == Dq_*Q_mat - TAN_PHI*L_mat,      ...  % [35] 无功平衡（含切负荷）
     E_vdrop              >= 0,                              ...
     delta_mat            <=  M_V*(1-S_mat) + E_vdrop,       ...  % [36] 电压降落+松弛
     delta_mat            >= -M_V*(1-S_mat) - E_vdrop,       ...
     sum(S_mat,1)         == sum(Q_mat,1),                   ...  % [11] 辐射约束
     S_mat(fault_lin_idx) == 0,                              ...  % [12] 故障断开
     Q_mat                >= 1 - p_feeder_d,                 ...  % [13] 非馈线节点强制恢复
     L_mat                >= 0,                              ...  % ★ 切负荷非负
     L_mat                <= P_max_mat .* Q_mat];                 % ★ q=0时L=0；q=1时L≤P_free

%% ── 目标函数（CID最小化等价形式）────────────────────────────────────────
alpha_ev = 1e-4;   % 电压降松弛惩罚权重（保持可行性）
objective = -sum(sum(W_cid .* Q_mat)) ...             % 主目标：最大化加权CID改善
          + BETA_SHED * sum(sum(W_shed .* L_mat)) ... % 次目标：惩罚切负荷
          + alpha_ev * sum(E_vdrop(:));                % 三级：最小化电压松弛

opts_milp = sdpsettings('solver','gurobi','verbose',0,'gurobi.MIPGap',1e-3);
sol = optimize(C, objective, opts_milp);

%% ── 提取结果 ──────────────────────────────────────────────────────────────
if sol.problem == 0
    Qv = value(Q_mat);
    if any(isnan(Qv(:)))
        warning('[§6] Q_mat 含 NaN，退化为无重构无切负荷');
        q_mat  = logical(1 - p_feeder_d);
        L_res  = zeros(nL, nScen);
        Pf_res = zeros(nB_all, nScen);
        Qf_res = zeros(nB_all, nScen);
        Vm_res = repmat(V_src_sq, num_nodes, nScen);
        Sw_res = zeros(nB_all, nScen);
    else
        q_mat  = logical(round(Qv));
        L_res  = max(value(L_mat), 0);   % nL×nScen，切负荷量（pu）
        Pf_res = value(Pf_mat);
        Qf_res = value(Qf_mat);
        Vm_res = sqrt(max(value(V_mat), 0));
        Sw_res = round(value(S_mat));
    end
else
    warning('[§6] MILP 求解失败: %s，退化为无重构无切负荷', sol.info);
    q_mat  = logical(1 - p_feeder_d);
    L_res  = zeros(nL, nScen);
    Pf_res = zeros(nB_all, nScen);
    Qf_res = zeros(nB_all, nScen);
    Vm_res = repmat(V_src_sq, num_nodes, nScen);
    Sw_res = zeros(nB_all, nScen);
end

%% ── 重构恢复率（功率基，含切负荷修正）──────────────────────────────────
%  传统恢复率（节点数）：n_recovered / n_affected
%  修正恢复率（功率基）：
%    分母 = Σ_{k,xy: p_direct=1} P_free(k)（下游受影响总功率）
%    分子 = Σ_{k,xy: p_direct=1} (P_free(k) - L(k,xy)) · q(k,xy)（净恢复功率）
%
%  分项统计：
%    完全恢复（q=1, L≈0）：节点和功率
%    部分恢复（q=1, L>0）：节点和功率
%    未恢复（q=0）：节点

q_mat_d     = double(q_mat);
p_direct_d  = double(p_mat);
p_feeder_d_full = double(p_feeder_mat);

SHED_THRESH = 1e-4;   % 判断切负荷是否显著的阈值（pu）
mask_q1     = q_mat_d > 0.5;
mask_q1_shed = mask_q1 & (L_res > SHED_THRESH);
mask_q1_full = mask_q1 & (L_res <= SHED_THRESH);
mask_q0_direct = (q_mat_d < 0.5) & (p_direct_d > 0.5);

P_free_mat = repmat(P_free, 1, nScen);   % nL×nScen

n_aff_total = full(sum(p_direct_d(:) > 0));
n_full_rec  = full(sum(mask_q1_full(:) & p_direct_d(:) > 0));
n_part_rec  = full(sum(mask_q1_shed(:) & p_direct_d(:) > 0));
n_unrec     = full(sum(mask_q0_direct(:)));

aff_power   = full(sum(sum(P_free_mat .* p_direct_d)));
net_rec_power = full(sum(sum((P_free_mat - L_res) .* q_mat_d .* p_direct_d)));
rec_pct_power = net_rec_power / max(aff_power, 1e-9) * 100;

total_shed_pu = full(sum(sum(L_res .* q_mat_d .* p_direct_d)));   % 有效切负荷总量

t_milp_elapsed = toc(t_milp);
fprintf('   MILP 完成（%.1f 秒）\n', t_milp_elapsed);
fprintf('   节点恢复分类: 完全恢复=%d, 部分恢复(切负荷)=%d, 未恢复=%d / 受影响=%d\n', ...
    n_full_rec, n_part_rec, n_unrec, n_aff_total);
fprintf('   功率基恢复率=%.1f%% (净恢复%.3f/受影响%.3f pu·场景)\n', ...
    rec_pct_power, net_rec_power, aff_power);
fprintf('   总切负荷量=%.4f pu·场景 (占受影响功率%.1f%%)\n', ...
    total_shed_pu, total_shed_pu/max(aff_power,1e-9)*100);

%% ================================================================
%  §7  可靠性指标计算（三阶段模型 + 切负荷修正）
%
%  三阶段CID（原有）：
%    ①上游同馈线: CID += τ_UP_SW · Σ λ·p_upstream
%    ②下游已转供: CID += τ_TIE_SW · Σ λ·p_direct·q
%    ③下游未转供: CID += Σ λ·τ_RP·p_direct·(1-q)
%
%  新增切负荷修正项④：
%    ④切负荷额外停电: CID += Σ λ·(τ_RP-τ_TIE_SW)·p_direct·q·(L/P_free)
%
%  物理推导：
%    q=1节点在τ_TIE_SW时联络线转供，(P-L)部分恢复（停电τ_TIE_SW）
%    L部分继续停电直至τ_RP修复完成（停电τ_RP）
%    额外等待 = τ_RP - τ_TIE_SW
%
%  验证：
%    q=1, L=0:    CID += τ_TIE_SW               ✓
%    q=1, L=P:    CID += τ_TIE_SW+(τ_RP-τ_TIE_SW)·1 = τ_RP  ✓（完全切除=未恢复）
%    q=0:         CID += τ_RP                    ✓
% ================================================================
fprintf('>> [7/8] 计算可靠性指标（三阶段+切负荷修正）...\n');

lam = rel_branches(:,3);
trp = rel_branches(:,4);

p_upstream_d = p_feeder_d_full - p_direct_d;   % nL×nScen，仅上游节点

[~, c_row] = ismember(inv_map(load_nodes), t_cust.Node);
NC_vec = zeros(1, nL);
NC_vec(c_row>0) = t_cust.NC(c_row(c_row>0))';

[~, p_row] = ismember(inv_map(load_nodes), t_peak.Node);
P_avg_vec = zeros(1, nL);
P_avg_vec(p_row>0) = t_peak.P_kW(p_row(p_row>0))' .* sum(L_f .* (T_l/8760));

total_cust = sum(NC_vec);

% 切负荷比例矩阵：shed_ratio(k,xy) = L(k,xy) / P_free(k)（q=0时为0）
P_free_safe = max(P_free, 1e-9);   % 避免除零
shed_ratio  = L_res ./ repmat(P_free_safe, 1, nScen) .* q_mat_d;   % nL×nScen
% 仅对 p_direct=1 的节点有意义（其他位置 shed_ratio 本应为0）
shed_ratio  = shed_ratio .* p_direct_d;

% ── R2 指标（含重构+切负荷，三阶段+修正项④）──────────────────────────────
CIF = p_feeder_d_full * lam;

CID = TAU_UP_SW  * (p_upstream_d * lam) ...                          % ①上游
    + TAU_TIE_SW * (p_direct_d .* q_mat_d) * lam ...                 % ②转供（基础停电）
    + (p_direct_d .* (1-q_mat_d)) * (lam .* trp) ...                 % ③未转供
    + (shed_ratio .* p_direct_d .* q_mat_d) * (lam .* (trp - TAU_TIE_SW));  % ④切负荷额外等待

SAIFI = sum(NC_vec .* CIF') / total_cust;
SAIDI = sum(NC_vec .* CID') / total_cust;
EENS  = sum(P_avg_vec .* CID') / 1e3;
ASAI  = 1 - SAIDI / 8760;

% ── R1 基准（无重构，q≡0，无切负荷）──────────────────────────────────────
CIF_R1 = p_feeder_d_full * lam;
CID_R1 = TAU_UP_SW * (p_upstream_d * lam) + p_direct_d * (lam .* trp);
SAIFI_R1 = sum(NC_vec .* CIF_R1') / total_cust;
SAIDI_R1 = sum(NC_vec .* CID_R1') / total_cust;
EENS_R1  = sum(P_avg_vec .* CID_R1') / 1e3;
ASAI_R1  = 1 - SAIDI_R1 / 8760;

%% ── 分项CID贡献（便于理解切负荷的影响）─────────────────────────────────
CID_upstream = TAU_UP_SW * (p_upstream_d * lam);            % ①项，nL×1
CID_tieline  = TAU_TIE_SW * (p_direct_d .* q_mat_d) * lam; % ②项
CID_repair   = (p_direct_d .* (1-q_mat_d)) * (lam .* trp); % ③项
CID_shed_add = (shed_ratio .* p_direct_d .* q_mat_d) * (lam .* (trp - TAU_TIE_SW)); % ④项

SAIDI_contrib_up   = sum(NC_vec .* CID_upstream') / total_cust;
SAIDI_contrib_tie  = sum(NC_vec .* CID_tieline')  / total_cust;
SAIDI_contrib_rep  = sum(NC_vec .* CID_repair')   / total_cust;
SAIDI_contrib_shed = sum(NC_vec .* CID_shed_add') / total_cust;

%% ================================================================
%  §8  结果输出
% ================================================================
total_elapsed = toc(program_total);

fprintf('\n╔══════════════════════════════════════════╗\n');
fprintf('  系统: %-39s\n', sys_filename);
if LAMBDA_TRF > 0
    fprintf('  设备: 线路λ=%.4f/km，变压器λ=%.4f/台\n', lambda_per_km, LAMBDA_TRF);
else
    fprintf('  设备: 线路λ=%.4f/km（统一适用）\n', lambda_per_km);
end
fprintf('  τ_UP_SW=%.2fh，τ_TIE_SW=%.2fh，BETA_SHED=%.3f\n', ...
    TAU_UP_SW, TAU_TIE_SW, BETA_SHED);
fprintf('  目标: CID最小化（Li et al. 2020, Eq.1）\n');
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  [R2 含重构+切负荷]                       ║\n');
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
fprintf('║  SAIFI : %10.4f  次/(户·年)         ║\n', SAIFI_R1);
fprintf('║  SAIDI : %10.4f  h/(户·年)          ║\n', SAIDI_R1);
fprintf('║  EENS  : %10.2f  MWh/年             ║\n', EENS_R1);
fprintf('║  ASAI  : %12.6f                   ║\n', ASAI_R1);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  SAIFI 改善: %+10.4f 次/(户·年)           \n', SAIFI_R1-SAIFI);
fprintf('║  注：SAIFI_R2=SAIFI_R1 为物理正确          \n');
fprintf('║  SAIDI 改善: %+10.4f h/(户·年)             \n', SAIDI_R1-SAIDI);
fprintf('║  EENS  改善: %+10.2f MWh/年               \n', EENS_R1-EENS);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  重构恢复率（功率基）: %.1f%%              \n', rec_pct_power);
fprintf('║    完全恢复(q=1,L=0): %d 节点-场景对       \n', n_full_rec);
fprintf('║    部分恢复(q=1,L>0): %d 节点-场景对（切负荷）\n', n_part_rec);
fprintf('║    未恢复  (q=0)    : %d 节点-场景对       \n', n_unrec);
fprintf('║    受影响下游总计   : %d 节点-场景对       \n', n_aff_total);
fprintf('║  总切负荷量: %.4f pu·场景 (%.1f%%受影响功率)\n', ...
    total_shed_pu, total_shed_pu/max(aff_power,1e-9)*100);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  联络线=%d 条  容量=%.0f MW                \n', nTie, LINE_CAP);
fprintf('║  §5 MCF : %7.1f 秒                    \n', t_mcf_elapsed);
fprintf('║  §6 MILP: %7.1f 秒                    \n', t_milp_elapsed);
fprintf('║  总耗时 : %7.1f 秒                    \n', total_elapsed);
fprintf('╚══════════════════════════════════════════╝\n');

%% ── 代表性故障场景潮流+切负荷输出 ────────────────────────────────────────
[~, rep_xy] = max(sum(p_direct_d, 1));
fprintf('\n══════════════════════════════════════════════\n');
fprintf('  重构+切负荷后潮流（代表性故障场景 %d：分支 %d─%d）\n', ...
    rep_xy, inv_map(rel_branches(rep_xy,1)), inv_map(rel_branches(rep_xy,2)));
fprintf('══════════════════════════════════════════════\n');

Vm_rep = Vm_res(:, rep_xy);
Pf_rep = Pf_res(:, rep_xy);
Qf_rep = Qf_res(:, rep_xy);
Sw_rep = Sw_res(:, rep_xy);
qv_rep = q_mat(:, rep_xy);
pf_rep = full(p_feeder_d_full(:, rep_xy));
L_rep  = L_res(:, rep_xy);

% 切负荷节点详情
shed_nodes = find(L_rep > SHED_THRESH & qv_rep);
if ~isempty(shed_nodes)
    fprintf('\n  切负荷节点（切除量>%.4fpu）\n', SHED_THRESH);
    fprintf('  %-10s  %-12s  %-12s  %-10s\n', '节点编号','P_demand/kW','L_shed/kW','切除比例');
    fprintf('  %s\n', repmat('─',1,48));
    for k = shed_nodes'
        fprintf('  %-10d  %-12.2f  %-12.2f  %-10.1f%%\n', ...
            inv_map(load_nodes(k)), P_free(k)*1e3, L_rep(k)*1e3, ...
            L_rep(k)/P_free_safe(k)*100);
    end
end

% 节点电压表
fprintf('\n  节点电压幅值（pu）\n');
fprintf('  %-10s  %-10s  %-22s\n', '节点编号', '电压/pu', '状态');
fprintf('  %s\n', repmat('─',1,46));
for si = 1:length(subs_idx)
    fprintf('  %-10d  %-10.4f  变电站（源）\n', inv_map(subs_idx(si)), Vm_rep(subs_idx(si)));
end
for k = 1:nL
    if qv_rep(k)
        if pf_rep(k)>0 && L_rep(k)>SHED_THRESH
            st = sprintf('转供（切%.1f%%）', L_rep(k)/P_free_safe(k)*100);
        elseif pf_rep(k)>0
            st = '转供恢复';
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
fprintf('\n  合路分支潮流（kW / kVar）\n');
fprintf('  %-6s  %-6s  %-6s  %-12s  %-12s  %-8s\n', ...
    '分支#', 'From', 'To', 'P/kW', 'Q/kVar', '设备类型');
fprintf('  %s\n', repmat('─',1,62));
for b = 1:nB_all
    if Sw_rep(b) == 1
        if b <= nB_norm
            br_type = ternary(is_trf_vec(b), '变压器', '线路');
        else
            br_type = '联络线';
        end
        fprintf('  %-6d  %-6d  %-6d  %+12.2f  %+12.2f  %s\n', b, ...
            inv_map(all_branches(b,1)), inv_map(all_branches(b,2)), ...
            Pf_rep(b)*1e3, Qf_rep(b)*1e3, br_type);
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
