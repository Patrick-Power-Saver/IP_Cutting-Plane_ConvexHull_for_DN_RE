%% ============================================================
%  配电网可靠性评估 —— R11（全面修正版）
%
%  [Q1] 负荷分级：综合重要性评分（NC+需求占比），非均匀阈值
%  [Q2] 低压分支开关个性化离散切负荷档位（参数化+可复用）
%  [Q3] MCF+MILP合并分析（双线性非凸性根源与McCormick线性化）
%  [Q4] 目标函数量纲统一（VOLL-based元/年）+ 开关动作次数可选
%  [Q5] 大规模离散优化方法（场景分解、Benders、列生成等）
%
%  依赖: YALMIP + Gurobi
% =============================================================
clear; clc;

%% ── 用户配置区 ─────────────────────────────────────────────
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

LAMBDA_TRF = 0.5;        % 变压器故障率（0=统一用线路公式）
TAU_UP_SW  = 0.3;      % 上游开关操作时间(h)
TAU_TIE_SW = 0.5;      % 联络开关切换时间(h)

% [Q1] 综合重要性评分权重与分级阈值
W_SCORE_NC = 0.5;      % NC占比权重
W_SCORE_P  = 0.5;      % 需求占比权重
RATIO_L1   = 0.30;     % 累积重要性前30%→L1
RATIO_L2   = 0.30;     % 接下来30%→L2，其余→L3

% VOLL基准（元/kWh）与扰动
VOLL_BASE  = [200, 50, 10];   % [L1, L2, L3]
VOLL_NOISE = 0.20;
VOLL_SEED  = 123;

% 切负荷上限比例
SHED_LIMIT    = [0.00, 0.25, 1.00];  % [L1, L2, L3]
FLEX_RATIO_L3 = 0.8;   % L3快速响应比例（柔性资源）

% [Q2] 低压分支开关参数
N_BR_THRESHOLDS = [50, 150, 400];   % NC阈值
N_BR_VALUES     = [2, 3, 4, 5];    % 对应低压分支数
LV_REGEN        = false;            % false=复用固定种子数据；true=重新生成
LV_SEED         = 42;

% [Q4] 开关动作次数惩罚（元/次，0=不考虑）
GAMMA_SWITCH = 0;

SOLVE_MODE = 'MCF';
V_UPPER = 1.05; V_LOWER = 0.95; V_SRC = 1.0; PF = 0.9;
% ──────────────────────────────────────────────────────────

program_total = tic;

%% §1  Testbench 数据读取
fprintf('>> [1/8] 读取 Testbench: Sheet="%s"\n', sys_sheet);
tb_cell = readcell(tb_filename, 'Sheet', sys_sheet);
nrows_tb = size(tb_cell,1);
hdr_row = 0;
for ri = 1:nrows_tb
    if ischar(tb_cell{ri,1}) && contains(tb_cell{ri,1},'Tie-Switch')
        hdr_row = ri; break;
    end
end
if hdr_row==0, error('未找到Tie-Switch表头行'); end
LINE_CAP = str2double(extractBefore(string(tb_cell{hdr_row+1,4}),' '));
TRAN_CAP = LINE_CAP;
TIE_LINES_RAW = [];
for ri = hdr_row+2:nrows_tb
    v1=tb_cell{ri,1}; v2=tb_cell{ri,2};
    if isnumeric(v1)&&~isnan(v1)&&isnumeric(v2)&&~isnan(v2)
        TIE_LINES_RAW(end+1,:)=[v1,v2]; %#ok<AGROW>
    end
end
fprintf('   线路容量=%.0f MW，联络线=%d条\n', LINE_CAP, size(TIE_LINES_RAW,1));

%% §2  可靠性参数读取
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
lambda_per_km = str2double(string(t_other{find(contains(col1,'Failure rate'),1),2}));
row_dur = find(contains(col1,'Duration'),1);
T_l = [str2double(string(t_other{row_dur,3})), str2double(string(t_other{row_dur+1,3})), str2double(string(t_other{row_dur+2,3}))];
row_lf = find(contains(col1,'Loading factors'),1);
L_f = [str2double(string(t_other{row_lf,3})), str2double(string(t_other{row_lf+1,3})), str2double(string(t_other{row_lf+2,3}))]/100;
fprintf('   lambda=%.4f/km\n', lambda_per_km);

%% §3  潮流参数
R_KM=0.003151; X_KM=0.001526; TAN_PHI=tan(acos(PF));
V_src_sq=V_SRC^2; V_upper_sq=V_UPPER^2; V_lower_sq=V_LOWER^2;
M_V=(V_upper_sq-V_lower_sq)*2; M_vn=V_upper_sq;

