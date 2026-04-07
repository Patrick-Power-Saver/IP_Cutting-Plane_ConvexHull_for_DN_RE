%% ============================================================
%  配电网可靠性评估 —— R2+切负荷版（连续切负荷，最大恢复负荷）
%
%  在 R6（重构）基础上新增：
%    连续切负荷变量 L_mat（切负荷量，pu，范围 [0, P_demand]）
%    目标：最大化恢复负荷量（最小化切负荷量），同时满足潮流安全约束
%
%  ─── 关于"一步到位 vs 两阶段"的设计选择 ─────────────────────
%  本代码采用一步到位（单阶段 MILP 同时决策重构拓扑+切负荷量）。
%
%  两阶段方案（先重构后切负荷）逻辑上不自洽：
%    第一阶段"重构无解"的判断本身依赖于哪些节点需要供电（即哪些节点
%    被切负荷），而切哪个负荷又取决于网络拓扑，两者完全耦合，
%    无法分离为独立的两步。
%
%  一步到位方案：
%    引入 L_mat(k,xy) ∈ [0, P_demand(k)] 作为连续决策变量，
%    功率平衡约束改为：
%      A_free_all * Pf = Dp * Q_mat - L_mat     （切负荷后的净需求）
%    目标为最大化实际供给功率（最小化切负荷量）：
%      min Σ_{k,xy} L_mat(k,xy)  等价于  max Σ_{k,xy} (P_demand(k)*Q_mat - L_mat)
%
%  ─── 切负荷与 Q_mat 的关系 ───────────────────────────────────
%  Q_mat(k,xy)=0 → 节点 k 不在恢复拓扑中，L_mat 须同步为零（由 [0,Pd]*Q_mat 保证）
%  Q_mat(k,xy)=1 → 节点 k 在恢复拓扑中，L_mat ∈ [0, P_demand(k)]（切负荷起作用）
%  因此 L_mat 只在 Q_mat=1 的节点上有效，物理意义清晰。
%
%  §§  对应关系：
%    §1-§5  与 R6 完全相同（数据读取、拓扑构建、MCF 路径识别）
%    §6     新增 L_mat 变量和修改功率平衡约束、目标函数
%    §7     切负荷量纳入可靠性指标输出
%    §8     输出切负荷分布
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
LAMBDA_TRF = 0;

% ── 多阶段恢复时间参数（h）───────────────────────────────────
TAU_UP_SW  = 0.3;   % 上游开关操作恢复时间
TAU_TIE_SW = 0.5;   % 联络开关切换转供时间

% ── MCF 求解模式 ──────────────────────────────────────────────
SOLVE_MODE = 'MCF';

% ── 电压约束（pu）与功率因数 ────────────────────────────────
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
hdr_row = 0;
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
t_branch = t_branch(:,1:3); t_branch.Properties.VariableNames = {'From','To','Length_km'};
t_branch = t_branch(~isnan(t_branch.From), :);
t_dur = readtable(sys_filename, 'Sheet', 'Interruption durations (h)', 'HeaderLines', 3);
t_dur = t_dur(:,1:4); t_dur.Properties.VariableNames = {'From','To','RP','SW'};
t_dur = t_dur(~isnan(t_dur.From), :);
t_cust = readtable(sys_filename, 'Sheet', 'Numbers of customers per node');
t_cust = t_cust(:,1:2); t_cust.Properties.VariableNames = {'Node','NC'};
t_cust = t_cust(~isnan(t_cust.Node), :);
t_peak = readtable(sys_filename, 'Sheet', 'Peak Nodal Demands (kW)');
t_peak = t_peak(:,1:2); t_peak.Properties.VariableNames = {'Node','P_kW'};
t_peak = t_peak(~isnan(t_peak.Node), :);
t_other = readtable(sys_filename, 'Sheet', 'Other data', 'ReadVariableNames', false);
col1 = cellfun(@(x) string(x), t_other{:,1}, 'UniformOutput', true);
lambda_per_km = str2double(string(t_other{find(contains(col1,'Failure rate'),1), 2}));
row_dur = find(contains(col1,'Duration'), 1);
T_l = [str2double(string(t_other{row_dur,  3})), str2double(string(t_other{row_dur+1,3})), str2double(string(t_other{row_dur+2,3}))];
row_lf = find(contains(col1,'Loading factors'), 1);
L_f = [str2double(string(t_other{row_lf,  3})), str2double(string(t_other{row_lf+1,3})), str2double(string(t_other{row_lf+2,3}))] / 100;
fprintf('   lambda_line=%.4f/km, T_l=[%s]h, L_f=[%s]\n', lambda_per_km, num2str(T_l,'%g '), num2str(L_f,'%.2f '));

