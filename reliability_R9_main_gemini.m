%% ============================================================
%  配电网可靠性评估 —— R9+离散切负荷（功能完全体）
%  1. 目标函数：科学 VOLL (Value of Lost Load) 差异化权重
%  2. 切负荷：参考 R8b 离散 5 档位建模 (0, 25%, 50%, 75%, 100%)
%  3. 输出格式：严格遵循 R9 原始格式（含 R1/R2 对比、SAIDI 分解、分支潮流表）
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

LAMBDA_TRF = 0.5;   % 变压器故障率
TAU_UP_SW  = 0.3;   % 上游开关操作时间
TAU_TIE_SW = 0.5;   % 联络线开关操作时间
BETA_SHED  = 1.0;   % R9 原始权重系数

% 离散切负荷档位
SHED_LEVELS  = [0, 0.25, 0.50, 0.75, 1.00];   
N_LEVELS     = length(SHED_LEVELS);

V_UPPER = 1.2; V_LOWER = 0.8; V_SRC = 1.0; PF = 0.9;
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
%  §5 MCF 路径识别
% ================================================================
fprintf('>> [5/8] MCF 路径识别...\n');
nSub = length(subs_idx); E_sub = sparse(subs_idx, 1:nSub, 1, num_nodes, nSub); E_load = sparse(load_nodes, 1:nL, 1, num_nodes, nL);
F_mcf = sdpvar(nB_norm, nL, 'full'); Z_mcf = sdpvar(nB_norm, nL, 'full'); Gss = sdpvar(nSub, nL, 'full');
C_mcf = [-Z_mcf <= F_mcf, F_mcf <= Z_mcf, Z_mcf >= 0, 0 <= Gss <= 1, sum(Gss,1) == 1, (sparse(rel_branches(:,2), (1:nB_norm)', 1, num_nodes, nB_norm) + sparse(rel_branches(:,1), (1:nB_norm)', -1, num_nodes, nB_norm)) * F_mcf == E_load - E_sub*Gss];
sol_mcf = optimize(C_mcf, sum(sum(Z_mcf)), sdpsettings('solver','gurobi','verbose',0));
f_res = sparse(abs(value(F_mcf)) > 0.5); p_mat = f_res';
is_outlet = ismember(rel_branches(:,1), subs_idx) | ismember(rel_branches(:,2), subs_idx);
p_feeder_mat = sparse(nL, nB_norm);
for xy = 1:nB_norm
    dn_k = find(p_mat(:,xy), 1); if isempty(dn_k), continue; end
    for bi = find(f_res(:, dn_k))', if is_outlet(bi), p_feeder_mat(:,xy) = f_res(bi,:)'; break; end, end
end
t_mcf_elapsed = toc(program_total);

%% ================================================================
%  §6 批量场景 MILP（VOLL + 离散切负荷）
% ================================================================
fprintf('>> [6/8] 批量场景 MILP 求解...\n');
t_milp_start = tic;
nScen = nB_norm; p_mat_d = double(p_mat); p_feeder_d = double(p_feeder_mat);
lam_vec = rel_branches(:,3); trp_vec = rel_branches(:,4);
[~, c_row_pre] = ismember(inv_map(load_nodes), t_cust.Node);
NC_vec = zeros(nL, 1); NC_vec(c_row_pre>0) = t_cust.NC(c_row_pre(c_row_pre>0));

% R9 负荷分级与 VOLL
load_types = 2 * ones(nL, 1); % 默认二级 (≤25% 切除)
idx_L1 = 1:min(round(nL*0.5), nL); idx_L3 = max(nL-round(nL*0.75), 1):nL;
load_types(idx_L1) = 1; load_types(idx_L3) = 3;
shed_limit_dict = [0.0; 0.1; 0.5]; voll_dict = [100; 20; 5];
shed_limit_vec = shed_limit_dict(load_types); voll_vec = voll_dict(load_types);

W_cid = (NC_vec .* p_mat_d) .* (lam_vec .* max(trp_vec - TAU_TIE_SW, 0))';
W_shed_voll = (voll_vec .* NC_vec .* p_mat_d) .* (lam_vec * BETA_SHED)';

fprintf('   W_cid: max=%.4f, mean=%.4f, nnz=%d\n', ...
    full(max(W_cid(:))), ...
    full(sum(W_cid(:))/max(nnz(W_cid), 1)), ...
    full(nnz(W_cid)));
fprintf('   (相比等权目标，CID最小化对高客户数/高故障率/长修复时间节点优先恢复)\n');

