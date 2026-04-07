%% ============================================================
%  配电网可靠性评估 —— R2+切负荷版（差异化优先级+离散切负荷，5档）
%
%  在 R8a（连续切负荷）基础上新增：
%    1. 负荷优先级（A/B/C 类随机划分，差异化停电时间上限约束）
%    2. 离散切负荷（每节点预设 5 个档位，用 SOS-2 或整数建模）
%
%  ─── 负荷优先级分类 ──────────────────────────────────────────
%  A类（约1/3节点）：关键负荷，停电时间约束为0
%    → 必须通过重构实现转供（q=1）且切负荷量为0
%    → 即 Q_mat(A,xy)=1 且 L_mat(A,xy)=0  ∀p_direct(A,xy)=1
%
%  B类（约1/3节点）：重要负荷，停电时间 ≤ τ_B（默认0.5h = τ_TIE_SW）
%    → 必须通过重构转供（q=1），允许切部分负荷
%    → 即 Q_mat(B,xy)=1  ∀p_direct(B,xy)=1
%
%  C类（约1/3节点）：一般负荷，停电时间 ≤ τ_C（默认1.0h）
%    → 如果停电时间超过τ_C，则必须通过重构转供；
%      但转供后停电时间仍为 τ_TIE_SW=0.5h，已满足≤1h，约束自动满足
%    → 若无法转供，则由维修恢复（τ_RP~2h）违反约束
%    → 因此：若p_direct(C,xy)=1，也必须 q=1（转供） 或接受维修等待
%      严格执行：p_direct(C,xy)=1 时要求 q=1（与A/B类相同，只是允许更多切负荷）
%
%  实际约束实现（对每个故障场景 xy）：
%    A类：p_direct(k,xy)=1 → Q_mat(k,xy)=1 且 L_mat(k,xy)=0
%    B类：p_direct(k,xy)=1 → Q_mat(k,xy)=1 且 L_mat(k,xy)≤P_B_shed_limit
%    C类：p_direct(k,xy)=1 → Q_mat(k,xy)=1（必须转供）
%
%  注意：A类停电时间约束为0，意味着这些节点在任何故障后都必须通过
%  联络线快速恢复（τ_TIE_SW=0.5h），这对联络线容量要求极高；
%  若系统物理上不能满足（容量或电压违约），则 MILP 不可行。
%
%  ─── 离散切负荷（5档）─────────────────────────────────────────
%  对每个节点 k，预设 5 个切负荷档位（占峰值需求的比例）：
%    levels = [0, 0.25, 0.50, 0.75, 1.00]
%  即切除 0%/25%/50%/75%/100% 的负荷。
%
%  建模方式：引入二进制选择变量 Z_mat(k,5,xy)，每场景每节点选1档。
%    L_mat(k,xy) = Σ_m levels(m) * P_free(k) * Z_mat(k,m,xy)
%    Σ_m Z_mat(k,m,xy) = 1  （选且仅选一档）
%
%  变量规模（85节点）：
%    Z_mat: nL×5×nScen = 83×5×84 ≈ 34,860 个二进制变量（额外）
%    合计约 50K 二进制变量，Gurobi 可在几分钟内求解
%
%  ─── 目标函数（加权切负荷最小化）─────────────────────────────
%  对不同优先级赋不同权重，体现"优先保障关键负荷"：
%    min  w_A * Σ_{A类} L_mat  +  w_B * Σ_{B类} L_mat  +  w_C * Σ_{C类} L_mat
%  典型权重：w_A=10, w_B=3, w_C=1
%  高权重使 A 类切负荷成本极大，优化器会优先避免切 A 类。
%
%  注：使用"切负荷量最小化"而非"负荷损失最小化"（EENS），理由：
%  恢复阶段各节点停电时长（τ_TIE_SW）相同，最小化切负荷等价于
%  最小化能量损失，且无需引入时间系数，建模更简洁。
%
%  §§  与 R8a 的区别：
%    §6  切负荷变量从连续改为 5 档离散（引入 Z_mat），增加优先级约束
%    §7  CID/EENS 增加按优先级分类输出
%    §8  输出按优先级的切负荷统计
%
%  依赖: YALMIP + Gurobi
% =============================================================
clear; clc;