%% §4  拓扑索引
fprintf('>> [4/8] 构建拓扑索引...\n');
raw_nodes=unique([t_branch.From;t_branch.To;TIE_LINES_RAW(:)]);
num_nodes=length(raw_nodes);
node_map=containers.Map(raw_nodes,1:num_nodes);
inv_map=raw_nodes;
subs_raw=raw_nodes(~ismember(raw_nodes,t_cust.Node));
subs_idx=arrayfun(@(s) node_map(s), subs_raw);
nB_norm=height(t_branch); nTie=size(TIE_LINES_RAW,1); nB_all=nB_norm+nTie;

rel_branches=zeros(nB_norm,8);
for b=1:nB_norm
    u_raw=t_branch.From(b); v_raw=t_branch.To(b);
    u=node_map(u_raw); v=node_map(v_raw); len=t_branch.Length_km(b);
    match=(t_dur.From==u_raw&t_dur.To==v_raw)|(t_dur.From==v_raw&t_dur.To==u_raw);
    if ~any(match), error('分支(%d-%d)无停电时间',u_raw,v_raw); end
    is_trf=ismember(u,subs_idx)|ismember(v,subs_idx);
    cap_b=TRAN_CAP*is_trf+LINE_CAP*(~is_trf);
    lam_b=ternary(LAMBDA_TRF>0&&is_trf, LAMBDA_TRF, len*lambda_per_km);
    rel_branches(b,:)=[u,v,lam_b,t_dur.RP(match),t_dur.SW(match),R_KM*len,X_KM*len,cap_b];
end
is_trf_vec=ismember(rel_branches(:,1),subs_idx)|ismember(rel_branches(:,2),subs_idx);
n_trf=sum(is_trf_vec);

tie_branches=zeros(nTie,8);
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
P_free=zeros(nL,1); valid_pk=pk_row>0;
P_free(valid_pk)=t_peak.P_kW(pk_row(valid_pk))/1e3;
Q_free=P_free*TAN_PHI;

%% ================================================================
%  §4b  [Q1+Q2] 负荷分级 & 低压分支开关档位
%
%  [Q1] 综合重要性评分分级（非均匀阈值）：
%    score(k) = W_NC*(NC_k/ΣNC) + W_P*(P_k/ΣP)
%    累积重要性前RATIO_L1→L1（关键），前RATIO_L1+RATIO_L2→L2（重要），其余→L3
%    意义：同样固定20%节点比例，用累积重要性则"少数高分节点早早达到阈值"
%    例：若排前3%的节点已贡献30%重要性 → 这3%节点全部归L1
%    这比固定节点数比例更能体现关键少数的特征（非均匀分配）
%
%  [Q2] 低压分支开关模型：
%    实际中台区k的切负荷最小单元=低压分支开关
%    控制自由度 = n_br(k)，可行状态 = 2^{n_br(k)} 种
%    各支路权重随机生成（固定种子LV_SEED保证复用，LV_REGEN控制是否重生成）
%    档位 = 各子集切负荷比例之和，施加shed_limit约束后得节点专属档位集
%
%  [Q3] MCF+MILP合并的非凸性分析（见§5）：
%    若s^NO为决策变量（规划问题），F^{f,NO}_i×F^{f,NO}_{xy}引入双线性→非凸
%    线性化：McCormick包络 w≥x+y-1, w≤x, w≤y, w≥0（最紧松弛，精确）
%    本评估问题s^NO固定→F^{f,NO}为常数→p_mat为参数→无双线性→两步优于合并
%
%  [Q4] 目标函数量纲（见§6）：
%    W_cid[户·时/年] vs W_shed[元·户/(kWh·年)]→量纲不一致
%    修正：W_q=VOLL×P_free×λ×(τRP-τTIE)[元/年], W_L=VOLL×λ×(τRP-τTIE)[元/(年·MW)]
%    目标全部单位元/年 ✓
%
%  [Q5] 大规模离散优化方法（见§6）
% ================================================================
[~,c_row_pre]=ismember(inv_map(load_nodes),t_cust.Node);
NC_vec=zeros(nL,1); NC_vec(c_row_pre>0)=t_cust.NC(c_row_pre(c_row_pre>0));