% 决策变量
S_mat = binvar(nB_all, nScen, 'full'); Q_mat = binvar(nL, nScen, 'full');
Pf_mat = sdpvar(nB_all, nScen, 'full'); Qf_mat = sdpvar(nB_all, nScen, 'full');
V_mat = sdpvar(num_nodes, nScen, 'full'); E_vdrop = sdpvar(nB_all, nScen, 'full');
ZZ_mat = binvar(nL*N_LEVELS, nScen, 'full'); L_mat = sdpvar(nL, nScen, 'full');

% 离散映射矩阵
idx_k = repelem((1:nL)', N_LEVELS); idx_m = repmat((1:N_LEVELS)', nL, 1);
SEL = sparse(idx_k, (1:nL*N_LEVELS)', P_free(idx_k).*SHED_LEVELS(idx_m)', nL, nL*N_LEVELS);
ONESUM = sparse(idx_k, (1:nL*N_LEVELS)', 1, nL, nL*N_LEVELS);

delta_mat = BdV*V_mat + 2*(spdiags(r_b_all,0,nB_all,nB_all)*Pf_mat + spdiags(x_b_all,0,nB_all,nB_all)*Qf_mat);
fault_lin_idx = (0:nB_norm-1)*nB_all + (1:nB_norm);

C = [V_mat(subs_idx,:) == V_src_sq, V_mat(non_sub,:) >= V_lower_sq - M_vn*(1-Q_mat), V_mat(non_sub,:) <= V_upper_sq + M_vn*(1-Q_mat), ...
     -spdiags(cap_b_all,0,nB_all,nB_all)*S_mat <= Pf_mat <= spdiags(cap_b_all,0,nB_all,nB_all)*S_mat, ...
     -spdiags(cap_b_all,0,nB_all,nB_all)*S_mat <= Qf_mat <= spdiags(cap_b_all,0,nB_all,nB_all)*S_mat, ...
     A_free_all*Pf_mat == spdiags(P_free,0,nL,nL)*Q_mat - L_mat, A_free_all*Qf_mat == spdiags(Q_free,0,nL,nL)*Q_mat - TAN_PHI*L_mat, ...
     E_vdrop >= 0, delta_mat <= M_V*(1-S_mat) + E_vdrop, delta_mat >= -M_V*(1-S_mat) - E_vdrop, ...
     sum(S_mat,1) == sum(Q_mat,1), S_mat(fault_lin_idx) == 0, Q_mat >= 1 - p_feeder_d, ...
     L_mat == SEL * ZZ_mat, ONESUM * ZZ_mat == 1, L_mat <= repmat(P_free, 1, nScen).*Q_mat];

% 锁定非法档位
for k = 1:nL
    invalid_m = find(SHED_LEVELS > shed_limit_vec(k) + 1e-6);
    if ~isempty(invalid_m), C = [C, ZZ_mat((k-1)*N_LEVELS + invalid_m, :) == 0]; end
end

sol = optimize(C, -sum(sum(W_cid.*Q_mat)) + sum(sum(W_shed_voll.*L_mat)) + 1e-4*sum(E_vdrop(:)), sdpsettings('solver','gurobi','verbose',0));
q_mat_d = double(logical(round(value(Q_mat)))); L_res = max(value(L_mat), 0); ZZ_res = round(value(ZZ_mat));

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

t_milp_elapsed = toc(t_milp_start);
fprintf('   MILP 完成（%.1f 秒）\n', t_milp_elapsed);
fprintf('   节点恢复分类: 完全恢复=%d, 部分恢复(切负荷)=%d, 未恢复=%d / 受影响=%d\n', ...
    n_full_rec, n_part_rec, n_unrec, n_aff_total);
fprintf('   功率基恢复率=%.1f%% (净恢复%.3f/受影响%.3f pu·场景)\n', ...
    rec_pct_power, net_rec_power, aff_power);
fprintf('   总切负荷量=%.4f pu·场景 (占受影响功率%.1f%%)\n', ...
    total_shed_pu, total_shed_pu/max(aff_power,1e-9)*100);

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
%% ================================================================
%  §7  可靠性指标计算 (含 R1/R2 对比与四项分解)
% ================================================================
p_upstream_d = p_feeder_d - p_mat_d;   % 仅上游节点

% 处理客户数向量
[~, c_row] = ismember(inv_map(load_nodes), t_cust{:, 1});
NC_vec = zeros(nL, 1);
NC_vec(c_row > 0) = t_cust{c_row(c_row > 0), 2};

% 处理平均负荷向量
P_avg_vec = zeros(nL, 1);
P_avg_vec(pk_row > 0) = t_peak{pk_row(pk_row > 0), 2} * sum(L_f .* (T_l/8760));

total_cust = sum(NC_vec);
P_free_safe = max(P_free, 1e-9);
shed_ratio = (L_res ./ repmat(P_free_safe, 1, nScen)) .* q_mat_d .* p_mat_d;

% --- R2 指标 (含重构+切负荷) ---
CIF = p_feeder_d * lam_vec;
CID_upstream = TAU_UP_SW * (p_upstream_d * lam_vec);
CID_tieline  = TAU_TIE_SW * (p_mat_d .* q_mat_d) * lam_vec;
CID_repair   = (p_mat_d .* (1-q_mat_d)) * (lam_vec .* trp_vec);
CID_shed_add = (shed_ratio .* p_mat_d .* q_mat_d) * (lam_vec .* (trp_vec - TAU_TIE_SW));
CID = CID_upstream + CID_tieline + CID_repair + CID_shed_add;

SAIFI = (NC_vec' * CIF) / total_cust;
SAIDI = (NC_vec' * CID) / total_cust;
EENS  = (P_avg_vec' * CID) / 1e3;
ASAI  = 1 - SAIDI / 8760;

% --- R1 指标 (无重构) ---
CID_R1 = TAU_UP_SW * (p_upstream_d * lam_vec) + p_mat_d * (lam_vec .* trp_vec);
CIF = p_feeder_d * lam_vec;
SAIFI_R1 = (NC_vec' * CIF) / total_cust;
SAIDI_R1 = (NC_vec' * CID_R1) / total_cust;
EENS_R1  = (P_avg_vec' * CID_R1) / 1e3;
ASAI_R1  = 1 - SAIDI_R1 / 8760;

%% ── 分项CID贡献（便于理解切负荷的影响）─────────────────────────────────
CID_upstream = TAU_UP_SW * (p_upstream_d * lam_vec);            % ①项，nL×1
CID_tieline  = TAU_TIE_SW * (p_direct_d .* q_mat_d) * lam_vec; % ②项
CID_repair   = (p_direct_d .* (1-q_mat_d)) * (lam_vec .* trp_vec); % ③项
CID_shed_add = (shed_ratio .* p_direct_d .* q_mat_d) * (lam_vec .* (trp_vec - TAU_TIE_SW)); % ④项

SAIDI_contrib_up   = sum(NC_vec' .* CID_upstream') / total_cust;
SAIDI_contrib_tie  = sum(NC_vec' .* CID_tieline')  / total_cust;
SAIDI_contrib_rep  = sum(NC_vec' .* CID_repair')   / total_cust;
SAIDI_contrib_shed = sum(NC_vec' .* CID_shed_add') / total_cust;

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
fprintf('║  注：SAIFI_R2=SAIFI_R1 为物理正确。         \n');
fprintf('║      重构仅缩短停电时长，不减少中断次数。    \n');
fprintf('║  注：τ_UP_SW=%.2fh，τ_TIE_SW=%.2fh（三阶段）  \n', TAU_UP_SW, TAU_TIE_SW);
fprintf('║  SAIDI 改善: %+10.4f h/(户·年)             \n', SAIDI_R1-SAIDI);
fprintf('║  EENS  改善: %+10.2f MWh/年               \n', EENS_R1-EENS);
fprintf('║  重构恢复率（功率基）: %.1f%%              \n', rec_pct_power);
fprintf('║    完全恢复(q=1,L=0): %d 节点-场景对       \n', n_full_rec);
fprintf('║    部分恢复(q=1,L>0): %d 节点-场景对（切负荷）\n', n_part_rec);
fprintf('║    未恢复  (q=0)    : %d 节点-场景对       \n', n_unrec);
fprintf('║    受影响下游总计   : %d 节点-场景对       \n', n_aff_total);
fprintf('║  总切负荷量: %.4f pu·场景 (%.1f%%受影响功率)\n', ...
    total_shed_pu, total_shed_pu/max(aff_power,1e-9)*100);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  联络线=%d 条  容量=%.0f MW                \n', nTie, LINE_CAP);
fprintf('║  负荷节点=%d  故障场景=%d                  \n', nL, nB_norm);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  §5 MCF : %7.1f 秒                    \n', t_mcf_elapsed);
fprintf('║  §6 MILP: %7.1f 秒                    \n', t_milp_elapsed);
fprintf('║  总耗时 : %7.1f 秒                    \n', total_elapsed);
fprintf('╚══════════════════════════════════════════╝\n');

%% ── 代表性故障场景潮流+切负荷输出 ────────────────────────────────────────
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