%% ============================================================
%  ★  用户配置区  ★
% ============================================================

% ── 系统文件 ──────────────────────────────────────────────────
sys_filename = '85-Node System Data.xlsx';
%sys_filename = '417-Node System Data.xlsx';
%sys_filename = '1080-Node System Data.xlsx';
tb_filename = 'Testbench for Linear Model Based Reliability Assessment Method for Distribution Optimization Models Considering Network Reconfiguration.xlsx';
sys_sheet = '85-node';
%sys_sheet = '417-node';
%sys_sheet = '1080-node';

% ── 变压器故障率 ──────────────────────────────────────────────
LAMBDA_TRF = 0;

% ── 多阶段恢复时间参数（h）───────────────────────────────────
TAU_UP_SW  = 0.3;   % 上游开关操作恢复时间
TAU_TIE_SW = 0.5;   % 联络开关切换转供时间

% ── 负荷优先级分类 ────────────────────────────────────────────
%  随机划分比例（A:B:C ≈ 1:1:1）
%  停电时间上限：A=0h（必须重构无切负荷）, B=0.5h, C=1.0h
TAU_LIMIT_B  = 0.5;    % B类停电时间上限（h）
TAU_LIMIT_C  = 1.0;    % C类停电时间上限（h）
PRIORITY_SEED = 42;    % 随机划分种子（固定可重现）

% B类切负荷上限比例（允许切除的最大比例）
SHED_LIMIT_B = 0.5;    % B类最多切50%负荷
SHED_LIMIT_C = 1.0;    % C类最多切100%负荷（可完全切除）

% ── 离散切负荷档位（5档，占峰值需求的比例）─────────────────
SHED_LEVELS  = [0, 0.25, 0.50, 0.75, 1.00];   % 5 个离散档位
N_LEVELS     = length(SHED_LEVELS);

% ── 加权目标函数权重（A:B:C）────────────────────────────────
W_A = 10;   W_B = 3;   W_C = 1;

% ── 其他参数 ──────────────────────────────────────────────────
SOLVE_MODE = 'MCF';
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
    v1 = tb_cell{ri,1}; v2 = tb_cell{ri,2};
    if isnumeric(v1) && ~isnan(v1) && isnumeric(v2) && ~isnan(v2)
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
L_f = [str2double(string(t_other{row_lf,3})), str2double(string(t_other{row_lf+1,3})), str2double(string(t_other{row_lf+2,3}))] / 100;
fprintf('   lambda_line=%.4f/km, T_l=[%s]h, L_f=[%s]\n', lambda_per_km, num2str(T_l,'%g '), num2str(L_f,'%.2f '));

%% ================================================================
%  §3  潮流参数生成
% ================================================================
fprintf('>> [3/8] 生成潮流参数...\n');
R_KM = 0.003151; X_KM = 0.001526; TAN_PHI = tan(acos(PF));
V_src_sq = V_SRC^2; V_upper_sq = V_UPPER^2; V_lower_sq = V_LOWER^2;
M_V  = (V_upper_sq - V_lower_sq)*2; M_vn = V_upper_sq;
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
    if ~any(match), error('找不到分支(%d-%d)停电时间',u_raw,v_raw); end
    is_trf=ismember(u,subs_idx)|ismember(v,subs_idx);
    cap_b=TRAN_CAP*is_trf+LINE_CAP*(~is_trf);
    lam_b=ternary(LAMBDA_TRF>0&&is_trf, LAMBDA_TRF, len*lambda_per_km);
    rel_branches(b,:)=[u,v,lam_b,t_dur.RP(match),t_dur.SW(match),R_KM*len,X_KM*len,cap_b];