%% ================================================================
%  §3  潮流参数生成
% ================================================================
fprintf('>> [3/8] 生成潮流参数...\n');
R_KM = 0.003151; X_KM = 0.001526; TAN_PHI = tan(acos(PF));
V_src_sq = V_SRC^2; V_upper_sq = V_UPPER^2; V_lower_sq = V_LOWER^2;
M_V  = (V_upper_sq - V_lower_sq) * 2;
M_vn = V_upper_sq;
fprintf('   R=%.4f pu/km, X=%.4f pu/km, V∈[%.2f,%.2f] pu\n', R_KM, X_KM, V_LOWER, V_UPPER);
fprintf('   τ_UP_SW=%.2fh, τ_TIE_SW=%.2fh\n', TAU_UP_SW, TAU_TIE_SW);

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
nB_norm = height(t_branch); nTie = size(TIE_LINES_RAW,1); nB_all = nB_norm + nTie;

rel_branches = zeros(nB_norm, 8);
for b = 1:nB_norm
    u_raw = t_branch.From(b); v_raw = t_branch.To(b);
    u = node_map(u_raw); v = node_map(v_raw); len = t_branch.Length_km(b);
    match = (t_dur.From==u_raw & t_dur.To==v_raw) | (t_dur.From==v_raw & t_dur.To==u_raw);
    if ~any(match), error('找不到分支(%d-%d)的停电时间', u_raw, v_raw); end
    is_trf = ismember(u, subs_idx) | ismember(v, subs_idx);
    cap_b  = TRAN_CAP*is_trf + LINE_CAP*(~is_trf);
    lam_b  = ternary(LAMBDA_TRF>0 && is_trf, LAMBDA_TRF, len*lambda_per_km);
    rel_branches(b,:) = [u, v, lam_b, t_dur.RP(match), t_dur.SW(match), R_KM*len, X_KM*len, cap_b];
end
is_trf_vec = ismember(rel_branches(:,1), subs_idx) | ismember(rel_branches(:,2), subs_idx);

tie_branches = zeros(nTie, 8);
for t = 1:nTie
    u = node_map(TIE_LINES_RAW(t,1)); v = node_map(TIE_LINES_RAW(t,2));
    tie_branches(t,:) = [u, v, 0, 0, 0, R_KM*0.1, X_KM*0.1, LINE_CAP];
end

all_branches = [rel_branches; tie_branches];
branch_from = all_branches(:,1); branch_to = all_branches(:,2);
r_b_all = all_branches(:,6); x_b_all = all_branches(:,7); cap_b_all = all_branches(:,8);

load_nodes = setdiff(1:num_nodes, subs_idx); nL = length(load_nodes); non_sub = load_nodes;