% [Q1] 综合评分排序
total_NC=max(sum(NC_vec),1); total_P=max(sum(P_free),1e-9);
score_k = W_SCORE_NC*(NC_vec/total_NC) + W_SCORE_P*(P_free/total_P);
[score_sorted,sort_idx]=sort(score_k,'descend');
cum_score=cumsum(score_sorted)/max(sum(score_sorted),1e-9);

rank_vec=zeros(nL,1);
rank_vec(sort_idx(cum_score<=RATIO_L1))=1;
rank_vec(sort_idx(cum_score>RATIO_L1 & cum_score<=RATIO_L1+RATIO_L2))=2;
rank_vec(sort_idx(cum_score>RATIO_L1+RATIO_L2))=3;
idx_L1=find(rank_vec==1); idx_L2=find(rank_vec==2); idx_L3=find(rank_vec==3);
nL1=length(idx_L1); nL2=length(idx_L2); nL3=length(idx_L3);

shed_limit_vec=zeros(nL,1);
shed_limit_vec(idx_L1)=SHED_LIMIT(1);
shed_limit_vec(idx_L2)=SHED_LIMIT(2);
shed_limit_vec(idx_L3)=SHED_LIMIT(3)*FLEX_RATIO_L3;

rng(VOLL_SEED);
voll_vec=zeros(nL,1);
voll_vec(idx_L1)=VOLL_BASE(1)*(1+VOLL_NOISE*(2*rand(nL1,1)-1));
voll_vec(idx_L2)=VOLL_BASE(2)*(1+VOLL_NOISE*(2*rand(nL2,1)-1));
voll_vec(idx_L3)=VOLL_BASE(3)*(1+VOLL_NOISE*(2*rand(nL3,1)-1));
voll_pu=voll_vec*1e3;   % 元/MWh（用于货币化目标）

% [Q2] 低压分支开关档位生成
if ~LV_REGEN
    rng(LV_SEED);
    fprintf('   [Q2] 使用固定随机种子(LV_SEED=%d)，LV_REGEN=false可复用结果\n', LV_SEED);
else
    fprintf('   [Q2] 重新生成低压分支权重(LV_REGEN=true)\n');
end

node_levels=cell(nL,1); n_br_vec=zeros(nL,1);
for k=1:nL
    if shed_limit_vec(k)<=1e-6
        node_levels{k}=[0]; continue;
    end
    nc_k=max(NC_vec(k),1);
    if nc_k<=N_BR_THRESHOLDS(1);       n_br=N_BR_VALUES(1);
    elseif nc_k<=N_BR_THRESHOLDS(2);   n_br=N_BR_VALUES(2);
    elseif nc_k<=N_BR_THRESHOLDS(3);   n_br=N_BR_VALUES(3);
    else;                               n_br=N_BR_VALUES(4);
    end
    n_br_vec(k)=n_br;
    raw_w=ones(1,n_br)/n_br + 0.1*(2*rand(1,n_br)-1);
    raw_w=max(raw_w,0.02);
    branch_w=raw_w/sum(raw_w);
    n_states=2^n_br;
    lset=zeros(1,n_states);
    for s=0:n_states-1
        bits=bitget(s,1:n_br,'uint32');
        lset(s+1)=sum(branch_w.*double(bits));
    end
    lset=sort(unique(round(lset,4)));
    lset=lset(lset<=shed_limit_vec(k)+1e-6);
    if isempty(lset)||lset(1)~=0, lset=[0,lset]; end
    node_levels{k}=lset;
end
n_lev_arr=cellfun(@length,node_levels);