end
is_trf_vec = ismember(rel_branches(:,1),subs_idx)|ismember(rel_branches(:,2),subs_idx);

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
A_inc_all =sparse(branch_to,(1:nB_all)',+1,num_nodes,nB_all)+sparse(branch_from,(1:nB_all)',-1,num_nodes,nB_all);
A_free_all=A_inc_all(load_nodes,:);
B_to_all  =sparse((1:nB_all)',branch_to,  1,nB_all,num_nodes);
B_from_all=sparse((1:nB_all)',branch_from,1,nB_all,num_nodes);
BdV=B_to_all-B_from_all;

[~,pk_row]=ismember(inv_map(load_nodes),t_peak.Node);
P_free=zeros(nL,1); valid=pk_row>0;
P_free(valid)=t_peak.P_kW(pk_row(valid))/1e3;
Q_free=P_free*TAN_PHI;

%% ── 负荷优先级随机划分 ─────────────────────────────────────────────────
rng(PRIORITY_SEED);
perm = randperm(nL);
nA = floor(nL/3);  nB = floor(nL/3);  nC = nL - nA - nB;
idx_A = sort(perm(1:nA));                    % A类节点（本地索引）
idx_B = sort(perm(nA+1:nA+nB));             % B类节点
idx_C = sort(perm(nA+nB+1:end));            % C类节点

mask_A = false(nL,1); mask_A(idx_A)=true;
mask_B = false(nL,1); mask_B(idx_B)=true;
mask_C = false(nL,1); mask_C(idx_C)=true;

% 权重向量（每个节点对应的目标权重）
W_vec = W_A*mask_A + W_B*mask_B + W_C*mask_C;   % nL×1

fprintf('   负荷优先级划分: A类=%d节点(w=%d), B类=%d节点(w=%d), C类=%d节点(w=%d)\n', nA,W_A,nB,W_B,nC,W_C);
fprintf('   切负荷档位: %s (×峰值需求)\n', num2str(SHED_LEVELS,'%.2f '));
fprintf('   正常分支=%d，联络线=%d，负荷节点=%d\n', nB_norm, nTie, nL);

%% ================================================================
%  §5  MCF 路径识别
% ================================================================
fprintf('>> [5/8] MCF 路径识别 (模式: %s)...\n', SOLVE_MODE);
t_mcf = tic;
nSub=length(subs_idx); E_sub=sparse(subs_idx,1:nSub,1,num_nodes,nSub);

if strcmp(SOLVE_MODE,'MCF')
    E_load=sparse(load_nodes,1:nL,1,num_nodes,nL);
    F_mat=sdpvar(nB_norm,nL,'full'); Z_mat=sdpvar(nB_norm,nL,'full'); Gss=sdpvar(nSub,nL,'full');
    C_mcf=[-Z_mat<=F_mat,F_mat<=Z_mat,Z_mat>=0,0<=Gss<=1,sum(Gss,1)==1,A_inc_norm*F_mat==E_load-E_sub*Gss];
    sol=optimize(C_mcf,sum(sum(Z_mat)),sdpsettings('solver','gurobi','verbose',0));
    if sol.problem~=0, error('MCF 失败: %s',sol.info); end
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
fprintf('   MCF 完成（%.1f 秒），p_direct nnz=%d，p_feeder nnz=%d\n', t_mcf_elapsed,nnz(p_mat),nnz(p_feeder_mat));

%% ================================================================
%  §6  批量场景 MILP — 含优先级约束 + 离散切负荷（5档）
%
%  新增决策变量：
%    Z_mat (nL × N_LEVELS × nScen) binary  档位选择（每节点每场景选1档）
%    L_mat (nL × nScen)            cont.   切负荷量（由档位变量决定）
%
%  离散切负荷建模（N_LEVELS=5档）：
%    L_mat(k,xy) = P_free(k) × Σ_m SHED_LEVELS(m) × Z_mat(k,m,xy)
%    Σ_m Z_mat(k,m,xy) = 1  （恰好选一个档位）
%  注：YALMIP 支持 3D binvar，但建议展开为 (nL×N_LEVELS) × nScen 的矩阵
%    ZZ_mat((k-1)*N_LEVELS+m, xy) = Z_mat(k,m,xy)
%
%  优先级约束（对每个故障场景 xy，每个受影响的下游节点）：
%    A类（mask_A）：
%      p_direct(k,xy)=1 → Q_mat(k,xy)=1 且 L_mat(k,xy)=0
%      实现：单独强制 Q_mat(A_down,xy)=1 且 ZZ_mat(A_0档,xy)=1（只能选0%档）
%    B类（mask_B）：
%      p_direct(k,xy)=1 → Q_mat(k,xy)=1（必须转供）
%      L_mat(k,xy) ≤ SHED_LIMIT_B × P_free(k)（切除量有上限）
%    C类（mask_C）：
%      p_direct(k,xy)=1 → Q_mat(k,xy)=1（必须转供，时间约束为τ_TIE_SW=0.5h≤1h）
%      L_mat(k,xy) ≤ SHED_LIMIT_C × P_free(k)（可切除全部）
%
%  目标函数：加权切负荷最小化
%    min Σ_{k,xy} W_vec(k) × L_mat(k,xy) + alpha × sum(E_vdrop)
% ================================================================
fprintf('>> [6/8] 批量场景 MILP（%d 场景，优先级+离散切负荷）...\n', nB_norm);
t_milp = tic;

nScen      = nB_norm;
p_mat_d    = double(p_mat);
p_feeder_d = double(p_feeder_mat);

Dr  = spdiags(r_b_all,  0,nB_all,nB_all); Dx  = spdiags(x_b_all,  0,nB_all,nB_all);
Dp  = spdiags(P_free,   0,nL,nL);         Dq_ = spdiags(Q_free,   0,nL,nL);
Cap = spdiags(cap_b_all,0,nB_all,nB_all);

% ── 决策变量 ──────────────────────────────────────────────────────────────
S_mat   = binvar(nB_all,         nScen, 'full');
Q_mat   = binvar(nL,             nScen, 'full');
Pf_mat  = sdpvar(nB_all,         nScen, 'full');
Qf_mat  = sdpvar(nB_all,         nScen, 'full');
V_mat   = sdpvar(num_nodes,      nScen, 'full');
E_vdrop = sdpvar(nB_all,         nScen, 'full');

% 离散切负荷档位选择矩阵：ZZ_mat 的行 = nL × N_LEVELS（展开），列 = 场景
% ZZ_mat((k-1)*N_LEVELS + m, xy) = 1 表示节点 k 在场景 xy 选择第 m 档
ZZ_mat  = binvar(nL*N_LEVELS,    nScen, 'full');
L_mat   = sdpvar(nL,             nScen, 'full');

% ── 离散切负荷辅助矩阵 ────────────────────────────────────────────────────
% 将 SHED_LEVELS × P_free 展开为选择矩阵
% L_mat(k,xy) = Σ_m P_free(k)*SHED_LEVELS(m)*ZZ_mat((k-1)*N+m, xy)
% 向量化：构造选择矩阵 SEL (nL × nL*N_LEVELS)，
%   SEL(k, (k-1)*N+m) = P_free(k)*SHED_LEVELS(m)
idx_k = repelem((1:nL)', N_LEVELS);    % nL*N_LEVELS×1，行节点索引
idx_m = repmat((1:N_LEVELS)', nL, 1);  % nL*N_LEVELS×1，档位索引
vals  = P_free(idx_k) .* SHED_LEVELS(idx_m)';   % nL*N_LEVELS×1，切负荷量
SEL   = sparse(idx_k, (1:nL*N_LEVELS)', vals, nL, nL*N_LEVELS);
% L_mat = SEL * ZZ_mat （nL × nScen）

% 独热约束矩阵：ONESUM(k, (k-1)*N+1:(k-1)*N+N) = ones(1,N)
% Σ_m ZZ_mat((k-1)*N+m, xy) = 1
idx_k2 = repelem((1:nL)', N_LEVELS)';
ONESUM = sparse(idx_k2, 1:nL*N_LEVELS, 1, nL, nL*N_LEVELS);

delta_mat     = BdV*V_mat + 2*(Dr*Pf_mat + Dx*Qf_mat);
fault_lin_idx = (0:nB_norm-1)*nB_all + (1:nB_norm);

% ── 基础 LinDistFlow 约束 ────────────────────────────────────────────────
C = [V_mat(subs_idx,:)    == V_src_sq,                        ...
     V_mat(non_sub,:)     >= V_lower_sq - M_vn*(1-Q_mat),    ...
     V_mat(non_sub,:)     <= V_upper_sq + M_vn*(1-Q_mat),    ...
     -Cap*S_mat           <= Pf_mat <= Cap*S_mat,             ...
     -Cap*S_mat           <= Qf_mat <= Cap*S_mat,             ...
     A_free_all*Pf_mat    == Dp*Q_mat - L_mat,                ...  % [34] 含切负荷
     A_free_all*Qf_mat    == Dq_*Q_mat - TAN_PHI*L_mat,       ...  % [35] 含切负荷
     E_vdrop              >= 0,                               ...
     delta_mat            <=  M_V*(1-S_mat) + E_vdrop,        ...
     delta_mat            >= -M_V*(1-S_mat) - E_vdrop,        ...
     sum(S_mat,1)         == sum(Q_mat,1),                    ...
     S_mat(fault_lin_idx) == 0,                               ...
     Q_mat                >= 1 - p_feeder_d];

% ── 离散切负荷约束 ────────────────────────────────────────────────────────
C = [C, ...
     ZZ_mat             >= 0,            ...  % 二进制（binvar已强制）
     L_mat              == SEL * ZZ_mat, ...  % L = 档位组合
     ONESUM * ZZ_mat    == 1];                % 每节点恰好选一档

% ── 优先级约束 ────────────────────────────────────────────────────────────
% A类（下游受影响时必须全量恢复，切负荷=0）
% 构造 A类×场景 的矩阵掩码（仅在 p_direct=1 时强制）
A_down = logical(p_mat_d(mask_A,:));   % nA × nScen，A类下游受影响指示
if any(A_down(:))
    % Q_mat(A类,xy)=1 当 p_direct(A类,xy)=1
    C = [C, Q_mat(mask_A,:) >= A_down];
    % A类切负荷=0：强制 ZZ_mat 只能选第1档（0%切除档）
    % 对 A类节点，无论场景，ZZ((k-1)*N+1)=1（第1档=0%）
    for k_local = find(mask_A)'
        col_start = (k_local-1)*N_LEVELS + 1;
        % 强制选 0% 档（第1档）
        C = [C, ZZ_mat(col_start, :) == 1];
        % 其余档强制为0
        for m = 2:N_LEVELS
            C = [C, ZZ_mat(col_start+m-1, :) == 0];
        end
    end
end

% B类（下游受影响时必须转供，切负荷≤SHED_LIMIT_B）
B_down = logical(p_mat_d(mask_B,:));
if any(B_down(:))
    C = [C, Q_mat(mask_B,:) >= B_down];
    % 切负荷上限：L(B,xy) ≤ SHED_LIMIT_B × P_free(B)
    P_B_max = SHED_LIMIT_B * P_free(mask_B);   % nB×1
    C = [C, L_mat(mask_B,:) <= repmat(P_B_max, 1, nScen)];
    % 限制档位：只能选不超过 SHED_LIMIT_B 的档位
    valid_m_B = SHED_LEVELS <= SHED_LIMIT_B + 1e-6;
    for k_local = find(mask_B)'
        col_start = (k_local-1)*N_LEVELS + 1;
        for m = 1:N_LEVELS
            if ~valid_m_B(m)
                C = [C, ZZ_mat(col_start+m-1, :) == 0];
            end
        end
    end
end

% C类（下游受影响时必须转供，切负荷≤SHED_LIMIT_C，通常=1.0可完全切除）
C_down = logical(p_mat_d(mask_C,:));
if any(C_down(:))
    C = [C, Q_mat(mask_C,:) >= C_down];
    P_C_max = SHED_LIMIT_C * P_free(mask_C);
    C = [C, L_mat(mask_C,:) <= repmat(P_C_max, 1, nScen)];
end

% ── 目标函数：加权切负荷最小化 ──────────────────────────────────────────
W_mat     = repmat(W_vec, 1, nScen);   % nL×nScen，权重广播
alpha_ev  = 1e-4;
objective = sum(sum(W_mat .* L_mat)) + alpha_ev*sum(E_vdrop(:));

opts_milp = sdpsettings('solver','gurobi','verbose',0,'gurobi.MIPGap',1e-3);
sol = optimize(C, objective, opts_milp);

if sol.problem == 0
    Qv = value(Q_mat);
    if any(isnan(Qv(:)))
        warning('[§6] Q_mat 含 NaN，退化处理');
        q_mat=logical(1-p_feeder_d); L_res=zeros(nL,nScen);
        Pf_res=zeros(nB_all,nScen); Qf_res=zeros(nB_all,nScen);
        Vm_res=repmat(V_src_sq,num_nodes,nScen); Sw_res=zeros(nB_all,nScen);
        ZZ_res=zeros(nL*N_LEVELS,nScen);
    else
        q_mat  = logical(round(Qv));
        L_res  = max(value(L_mat), 0);
        ZZ_res = round(value(ZZ_mat));
        Pf_res = value(Pf_mat); Qf_res = value(Qf_mat);
        Vm_res = sqrt(max(value(V_mat),0));
        Sw_res = round(value(S_mat));
    end
else
    warning('[§6] MILP 求解失败: %s，退化处理', sol.info);
    q_mat=logical(1-p_feeder_d); L_res=zeros(nL,nScen); ZZ_res=zeros(nL*N_LEVELS,nScen);
    Pf_res=zeros(nB_all,nScen); Qf_res=zeros(nB_all,nScen);
    Vm_res=repmat(V_src_sq,num_nodes,nScen); Sw_res=zeros(nB_all,nScen);
end

% 统计
n_affected  = full(sum(p_mat_d(:)>0));
n_recovered = full(sum(sum(logical(p_mat_d) & q_mat)));
rec_pct     = n_recovered / max(n_affected,1) * 100;
shed_by_class = [sum(sum(L_res(mask_A,:))), sum(sum(L_res(mask_B,:))), sum(sum(L_res(mask_C,:)))];

t_milp_elapsed = toc(t_milp);
fprintf('   MILP 完成（%.1f 秒），恢复率=%.1f%% (%d/%d)\n', t_milp_elapsed, rec_pct, n_recovered, n_affected);
fprintf('   切负荷: A类=%.4f, B类=%.4f, C类=%.4f pu·场景\n', shed_by_class);

%% ================================================================
%  §7  可靠性指标计算（三阶段+优先级分类）
% ================================================================
fprintf('>> [7/8] 计算可靠性指标...\n');

lam=rel_branches(:,3); trp=rel_branches(:,4);
p_direct_d  =double(p_mat); q_mat_d=double(q_mat);
p_upstream_d=full(p_feeder_d)-p_direct_d;

[~,c_row]=ismember(inv_map(load_nodes),t_cust.Node);
NC_vec=zeros(1,nL); NC_vec(c_row>0)=t_cust.NC(c_row(c_row>0))';

[~,p_row]=ismember(inv_map(load_nodes),t_peak.Node);
P_avg_vec=zeros(1,nL);
P_avg_vec(p_row>0)=t_peak.P_kW(p_row(p_row>0))'.* sum(L_f.*(T_l/8760));
total_cust=sum(NC_vec);

% R2 三阶段 CIF/CID
CIF = p_feeder_d * lam;
CID = TAU_UP_SW  * (p_upstream_d * lam) ...
    + TAU_TIE_SW * (p_direct_d .* q_mat_d) * lam ...
    + (p_direct_d .* (1-q_mat_d)) * (lam .* trp);
SAIFI=sum(NC_vec.*CIF')/total_cust; SAIDI=sum(NC_vec.*CID')/total_cust;
EENS=sum(P_avg_vec.*CID')/1e3; ASAI=1-SAIDI/8760;

% R1 基准
CIF_R1=p_feeder_d*lam;
CID_R1=TAU_UP_SW*(p_upstream_d*lam)+p_direct_d*(lam.*trp);
SAIFI_R1=sum(NC_vec.*CIF_R1')/total_cust; SAIDI_R1=sum(NC_vec.*CID_R1')/total_cust;
EENS_R1=sum(P_avg_vec.*CID_R1')/1e3; ASAI_R1=1-SAIDI_R1/8760;

% 按优先级分类的 SAIDI/EENS
CID_A=CID(mask_A); CID_B=CID(mask_B); CID_C=CID(mask_C);
SAIDI_A=sum(NC_vec(mask_A).*CID_A')/max(sum(NC_vec(mask_A)),1);
SAIDI_B=sum(NC_vec(mask_B).*CID_B')/max(sum(NC_vec(mask_B)),1);
SAIDI_C=sum(NC_vec(mask_C).*CID_C')/max(sum(NC_vec(mask_C)),1);

%% ================================================================
%  §8  结果输出（含优先级分类统计）
% ================================================================
total_elapsed = toc(program_total);

fprintf('\n╔══════════════════════════════════════════╗\n');
fprintf('  系统: %-39s\n', sys_filename);
fprintf('  τ_UP_SW=%.2fh, τ_TIE_SW=%.2fh（三阶段）\n', TAU_UP_SW, TAU_TIE_SW);
fprintf('  负荷档位: %s\n', num2str(SHED_LEVELS,'%.2f '));
fprintf('  权重 A=%d, B=%d, C=%d\n', W_A, W_B, W_C);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  [R2 含重构+离散切负荷]                   ║\n');
fprintf('║  SAIFI : %10.4f  次/(户·年)         ║\n', SAIFI);
fprintf('║  SAIDI : %10.4f  h/(户·年)          ║\n', SAIDI);
fprintf('║    A类 : %10.4f  h/(户·年)          \n', SAIDI_A);
fprintf('║    B类 : %10.4f  h/(户·年)          \n', SAIDI_B);
fprintf('║    C类 : %10.4f  h/(户·年)          \n', SAIDI_C);
fprintf('║  EENS  : %10.2f  MWh/年             ║\n', EENS);
fprintf('║  ASAI  : %12.6f                   ║\n', ASAI);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  [R1 不含重构]                            ║\n');
fprintf('║  SAIDI : %10.4f  h/(户·年)          ║\n', SAIDI_R1);
fprintf('║  EENS  : %10.2f  MWh/年             ║\n', EENS_R1);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  SAIDI 改善: %+10.4f h/(户·年)             \n', SAIDI_R1-SAIDI);
fprintf('║  重构恢复率: %.1f%% (%d/%d)                \n', rec_pct, n_recovered, n_affected);
fprintf('║  切负荷量: A=%.4f  B=%.4f  C=%.4f pu·场景\n', shed_by_class);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  §5 MCF : %7.1f 秒                    \n', t_mcf_elapsed);
fprintf('║  §6 MILP: %7.1f 秒                    \n', t_milp_elapsed);
fprintf('║  总耗时 : %7.1f 秒                    \n', total_elapsed);
fprintf('╚══════════════════════════════════════════╝\n');

% 代表性场景详细输出
[~, rep_xy] = max(sum(p_mat_d,1));
fprintf('\n══════════════════════════════════════════════\n');
fprintf('  代表性故障场景 %d 的切负荷+潮流详情\n', rep_xy);
fprintf('══════════════════════════════════════════════\n');

L_rep = L_res(:, rep_xy);
qv_rep = q_mat(:, rep_xy);
pf_rep = full(p_feeder_d(:, rep_xy));
Vm_rep = Vm_res(:,rep_xy); Pf_rep=Pf_res(:,rep_xy); Qf_rep=Qf_res(:,rep_xy); Sw_rep=Sw_res(:,rep_xy);

fprintf('\n  切负荷节点（切除量>0）\n');
fprintf('  %-10s  %-6s  %-12s  %-12s  %-10s  %-8s\n','节点','优先级','P_demand/kW','L_shed/kW','档位','切除比例');
fprintf('  %s\n', repmat('─',1,64));
any_shed = false;
for k = 1:nL
    if L_rep(k) > 1e-4
        any_shed = true;
        pr = ternary(mask_A(k),'A', ternary(mask_B(k),'B','C'));
        % 找选中的档位
        col_start = (k-1)*N_LEVELS+1;
        chosen_m = find(ZZ_res(col_start:col_start+N_LEVELS-1, rep_xy)>0.5, 1);
        if isempty(chosen_m), chosen_m=1; end
        fprintf('  %-10d  %-6s  %-12.2f  %-12.2f  %d(%.0f%%)  %-8.1f%%\n', ...
            inv_map(load_nodes(k)), pr, P_free(k)*1e3, L_rep(k)*1e3, ...
            chosen_m, SHED_LEVELS(chosen_m)*100, L_rep(k)/max(P_free(k),1e-9)*100);
    end
end
if ~any_shed, fprintf('  （本场景无切负荷操作）\n'); end

fprintf('\n  节点电压（供电节点）\n');
fprintf('  %-10s  %-10s  %-6s  %-16s\n','节点','电压/pu','优先级','状态');
fprintf('  %s\n', repmat('─',1,46));
for si=1:length(subs_idx)
    fprintf('  %-10d  %-10.4f  %-6s  变电站\n', inv_map(subs_idx(si)), Vm_rep(subs_idx(si)),'─');
end
for k=1:nL
    if qv_rep(k)
        pr=ternary(mask_A(k),'A',ternary(mask_B(k),'B','C'));
        if pf_rep(k)>0 && L_rep(k)>1e-4
            st=sprintf('转供(切%.1f%%)',L_rep(k)/max(P_free(k),1e-9)*100);
        elseif pf_rep(k)>0
            st='转供恢复';
        else
            st='正常供电';
        end
        fprintf('  %-10d  %-10.4f  %-6s  %s\n', inv_map(load_nodes(k)), Vm_rep(load_nodes(k)), pr, st);
    end
end

fprintf('\n  合路分支潮流（kW / kVar）\n');
fprintf('  %-6s  %-6s  %-6s  %-12s  %-12s  %-8s\n','分支#','From','To','P/kW','Q/kVar','类型');
fprintf('  %s\n', repmat('─',1,60));
for b=1:nB_all
    if Sw_rep(b)==1
        br_type=ternary(b<=nB_norm,ternary(is_trf_vec(b),'变压器','线路'),'联络线');
        fprintf('  %-6d  %-6d  %-6d  %+12.2f  %+12.2f  %s\n', b, inv_map(all_branches(b,1)), inv_map(all_branches(b,2)), Pf_rep(b)*1e3, Qf_rep(b)*1e3, br_type);
    end
end

%% ── 辅助内联函数 ─────────────────────────────────────────────
function out = ternary(cond, a, b)
    if cond, out = a; else, out = b; end
end