A_inc_norm = sparse(rel_branches(:,2),(1:nB_norm)',+1,num_nodes,nB_norm) + sparse(rel_branches(:,1),(1:nB_norm)',-1,num_nodes,nB_norm);
A_inc_all  = sparse(branch_to,(1:nB_all)',+1,num_nodes,nB_all) + sparse(branch_from,(1:nB_all)',-1,num_nodes,nB_all);
A_free_all = A_inc_all(load_nodes, :);
B_to_all   = sparse((1:nB_all)',branch_to,  1,nB_all,num_nodes);
B_from_all = sparse((1:nB_all)',branch_from,1,nB_all,num_nodes);
BdV = B_to_all - B_from_all;

[~, pk_row] = ismember(inv_map(load_nodes), t_peak.Node);
P_free = zeros(nL,1); valid = pk_row>0;
P_free(valid) = t_peak.P_kW(pk_row(valid)) / 1e3;
Q_free = P_free * TAN_PHI;
fprintf('   正常分支=%d，联络线=%d，负荷节点=%d\n', nB_norm, nTie, nL);

%% ================================================================
%  §5  MCF 路径识别
% ================================================================
fprintf('>> [5/8] MCF 路径识别 (模式: %s)...\n', SOLVE_MODE);
t_mcf = tic;
nSub  = length(subs_idx);
E_sub = sparse(subs_idx, 1:nSub, 1, num_nodes, nSub);

if strcmp(SOLVE_MODE, 'MCF')
    E_load = sparse(load_nodes, 1:nL, 1, num_nodes, nL);
    F_mat = sdpvar(nB_norm,nL,'full'); Z_mat = sdpvar(nB_norm,nL,'full'); Gss = sdpvar(nSub,nL,'full');
    C_mcf = [-Z_mat<=F_mat, F_mat<=Z_mat, Z_mat>=0, 0<=Gss<=1, sum(Gss,1)==1, A_inc_norm*F_mat==E_load-E_sub*Gss];
    sol = optimize(C_mcf, sum(sum(Z_mat)), sdpsettings('solver','gurobi','verbose',0));
    if sol.problem ~= 0, error('MCF 失败: %s', sol.info); end
    f_res = sparse(abs(value(F_mat)) > 0.5);
else
    f_res = false(nB_norm, nL); opts_sp = sdpsettings('solver','gurobi','verbose',0);
    parfor k=1:nL
        f_k=sdpvar(nB_norm,1); z_k=sdpvar(nB_norm,1); g_k=sdpvar(nSub,1);
        d_k=sparse(load_nodes(k),1,1,num_nodes,1)-E_sub*g_k;
        C_k=[-z_k<=f_k,f_k<=z_k,z_k>=0,0<=g_k<=1,sum(g_k)==1,A_inc_norm*f_k==d_k];
        optimize(C_k,sum(z_k),opts_sp); f_res(:,k)=abs(value(f_k))>0.5;
    end
    f_res = sparse(f_res);
end

p_mat = f_res';   % nL×nB_norm，下游受影响（p_direct）

is_outlet = ismember(rel_branches(:,1),subs_idx) | ismember(rel_branches(:,2),subs_idx);
p_feeder_mat = sparse(nL, nB_norm);
for xy = 1:nB_norm
    dn_k = find(p_mat(:,xy), 1); if isempty(dn_k), continue; end
    for bi = find(f_res(:,dn_k))'
        if is_outlet(bi), p_feeder_mat(:,xy) = f_res(bi,:)'; break; end
    end
end
p_feeder_mat = sparse(p_feeder_mat);
t_mcf_elapsed = toc(t_mcf);
fprintf('   MCF 完成（%.1f 秒），p_direct nnz=%d，p_feeder nnz=%d\n', t_mcf_elapsed, nnz(p_mat), nnz(p_feeder_mat));

%% ================================================================
%  §6  批量场景 MILP — 网络重构 + 连续切负荷（一步到位）
%
%  新增决策变量：
%    L_mat  (nL×nScen) cont.≥0  切负荷量（pu，范围 [0, P_demand(k)]）
%
%  修改的约束：
%    [34-35] 功率平衡（加入切负荷）：
%      A_free_all * Pf_mat = Dp * Q_mat - L_mat
%      A_free_all * Qf_mat = Dq_ * Q_mat - L_mat * TAN_PHI
%      说明：恢复节点的实际供给 = 原始需求×恢复状态 - 主动切除量
%
%  新增约束：
%    L_mat(k,xy) ∈ [0, P_demand(k) * Q_mat(k,xy)]
%      切负荷量受恢复状态约束：q=0 时 L=0（未恢复节点不参与调度）；
%      q=1 时 L ∈ [0, P_demand]（可选择切除 0~全部需求）
%      此约束为双线性，线性化为：L_mat ≤ P_diag * Q_mat
%                              0 ≤ L_mat ≤ P_diag * ones(nScen,1)
%
%  修改的目标函数（最大化恢复负荷 = 最小化切负荷量）：
%    原：min -sum(sum(Q_mat))  （最大化恢复节点数，忽略节点负荷大小）
%    新：min sum(sum(L_mat))   （最小化切负荷量之和，考虑负荷大小）
%    两者本质一致：都鼓励向更多用户供电，新目标更合理（重负荷节点优先恢复）
% ================================================================
fprintf('>> [6/8] 批量场景 MILP（%d 场景，含连续切负荷）...\n', nB_norm);
t_milp = tic;

nScen      = nB_norm;
p_mat_d    = double(p_mat);
p_feeder_d = double(p_feeder_mat);

Dr  = spdiags(r_b_all,  0,nB_all,nB_all); Dx  = spdiags(x_b_all,  0,nB_all,nB_all);
Dp  = spdiags(P_free,   0,nL,nL);         Dq_ = spdiags(Q_free,   0,nL,nL);
Cap = spdiags(cap_b_all,0,nB_all,nB_all);
DpQ = spdiags(Q_free,   0,nL,nL);         % 无功需求对角阵（用于切负荷无功）

% 批量决策变量
S_mat   = binvar(nB_all,    nScen, 'full');
Q_mat   = binvar(nL,        nScen, 'full');
Pf_mat  = sdpvar(nB_all,    nScen, 'full');
Qf_mat  = sdpvar(nB_all,    nScen, 'full');
V_mat   = sdpvar(num_nodes, nScen, 'full');
E_vdrop = sdpvar(nB_all,    nScen, 'full');
L_mat   = sdpvar(nL,        nScen, 'full');   % ★ 新增：连续切负荷量（pu）

delta_mat     = BdV*V_mat + 2*(Dr*Pf_mat + Dx*Qf_mat);
fault_lin_idx = (0:nB_norm-1)*nB_all + (1:nB_norm);

% 节点需求上界矩阵（用于切负荷上界约束）
P_max_mat = repmat(P_free, 1, nScen);   % nL×nScen，每列相同

C = [V_mat(subs_idx,:)    == V_src_sq,                      ...  % [C4] 子站电压
     V_mat(non_sub,:)     >= V_lower_sq - M_vn*(1-Q_mat),   ...  % [C3] 条件电压下限
     V_mat(non_sub,:)     <= V_upper_sq + M_vn*(1-Q_mat),   ...  % [C3] 条件电压上限
     -Cap*S_mat           <= Pf_mat <= Cap*S_mat,            ...  % [7-10] 容量约束
     -Cap*S_mat           <= Qf_mat <= Cap*S_mat,            ...
     A_free_all*Pf_mat    == Dp*Q_mat - L_mat,               ...  % [34] 有功平衡（含切负荷）
     A_free_all*Qf_mat    == Dq_*Q_mat - TAN_PHI*L_mat,      ...  % [35] 无功平衡（含切负荷）
     E_vdrop              >= 0,                              ...
     delta_mat            <=  M_V*(1-S_mat) + E_vdrop,       ...  % [36] 电压降落
     delta_mat            >= -M_V*(1-S_mat) - E_vdrop,       ...
     sum(S_mat,1)         == sum(Q_mat,1),                   ...  % [11] 辐射约束
     S_mat(fault_lin_idx) == 0,                              ...  % [12] 故障断开
     Q_mat                >= 1 - p_feeder_d,                 ...  % [13] 非馈线节点恢复
     L_mat                >= 0,                              ...  % ★ 切负荷非负
     L_mat                <= P_max_mat .* Q_mat];                 % ★ 切负荷上界（q=0时L=0）

alpha_vdrop = 1e-4;
opts_milp   = sdpsettings('solver','gurobi','verbose',0,'gurobi.MIPGap',1e-3);

% 目标：最小化切负荷量（最大化恢复功率）+ 极小松弛惩罚
%   sum(P_free.*Q_mat - L_mat) → 等价于 max 实际供给功率
objective = sum(sum(L_mat)) + alpha_vdrop*sum(E_vdrop(:));
sol = optimize(C, objective, opts_milp);

if sol.problem == 0
    Qv = value(Q_mat);
    if any(isnan(Qv(:)))
        warning('[§6] Q_mat 含 NaN，退化为无重构无切负荷');
        q_mat  = logical(1 - p_feeder_d); L_res = zeros(nL, nScen);
        Pf_res = zeros(nB_all,nScen); Qf_res = zeros(nB_all,nScen);
        Vm_res = repmat(V_src_sq,num_nodes,nScen); Sw_res = zeros(nB_all,nScen);
    else
        q_mat  = logical(round(Qv));
        L_res  = max(value(L_mat), 0);   % 切负荷结果（nL×nScen）
        Pf_res = value(Pf_mat); Qf_res = value(Qf_mat);
        Vm_res = sqrt(max(value(V_mat), 0));
        Sw_res = round(value(S_mat));
    end
else
    warning('[§6] MILP 求解失败: %s', sol.info);
    q_mat  = logical(1 - p_feeder_d); L_res = zeros(nL, nScen);
    Pf_res = zeros(nB_all,nScen); Qf_res = zeros(nB_all,nScen);
    Vm_res = repmat(V_src_sq,num_nodes,nScen); Sw_res = zeros(nB_all,nScen);
end

% 重构统计
n_affected  = full(sum(p_mat_d(:) > 0));
n_recovered = full(sum(sum(logical(p_mat_d) & q_mat)));
rec_pct     = n_recovered / max(n_affected, 1) * 100;
total_shed_pu = sum(sum(L_res));   % 所有场景总切负荷量（pu·场景）

t_milp_elapsed = toc(t_milp);
fprintf('   MILP 完成（%.1f 秒），重构恢复率=%.1f%% (%d/%d)，总切负荷=%.3f pu·场景\n', ...
    t_milp_elapsed, rec_pct, n_recovered, n_affected, total_shed_pu);

%% ================================================================
%  §7  可靠性指标计算（三阶段恢复模型，含切负荷修正）
%
%  切负荷对 CID 的影响：
%    切负荷节点虽然在恢复拓扑中（q=1），但仍有部分负荷未供电。
%    精确 CID 应使用实际供给比率，此处简化：
%      已恢复节点（q=1）按 τ_TIE_SW 计算停电时长（不区分切负荷比例）
%      切负荷对 EENS 的贡献单独统计
% ================================================================
fprintf('>> [7/8] 计算可靠性指标（含切负荷）...\n');

lam = rel_branches(:,3); trp = rel_branches(:,4);
p_direct_d   = double(p_mat);
q_mat_d      = double(q_mat);
p_upstream_d = full(p_feeder_d) - p_direct_d;

[~, c_row] = ismember(inv_map(load_nodes), t_cust.Node);
NC_vec = zeros(1,nL); NC_vec(c_row>0) = t_cust.NC(c_row(c_row>0))';

[~, p_row] = ismember(inv_map(load_nodes), t_peak.Node);
P_avg_vec = zeros(1,nL);
P_avg_vec(p_row>0) = t_peak.P_kW(p_row(p_row>0))' .* sum(L_f .* (T_l/8760));

total_cust = sum(NC_vec);

% R2 指标（含重构+切负荷，三阶段模型）
CIF = p_feeder_d * lam;
CID = TAU_UP_SW  * (p_upstream_d * lam) ...
    + TAU_TIE_SW * (p_direct_d .* q_mat_d) * lam ...
    + (p_direct_d .* (1-q_mat_d)) * (lam .* trp);
SAIFI = sum(NC_vec .* CIF') / total_cust;
SAIDI = sum(NC_vec .* CID') / total_cust;
EENS  = sum(P_avg_vec .* CID') / 1e3;
ASAI  = 1 - SAIDI / 8760;

% EENS_shed：切负荷引起的额外能量损失（仅计算恢复期间 τ_TIE_SW 内的切负荷）
%   对每个场景 xy，已恢复节点（q=1）中切负荷量 L_res(k,xy) 停电 τ_TIE_SW
EENS_shed = sum(sum(L_res .* q_mat_d)) * TAU_TIE_SW * sum(lam) / nScen / 1e3;

% R1 基准（无重构无切负荷）
CIF_R1   = p_feeder_d * lam;
CID_R1   = TAU_UP_SW * (p_upstream_d * lam) + p_direct_d * (lam .* trp);
SAIFI_R1 = sum(NC_vec .* CIF_R1') / total_cust;
SAIDI_R1 = sum(NC_vec .* CID_R1') / total_cust;
EENS_R1  = sum(P_avg_vec .* CID_R1') / 1e3;
ASAI_R1  = 1 - SAIDI_R1 / 8760;

%% ================================================================
%  §8  结果输出
% ================================================================
total_elapsed = toc(program_total);

fprintf('\n╔══════════════════════════════════════════╗\n');
fprintf('  系统: %-39s\n', sys_filename);
fprintf('  τ_UP_SW=%.2fh, τ_TIE_SW=%.2fh（三阶段）\n', TAU_UP_SW, TAU_TIE_SW);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  [R2 含重构+切负荷]                       ║\n');
fprintf('║  SAIFI : %10.4f  次/(户·年)         ║\n', SAIFI);
fprintf('║  SAIDI : %10.4f  h/(户·年)          ║\n', SAIDI);
fprintf('║  EENS  : %10.2f  MWh/年             ║\n', EENS);
fprintf('║  EENS_shed: %8.2f  MWh/年（切负荷）  ║\n', EENS_shed);
fprintf('║  ASAI  : %12.6f                   ║\n', ASAI);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  [R1 不含重构]                            ║\n');
fprintf('║  SAIFI : %10.4f  次/(户·年)         ║\n', SAIFI_R1);
fprintf('║  SAIDI : %10.4f  h/(户·年)          ║\n', SAIDI_R1);
fprintf('║  EENS  : %10.2f  MWh/年             ║\n', EENS_R1);
fprintf('║  ASAI  : %12.6f                   ║\n', ASAI_R1);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  SAIDI 改善: %+10.4f h/(户·年)             \n', SAIDI_R1-SAIDI);
fprintf('║  EENS  改善: %+10.2f MWh/年               \n', EENS_R1-EENS);
fprintf('║  重构恢复率: %.1f%% (%d/%d)                \n', rec_pct, n_recovered, n_affected);
fprintf('║  总切负荷量: %.4f pu·场景               \n', total_shed_pu);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  联络线=%d 条  容量=%.0f MW                \n', nTie, LINE_CAP);
fprintf('║  §5 MCF : %7.1f 秒                    \n', t_mcf_elapsed);
fprintf('║  §6 MILP: %7.1f 秒                    \n', t_milp_elapsed);
fprintf('║  总耗时 : %7.1f 秒                    \n', total_elapsed);
fprintf('╚══════════════════════════════════════════╝\n');

% 代表性场景潮流+切负荷输出
[~, rep_xy] = max(sum(p_mat_d,1));
fprintf('\n══════════════════════════════════════════════\n');
fprintf('  重构+切负荷后潮流（代表性故障场景 %d）\n', rep_xy);
fprintf('══════════════════════════════════════════════\n');

Vm_rep = Vm_res(:,rep_xy); Pf_rep = Pf_res(:,rep_xy); Qf_rep = Qf_res(:,rep_xy);
Sw_rep = Sw_res(:,rep_xy); qv_rep = q_mat(:,rep_xy);
pf_rep = full(p_feeder_d(:,rep_xy)); L_rep = L_res(:,rep_xy);

% 切负荷节点列表
shed_nodes = find(L_rep > 1e-4);
if ~isempty(shed_nodes)
    fprintf('\n  切负荷节点（切除量 > 0.0001 pu）\n');
    fprintf('  %-10s  %-14s  %-14s  %-10s\n', '节点编号','P_demand/kW','L_shed/kW','切除比例');
    fprintf('  %s\n', repmat('─',1,52));
    for k = shed_nodes'
        fprintf('  %-10d  %-14.2f  %-14.2f  %-10.1f%%\n', ...
            inv_map(load_nodes(k)), P_free(k)*1e3, L_rep(k)*1e3, L_rep(k)/max(P_free(k),1e-9)*100);
    end
end

% 节点电压表（供电节点）
fprintf('\n  节点电压幅值（pu）\n');
fprintf('  %-10s  %-10s  %-20s\n', '节点编号', '电压/pu', '状态');
fprintf('  %s\n', repmat('─',1,44));
for si = 1:length(subs_idx)
    fprintf('  %-10d  %-10.4f  变电站\n', inv_map(subs_idx(si)), Vm_rep(subs_idx(si)));
end
for k = 1:nL
    if qv_rep(k)
        if pf_rep(k)>0 && L_rep(k)>1e-4
            st = sprintf('转供（切%.1f%%）', L_rep(k)/max(P_free(k),1e-9)*100);
        elseif pf_rep(k)>0
            st = '转供恢复';
        else
            st = '正常供电';
        end
        fprintf('  %-10d  %-10.4f  %s\n', inv_map(load_nodes(k)), Vm_rep(load_nodes(k)), st);
    end
end
n_dark = sum(~qv_rep & pf_rep>0);
if n_dark>0, fprintf('  （%d 个受影响节点未恢复，略去）\n', n_dark); end

% 分支潮流表
fprintf('\n  合路分支潮流（kW / kVar）\n');
fprintf('  %-6s  %-6s  %-6s  %-12s  %-12s  %-8s\n','分支#','From','To','P/kW','Q/kVar','类型');
fprintf('  %s\n', repmat('─',1,60));
for b = 1:nB_all
    if Sw_rep(b)==1
        br_type = ternary(b<=nB_norm, ternary(is_trf_vec(b),'变压器','线路'), '联络线');
        fprintf('  %-6d  %-6d  %-6d  %+12.2f  %+12.2f  %s\n', b, ...
            inv_map(all_branches(b,1)), inv_map(all_branches(b,2)), ...
            Pf_rep(b)*1e3, Qf_rep(b)*1e3, br_type);
    end
end

%% ── 辅助内联函数 ─────────────────────────────────────────────
function out = ternary(cond, a, b)
    if cond, out = a; else, out = b; end
end