fprintf('   [Q1]负荷分级(累积重要性%.0f%%/%.0f%%/其余): L1=%d, L2=%d, L3=%d节点\n', RATIO_L1*100,RATIO_L2*100,nL1,nL2,nL3);
fprintf('   L1覆盖:NC=%.0f户(%.1f%%), L2覆盖:NC=%.0f户(%.1f%%)\n', sum(NC_vec(idx_L1)),sum(NC_vec(idx_L1))/total_NC*100,sum(NC_vec(idx_L2)),sum(NC_vec(idx_L2))/total_NC*100);
fprintf('   n_br分布:%s  档位: 均值%.1f, 最大%d\n', mat2str(unique(n_br_vec(n_br_vec>0))'), mean(n_lev_arr(shed_limit_vec>0)), max(n_lev_arr));
fprintf('   VOLL[元/kWh]: L1=%.0f~%.0f, L2=%.0f~%.0f, L3=%.0f~%.0f\n', min(voll_vec(idx_L1)),max(voll_vec(idx_L1)),min(voll_vec(idx_L2)),max(voll_vec(idx_L2)),min(voll_vec(idx_L3)),max(voll_vec(idx_L3)));
fprintf('   正常分支=%d，联络线=%d，负荷节点=%d\n',nB_norm,nTie,nL);

%% ================================================================
%  §5  MCF 路径识别
%
%  [Q3] MCF+MILP合并分析：
%
%  【合并方案】将文献Eq(16)-(27)的F^{f,NO}和p^{xy}纳入统一模型：
%    正常运行变量: F^{f,NO}_i ∈ [0,1]（节点i属于馈线f的连续标记）
%    故障影响变量: p^{xy}_i ∈ {0,1}（由F^{f,NO}通过Eq(16)导出）
%    链接约束(Eq.16): F^{f,NO}_i + F^{f,NO}_{xy} - 1 ≤ p^{xy}_i
%
%  【非凸性根源】
%  若s^{NO}也为决策变量（如网络规划问题），则F^{f,NO}也是变量。
%  Eq(16)等价于: F^{f,NO}_i × F^{f,NO}_{xy} ≤ p^{xy}_i（取隐含乘积形式）
%  两个连续变量之积 = 双线性约束 → 非凸MINLP问题
%  根本原因：馈线归属（F^{f,NO}_i）× 故障分支归属（F^{f,NO}_{xy}）= 双乘积
%
%  【线性化方法（若需合并）】
%  McCormick包络（最紧松弛，精确线性化双线性约束x·y≤w）：
%    w ≥ x + y - 1    （当x,y ∈ [0,1]时最紧下界）
%    w ≤ x            （上界）
%    w ≤ y            （上界）
%    w ≥ 0            （非负）
%  引入辅助变量 w_{ij}^f = F^{f,NO}_i × F^{f,NO}_{xy}：
%    规模增加: nL×nB×nF 个新变量和4倍约束
%
%  【本问题结论：不合并，保持两步结构】
%  s^{NO}固定 → F^{f,NO}唯一确定（预求解为常数） → p_mat为参数
%  → 不存在双线性项 → 合并无必要
%  合并后仅增加规模（+6972个二进制变量），不产生任何联合优化收益
%  唯一合并价值：s^{NO}本身为决策变量的网络规划问题
% ================================================================
fprintf('>> [5/8] MCF 路径识别...\n');
t_mcf=tic;
nSub=length(subs_idx); E_sub=sparse(subs_idx,1:nSub,1,num_nodes,nSub);

if strcmp(SOLVE_MODE,'MCF')
    E_load=sparse(load_nodes,1:nL,1,num_nodes,nL);
    F_mat=sdpvar(nB_norm,nL,'full'); Z_mat=sdpvar(nB_norm,nL,'full'); Gss=sdpvar(nSub,nL,'full');
    C_mcf=[-Z_mat<=F_mat,F_mat<=Z_mat,Z_mat>=0,0<=Gss<=1,sum(Gss,1)==1,A_inc_norm*F_mat==E_load-E_sub*Gss];
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
fprintf('   MCF完成（%.1f秒），p_direct nnz=%d，p_feeder nnz=%d\n',t_mcf_elapsed,nnz(p_mat),nnz(p_feeder_mat));

%% ================================================================
%  §6  批量场景 MILP
%
%  [Q4] 量纲修正（全部元/年）：
%    原版: W_cid[户·时/年]×Q vs W_shed[元·户/(kWh·年)]×L[MW]
%          → W_cid×Q[户·时/年], W_shed×L[元·户/(h·年)] 量纲不同！
%    修正: W_q=VOLL[元/MWh]×P_free[MW]×λ[次/年]×(τRP-τTIE)[h] → [元/年]
%          W_L=VOLL[元/MWh]×λ[次/年]×(τRP-τTIE)[h] → [元/(年·MW)], ×L[MW]=[元/年]
%    目标: min -Σ W_q·Q + Σ W_L·L + γ·Σ开关动作 + α·ΣE_vdrop [元/年] ✓
%
%  [Q4b] 开关动作次数（可选惩罚）：
%    次数 = Σ_{b,xy} |S_mat(b,xy)-S_NO(b)|
%    线性化: S_NO×(1-S) + (1-S_NO)×S（二值变量绝对值展开）
%
%  [Q5] 大规模离散优化方法（本问题适用策略）：
%  【方法1：场景分解（最推荐）】
%    故障场景间完全独立 → 逐场景并行求解
%    每次MILP规模: nB_all+nL+total_ZZ → 比批量小nScen倍
%    实现: 将下方批量MILP改为 parfor xy=1:nB_norm 逐场景
%
%  【方法2：Benders分解】
%    主问题: 开关决策(S_mat, Q_mat, ZZ_s)
%    子问题: 给定开关方案的潮流可行性验证(LP)
%    Benders割: LP不可行时将约束回传主问题
%    优势: 将MILP规模大幅压缩（整数变量→外层，连续变量→内层）
%
%  【方法3：列生成】
%    ZZ_s初始只生成0档，按需添加其他档位列
%    当增加某列使目标函数改善时加入，否则停止
%    优势: 大幅减少初始ZZ变量数，适合档位数多但最优解只用少数档位时
%
%  【方法4：启发式（精确方法超时时）】
%    GRASP: 贪婪构造初始解(选对CID改善最大的节点优先恢复)+局部搜索改进
%    模拟退火(SA): 在当前方案邻域随机跳转，以概率接受差解跳出局部最优
%    遗传算法(GA): 种群进化，适合大规模并行
% ================================================================
fprintf('>> [6/8] 批量场景MILP（量纲一致目标+低压分支档位）...\n');
t_milp=tic;

nScen=nB_norm;
p_mat_d=double(p_mat); p_feeder_d=double(p_feeder_mat);
lam_vec=rel_branches(:,3); trp_vec=rel_branches(:,4);

Dr=spdiags(r_b_all,0,nB_all,nB_all); Dx=spdiags(x_b_all,0,nB_all,nB_all);
Dp=spdiags(P_free,0,nL,nL); Dq_=spdiags(Q_free,0,nL,nL);
Cap=spdiags(cap_b_all,0,nB_all,nB_all);

% [Q4] 量纲一致的货币化权重矩阵
tau_benefit=max(trp_vec-TAU_TIE_SW,0);
W_q=(voll_pu.*P_free.*p_mat_d).*(lam_vec.*tau_benefit)';   % nL×nScen [元/年]
W_L=(voll_pu.*p_mat_d).*(lam_vec.*tau_benefit)';           % nL×nScen [元/(年·MW)]
fprintf('   [Q4]量纲: W_q[元/年]×Q→元/年, W_L[元/(年·MW)]×L[MW]→元/年 ✓\n');
fprintf('   W_q: 非零=%d, max=%.2f元/年\n', nnz(W_q), max(full(W_q(:))));

% 稀疏ZZ变量
can_shed=shed_limit_vec>1e-6;
n_shed=sum(can_shed); shed_nodes_idx=find(can_shed);
total_ZZ=sum(n_lev_arr(shed_nodes_idx));
row_s=zeros(total_ZZ,1); val_sel=zeros(total_ZZ,1); val_one=ones(total_ZZ,1);
ptr=0;
for ki=1:n_shed
    k=shed_nodes_idx(ki); lv=node_levels{k}; nk=length(lv);
    rows=ptr+1:ptr+nk;
    row_s(rows)=ki; val_sel(rows)=P_free(k)*lv(:);
    ptr=ptr+nk;
end
col_s=(1:total_ZZ)';
SEL_s=sparse(row_s,col_s,val_sel,n_shed,total_ZZ);
ONESUM_s=sparse(row_s,col_s,val_one,n_shed,total_ZZ);
fprintf('   ZZ变量(低压分支): 可切节点=%d/%d，总档位列数=%d\n',n_shed,nL,total_ZZ);

% 决策变量
S_mat=binvar(nB_all,nScen,'full'); Q_mat=binvar(nL,nScen,'full');
Pf_mat=sdpvar(nB_all,nScen,'full'); Qf_mat=sdpvar(nB_all,nScen,'full');
V_mat=sdpvar(num_nodes,nScen,'full'); E_vdrop=sdpvar(nB_all,nScen,'full');
ZZ_s=binvar(total_ZZ,nScen,'full'); L_mat=sdpvar(nL,nScen,'full');

delta_mat=BdV*V_mat+2*(Dr*Pf_mat+Dx*Qf_mat);
fault_lin_idx=(0:nB_norm-1)*nB_all+(1:nB_norm);
P_max_mat=repmat(P_free,1,nScen);
L_shed_part=SEL_s*ZZ_s;

C=[V_mat(subs_idx,:)==V_src_sq, V_mat(non_sub,:)>=V_lower_sq-M_vn*(1-Q_mat), V_mat(non_sub,:)<=V_upper_sq+M_vn*(1-Q_mat), ...
   -Cap*S_mat<=Pf_mat<=Cap*S_mat, -Cap*S_mat<=Qf_mat<=Cap*S_mat, ...
   A_free_all*Pf_mat==Dp*Q_mat-L_mat, A_free_all*Qf_mat==Dq_*Q_mat-TAN_PHI*L_mat, ...
   E_vdrop>=0, delta_mat<=M_V*(1-S_mat)+E_vdrop, delta_mat>=-M_V*(1-S_mat)-E_vdrop, ...
   sum(S_mat,1)==sum(Q_mat,1), S_mat(fault_lin_idx)==0, Q_mat>=1-p_feeder_d];

if any(~can_shed), C=[C,L_mat(~can_shed,:)==0]; end
C=[C,ZZ_s>=0,L_mat(shed_nodes_idx,:)==L_shed_part,ONESUM_s*ZZ_s==1,L_mat>=0,L_mat<=P_max_mat.*Q_mat];

% [Q4b] 开关动作次数惩罚
if GAMMA_SWITCH>0
    S_NO=ones(nB_all,1); S_NO(nB_norm+1:end)=0;
    S_NO_mat=repmat(S_NO,1,nScen);
    switch_cost=GAMMA_SWITCH*sum(sum(S_NO_mat.*(1-S_mat)+(1-S_NO_mat).*S_mat));
    fprintf('   [Q4b]开关动作惩罚: γ=%.2f元/次\n',GAMMA_SWITCH);
else
    switch_cost=0;
end

opts_milp=sdpsettings('solver','gurobi','verbose',0,'gurobi.MIPGap',1e-3,'gurobi.Heuristics',0.05,'gurobi.Presolve',2,'gurobi.Cuts',2,'gurobi.NodefileStart',0.5);
%objective=-sum(sum(W_q.*Q_mat))+sum(sum(W_L.*L_mat))+switch_cost+1e-4*sum(E_vdrop(:));
objective=VOLL_saving/switch_cost;
sol=optimize(C,objective,opts_milp);

if sol.problem==0
    Qv=value(Q_mat);
    if any(isnan(Qv(:)))
        q_mat=logical(1-p_feeder_d); L_res=zeros(nL,nScen);
        Pf_res=zeros(nB_all,nScen); Qf_res=zeros(nB_all,nScen);
        Vm_res=repmat(V_src_sq,num_nodes,nScen); Sw_res=zeros(nB_all,nScen);
    else
        q_mat=logical(round(Qv)); L_res=max(value(L_mat),0);
        Pf_res=value(Pf_mat); Qf_res=value(Qf_mat);
        Vm_res=sqrt(max(value(V_mat),0)); Sw_res=round(value(S_mat));
    end
else
    warning('[§6] MILP失败: %s',sol.info);
    q_mat=logical(1-p_feeder_d); L_res=zeros(nL,nScen);
    Pf_res=zeros(nB_all,nScen); Qf_res=zeros(nB_all,nScen);
    Vm_res=repmat(V_src_sq,num_nodes,nScen); Sw_res=zeros(nB_all,nScen);
end

q_mat_d=double(q_mat); p_direct_d=double(p_mat); p_feeder_d_full=double(p_feeder_mat);
SHED_THRESH=1e-4;
P_free_mat=repmat(P_free,1,nScen);
n_full=full(sum(q_mat_d(:)>0.5&L_res(:)<=SHED_THRESH&p_direct_d(:)>0.5));
n_part=full(sum(q_mat_d(:)>0.5&L_res(:)>SHED_THRESH&p_direct_d(:)>0.5));
n_unrec=full(sum(q_mat_d(:)<0.5&p_direct_d(:)>0.5));
n_aff=full(sum(p_direct_d(:)>0));
aff_power=full(sum(sum(P_free_mat.*p_direct_d)));
net_rec=full(sum(sum((P_free_mat-L_res).*q_mat_d.*p_direct_d)));
rec_pct=net_rec/max(aff_power,1e-9)*100;
total_shed=full(sum(sum(L_res.*q_mat_d.*p_direct_d)));
mask_L1=false(nL,1); mask_L1(idx_L1)=true;
mask_L2=false(nL,1); mask_L2(idx_L2)=true;
mask_L3=false(nL,1); mask_L3(idx_L3)=true;
shed_lev=[sum(sum(L_res(mask_L1,:).*q_mat_d(mask_L1,:))),sum(sum(L_res(mask_L2,:).*q_mat_d(mask_L2,:))),sum(sum(L_res(mask_L3,:).*q_mat_d(mask_L3,:)))];
t_milp_elapsed=toc(t_milp);
fprintf('   MILP完成（%.1f秒），目标=%.2f元/年\n',t_milp_elapsed,value(objective));
fprintf('   恢复: 完全=%d,部分=%d,未恢复=%d/受影响=%d, 功率基=%.1f%%\n',n_full,n_part,n_unrec,n_aff,rec_pct);

%% §7  可靠性指标
fprintf('>> [7/8] 计算可靠性指标...\n');
lam=rel_branches(:,3); trp=rel_branches(:,4);
p_upstream_d=p_feeder_d_full-p_direct_d;
[~,c_row]=ismember(inv_map(load_nodes),t_cust.Node);
NC_r=zeros(nL,1); NC_r(c_row>0)=t_cust.NC(c_row(c_row>0));
[~,p_row]=ismember(inv_map(load_nodes),t_peak.Node);
P_avg=zeros(nL,1); P_avg(p_row>0)=t_peak.P_kW(p_row(p_row>0))*sum(L_f.*(T_l/8760));
total_cust=sum(NC_r);
P_free_safe=max(P_free,1e-9);
shed_ratio=(L_res./repmat(P_free_safe,1,nScen)).*q_mat_d.*p_direct_d;

CIF=p_feeder_d_full*lam;
CID_up=TAU_UP_SW*(p_upstream_d*lam);
CID_tie=TAU_TIE_SW*(p_direct_d.*q_mat_d)*lam;
CID_rep=(p_direct_d.*(1-q_mat_d))*(lam.*trp);
CID_shed=(shed_ratio.*p_direct_d.*q_mat_d)*(lam.*(trp-TAU_TIE_SW));
CID=CID_up+CID_tie+CID_rep+CID_shed;

SAIFI=(NC_r'*CIF)/total_cust; SAIDI=(NC_r'*CID)/total_cust;
EENS=(P_avg'*CID)/1e3; ASAI=1-SAIDI/8760;
SAIDI_up=(NC_r'*CID_up)/total_cust; SAIDI_tie=(NC_r'*CID_tie)/total_cust;
SAIDI_rep=(NC_r'*CID_rep)/total_cust; SAIDI_shed=(NC_r'*CID_shed)/total_cust;

CID_R1=TAU_UP_SW*(p_upstream_d*lam)+p_direct_d*(lam.*trp);
SAIDI_R1=(NC_r'*CID_R1)/total_cust; EENS_R1=(P_avg'*CID_R1)/1e3; ASAI_R1=1-SAIDI_R1/8760;

VOLL_loss_R2=sum(voll_vec.*P_avg.*CID);   % 元/年
VOLL_loss_R1=sum(voll_vec.*P_avg.*CID_R1);
VOLL_saving=VOLL_loss_R1-VOLL_loss_R2;

%% §8  结果输出
total_elapsed=toc(program_total);
fprintf('\n╔══════════════════════════════════════════╗\n');
fprintf('  系统: %-39s\n',sys_filename);
fprintf('  [Q1]负荷分级(累积%.0f%%/%.0f%%/其余): L1=%d, L2=%d, L3=%d\n',RATIO_L1*100,RATIO_L2*100,nL1,nL2,nL3);
fprintf('  [Q4]目标函数: VOLL-based元/年，量纲一致✓\n');
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  [R2 含重构+VOLL切负荷]                   ║\n');
fprintf('║  SAIFI : %10.4f  次/(户·年)         ║\n',SAIFI);
fprintf('║  SAIDI : %10.4f  h/(户·年)          ║\n',SAIDI);
fprintf('║    ①上游开关  : %+8.4f h/(户·年)     \n',SAIDI_up);
fprintf('║    ②联络转供  : %+8.4f h/(户·年)     \n',SAIDI_tie);
fprintf('║    ③等待修复  : %+8.4f h/(户·年)     \n',SAIDI_rep);
fprintf('║    ④切负荷等待: %+8.4f h/(户·年)     \n',SAIDI_shed);
fprintf('║  EENS  : %10.2f  MWh/年             ║\n',EENS);
fprintf('║  ASAI  : %12.6f                   ║\n',ASAI);
fprintf('║  VOLL年损失: %10.2f 万元/年         ║\n',VOLL_loss_R2/1e4);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  [R1 不含重构]  SAIDI=%8.4f  EENS=%8.2f ║\n',SAIDI_R1,EENS_R1);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  SAIDI改善: %+10.4f h/(户·年)              \n',SAIDI_R1-SAIDI);
fprintf('║  EENS改善 : %+10.2f MWh/年                \n',EENS_R1-EENS);
fprintf('║  VOLL节约 : %+10.2f 万元/年                \n',VOLL_saving/1e4);
fprintf('║  功率基恢复率: %.1f%%(完全%d/部分%d/未%d)   \n',rec_pct,n_full,n_part,n_unrec);
fprintf('║  切负荷(L1/L2/L3): %.4f/%.4f/%.4f pu·场景 \n',shed_lev);
fprintf('╠══════════════════════════════════════════╣\n');
fprintf('║  §5 MCF : %7.1f 秒                    \n',t_mcf_elapsed);
fprintf('║  §6 MILP: %7.1f 秒 (ZZ=%d档位)       \n',t_milp_elapsed,total_ZZ);
fprintf('║  总耗时 : %7.1f 秒                    \n',total_elapsed);
fprintf('╚══════════════════════════════════════════╝\n');

[~,rep_xy]=max(sum(p_direct_d,1));
fprintf('\n══ 代表性故障场景 %d（分支%d─%d）══\n',rep_xy,inv_map(rel_branches(rep_xy,1)),inv_map(rel_branches(rep_xy,2)));
Vm_rep=Vm_res(:,rep_xy); Pf_rep=Pf_res(:,rep_xy); Qf_rep=Qf_res(:,rep_xy);
Sw_rep=Sw_res(:,rep_xy); qv_rep=q_mat(:,rep_xy);
pf_rep=full(p_feeder_d_full(:,rep_xy)); L_rep=L_res(:,rep_xy);

shed_rep=find(L_rep>SHED_THRESH&qv_rep);
if ~isempty(shed_rep)
    fprintf('\n  切负荷节点（低压分支开关操作）\n');
    fprintf('  %-8s %-4s %-5s %-8s %-10s %-10s %-8s\n','节点','级','n_br','VOLL','P/kW','L/kW','切除比');
    fprintf('  %s\n',repmat('─',1,58));
    for k=shed_rep'
        lvl=ternary(mask_L1(k),'L1',ternary(mask_L2(k),'L2','L3'));
        fprintf('  %-8d %-4s %-5d %-8.0f %-10.2f %-10.2f %-8.1f%%\n', ...
            inv_map(load_nodes(k)),lvl,n_br_vec(k),voll_vec(k)*1e3,P_free(k)*1e3,L_rep(k)*1e3,L_rep(k)/P_free_safe(k)*100);
    end
end

fprintf('\n  节点电压（pu）\n  %-8s %-10s %-4s %-16s\n','节点','V/pu','级','状态');
fprintf('  %s\n',repmat('─',1,42));
for si=1:length(subs_idx)
    fprintf('  %-8d %-10.4f %-4s 变电站\n',inv_map(subs_idx(si)),Vm_rep(subs_idx(si)),'─');
end
for k=1:nL
    if qv_rep(k)
        lvl=ternary(mask_L1(k),'L1',ternary(mask_L2(k),'L2','L3'));
        if pf_rep(k)>0&&L_rep(k)>SHED_THRESH; st=sprintf('转供(切%.1f%%)',L_rep(k)/P_free_safe(k)*100);
        elseif pf_rep(k)>0; st='转供恢复'; else; st='正常供电'; end
        fprintf('  %-8d %-10.4f %-4s %s\n',inv_map(load_nodes(k)),Vm_rep(load_nodes(k)),lvl,st);
    end
end
n_dark=sum(~qv_rep&pf_rep>0);
if n_dark>0, fprintf('  （%d受影响节点未恢复略去）\n',n_dark); end

fprintf('\n  合路分支潮流（kW/kVar）\n  %-6s %-6s %-6s %-12s %-12s %-8s\n','分支#','From','To','P/kW','Q/kVar','类型');
fprintf('  %s\n',repmat('─',1,58));
P_total=0; Q_total=0;
for b=1:nB_all
    if Sw_rep(b)==1
        if ismember(all_branches(b,1),subs_idx); P_total=P_total+Pf_rep(b); Q_total=Q_total+Qf_rep(b);
        elseif ismember(all_branches(b,2),subs_idx); P_total=P_total-Pf_rep(b); Q_total=Q_total-Qf_rep(b); end
    end
end
fprintf('\n  汇总: 受影响=%d 恢复=%d 未=%d 切负荷=%.2fkW\n',sum(pf_rep),sum(qv_rep&pf_rep>0),sum(~qv_rep&pf_rep>0),sum(L_rep(qv_rep))*1e3);
fprintf('  变电站: P=%.2fkW Q=%.2fkVar\n',P_total*1e3,Q_total*1e3);

function out=ternary(cond,a,b)
    if cond; out=a; else; out=b; end
end
