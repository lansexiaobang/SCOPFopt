function [results, success, raw] = optizellescopf_solver(om, model, mpopt)
%IPOPTOPF_SOLVER  Solves AC optimal power flow with security constraints using IPOPT.
%
%   [RESULTS, SUCCESS, RAW] = OPTIZELLESCOPF_SOLVER(OM, MODEL, MPOPT)
%
%   Inputs are an OPF model object, SCOPF model and a MATPOWER options struct.
%
%   Model is a struct with following fields:
%       .cont Containts a list of contingencies
%       .index Contains functions to handle proper indexing of SCOPF variables
%           .getGlobalIndices
%           .getLocalIndicesOPF
%           .getLocalIndicesSCOPF
%           .getREFgens
%           .getPVbuses
%
%   Outputs are a RESULTS struct, SUCCESS flag and RAW output struct.
%
%   The internal x that ipopt works with has structure
%   [Va1 Vm1 Qg1 Pg_ref1... VaN VmN QgN Pg_refN] [Vm Pg] for all contingency scenarios 1..N
%   with corresponding bounds xmin < x < xmax
%
%   We impose nonlinear equality and inequality constraints g(x) and h(x)
%   with corresponding bounds cl < [g(x); h(x)] < cu
%   and linear constraints l < Ax < u.
%
%   See also OPF, IPOPT.

%   MATPOWER
%   Copyright (c) 2000-2017, Power Systems Engineering Research Center (PSERC)
%   by Ray Zimmerman, PSERC Cornell
%   and Carlos E. Murillo-Sanchez, PSERC Cornell & Universidad Nacional de Colombia
%
%   This file is part of MATPOWER.
%   Covered by the 3-clause BSD License (see LICENSE file for details).
%   See http://www.pserc.cornell.edu/matpower/ for more info.


%% TODO
% need to work more efficiently with sparse indexing during construction
% of global hessian/jacobian

% how to account for the sparse() leaving out zeros from the sparse
% structure? We want to have exactly same structure across scenarios

%%----- initialization -----
%% define named indices into data matrices
[PQ, PV, REF, NONE, BUS_I, BUS_TYPE, PD, QD, GS, BS, BUS_AREA, VM, ...
    VA, BASE_KV, ZONE, VMAX, VMIN, LAM_P, LAM_Q, MU_VMAX, MU_VMIN] = idx_bus;
[GEN_BUS, PG, QG, QMAX, QMIN, VG, MBASE, GEN_STATUS, PMAX, PMIN, ...
    MU_PMAX, MU_PMIN, MU_QMAX, MU_QMIN, PC1, PC2, QC1MIN, QC1MAX, ...
    QC2MIN, QC2MAX, RAMP_AGC, RAMP_10, RAMP_30, RAMP_Q, APF] = idx_gen;
[F_BUS, T_BUS, BR_R, BR_X, BR_B, RATE_A, RATE_B, RATE_C, ...
    TAP, SHIFT, BR_STATUS, PF, QF, PT, QT, MU_SF, MU_ST, ...
    ANGMIN, ANGMAX, MU_ANGMIN, MU_ANGMAX] = idx_brch;
[PW_LINEAR, POLYNOMIAL, MODEL, STARTUP, SHUTDOWN, NCOST, COST] = idx_cost;

%% unpack data
mpc = get_mpc(om);
[baseMVA, bus, gen, branch, gencost] = ...
    deal(mpc.baseMVA, mpc.bus, mpc.gen, mpc.branch, mpc.gencost);
[vv, ll, nn] = get_idx(om);

cont = model.cont;


%% problem dimensions
nb = size(bus, 1);          %% number of buses
ng = size(gen, 1);          %% number of gens
nl = size(branch, 1);       %% number of branches
ns = size(cont, 1);         %% number of scenarios (nominal + ncont)

% get indices of REF gen and of REF/PV buses
[REFgen_idx, nREFgen_idx] = model.index.getREFgens(mpc);
[REFbus_idx,nREFbus_idx] = model.index.getXbuses(mpc,3);%3==REF
[PVbus_idx, nPVbus_idx] = model.index.getXbuses(mpc,2);%2==PV

% indices of local OPF solution vector x = [VA VM PG QG]
[VAscopf, VMscopf, PGscopf, QGscopf] = model.index.getLocalIndicesSCOPF(mpc);
[VAopf, VMopf, PGopf, QGopf] = model.index.getLocalIndicesOPF(mpc);

%% build admittance matrices for nominal case
[Ybus, Yf, Yt] = makeYbus(baseMVA, bus, branch);

%% bounds on optimization vars xmin <= x <= xmax 
[x0, xmin, xmax] = getv(om); %returns standard OPF form [Va Vm Pg Qg]

% add small pertubation to UB so that we prevent ipopt removing variables
% for which LB=UB, except the Va of the reference bus
tmp = xmax(REFbus_idx);
xmax = xmax + 1e-10;
xmax(REFbus_idx) = tmp;

% replicate bounds for all scenarios and append global limits
xl = xmin([VAopf VMopf(nPVbus_idx) QGopf PGopf(REFgen_idx)]); %local variables
xg = xmin([VMopf(PVbus_idx) PGopf(nREFgen_idx)]); %global variables
xmin = [repmat(xl, [ns, 1]); xg];

xl = xmax([VAopf VMopf(nPVbus_idx) QGopf PGopf(REFgen_idx)]); %local variables
xg = xmax([VMopf(PVbus_idx) PGopf(nREFgen_idx)]); %global variables
xmax = [repmat(xl, [ns, 1]); xg];

%% try to select an interior initial point based on bounds
if mpopt.opf.init_from_mpc ~= 1
    ll = xmin; uu = xmax;
    ll(xmin == -Inf) = -1e10;               %% replace Inf with numerical proxies
    uu(xmax ==  Inf) =  1e10;
    x0 = (ll + uu) / 2;                     %% set x0 mid-way between bounds
    k = find(xmin == -Inf & xmax < Inf);    %% if only bounded above
    x0(k) = xmax(k) - 1;                    %% set just below upper bound
    k = find(xmin > -Inf & xmax == Inf);    %% if only bounded below
    x0(k) = xmin(k) + 1;                    %% set just above lower bound
    
    % adjust voltage angles to match reference bus
    Varefs = bus(REFbus_idx, VA) * (pi/180);
    for i = 0:ns-1
        idx = model.index.getGlobalIndices(mpc, ns, i);
        x0(idx(VAscopf)) = Varefs(1);
    end
end

%% find branches with flow limits
il_ = find(branch(:, RATE_A) ~= 0 & branch(:, RATE_A) < 1e10);
il = [1:nl]';               %% we assume every branch has implicit bounds
                             % TODO insert default limits to branches that
                             % do not satisfy condition above
nl2 = length(il);           %% number of constrained lines

if size(il_, 1) ~= nl2
   error('Not all branches have specified RATE_A field.'); 
end


%% build linear constraints l <= A*x <= u

A = [];
l = [];
u = [];


%% build local connectivity matrices
f = branch(:, F_BUS);                           %% list of "from" buses
t = branch(:, T_BUS);                           %% list of "to" buses
Cf = sparse(1:nl, f, ones(nl, 1), nl, nb);      %% connection matrix for line & from buses
Ct = sparse(1:nl, t, ones(nl, 1), nl, nb);      %% connection matrix for line & to buses
Cl = Cf + Ct;                                   %% for each line - from & to 
Cb_nominal = Cl' * Cl + speye(nb);              %% for each bus - contains adjacent buses
Cl2_nominal = Cl(il, :);                        %% branches with active flow limit
Cg = sparse(gen(:, GEN_BUS), (1:ng)', 1, nb, ng); %%locations where each gen. resides

%% Jacobian of constraints
Js = sparse(0,0);

for i = 0:ns-1
    %update Cb to reflect the bus connectivity caused by contingency
    Cb = Cb_nominal;
    if (model.cont(i+1) > 0)
        c = model.cont(i+1);
        f = branch(c, F_BUS);                           %% "from" bus
        t = branch(c, T_BUS);                           %% "to" bus
        Cb(f,t) = 0;
        Cb(t,f) = 0;
    end
    
    %update Cl to reflect the contingency
    Cl2 = Cl2_nominal;
    if (model.cont(i+1) > 0)
        c = model.cont(i+1);
        Cl2(c, :) = 0;
    end
    
    % Jacobian wrt local variables
    %     dVa  dVm(nPV)   dQg   dPg(REF)   <- local variables for each scenario
    %    | Cb     Cb'      0     Cg' | ('one' at row of REF bus, otherwise zeros) 
    %    |                           |
    %    | Cb     Cb'      Cg     0  |
    %    |                           |
    %    | Cl     Cl'      0      0  | 
    %    |                           |
    %    | Cl     Cl'      0      0  |
    Js_local = [
        Cb      Cb(:, nPVbus_idx)    sparse(nb, ng)   Cg(:, REFgen_idx);
        Cb      Cb(:, nPVbus_idx)     Cg              sparse(nb, 1);
        Cl2     Cl2(:, nPVbus_idx)   sparse(nl2, ng+1);
        Cl2     Cl2(:, nPVbus_idx)   sparse(nl2, ng+1);
    ];
    % Jacobian wrt global variables
    %     dVm(PV) dPg(nREF)   <- global variables for all scenarios
    %    | Cb'        Cg'  | ('one' at row of REF bus, otherwise zeros) 
    %    |                 |
    %    | Cb'         0   |
    %    |                 |
    %    | Cl'         0   |
    %    |                 |
    %    | Cl'         0   |
    Js_global = [
     Cb(:, PVbus_idx)  Cg(:, nREFgen_idx);
     Cb(:, PVbus_idx)  sparse(nb, ng-1);
     Cl2(:, PVbus_idx) sparse(nl2, ng-1);
     Cl2(:, PVbus_idx) sparse(nl2, ng-1);
    ];

    Js = [Js;
          sparse(size(Js_local,1), i*size(Js_local,2)) Js_local sparse(size(Js_local,1), (ns-1-i)*size(Js_local,2)) Js_global];

%     Js = kron(eye(ns), Js_local); %replicate jac. w.r.t local variables
%     Js = [Js kron(ones(ns,1), Js_global)]; % replicate and append jac w.r.t global variables
end
Js = [Js; A]; %append linear constraints

%% Hessian of lagrangian Hs = f(x)_dxx + c(x)_dxx + h(x)_dxx
Hs = sparse(0,0);
Hs_gl = sparse(0,0);

for i = 0:ns-1
    %update Cb to reflect the bus connectivity caused by contingency
    Cb = Cb_nominal;
    if (model.cont(i+1) > 0)
        c = model.cont(i+1);
        f = branch(c, F_BUS);                           %% "from" bus
        t = branch(c, T_BUS);                           %% "to" bus
        Cb(f,t) = 0;
        Cb(t,f) = 0;
    end
    
    %update Cl to reflect the contingency
    Cl2 = Cl2_nominal;
    if (model.cont(i+1) > 0)
        c = model.cont(i+1);
        Cl2(c, :) = 0;
    end

    %--- hessian wrt. scenario local variables ---

    %          dVa  dVm(nPV)  dQg dPg(REF)
    % dVa     | Cb     Cb'     0     0  | 
    %         |                         |
    % dVm(nPV)| Cb'    Cb'     0     0  |
    %         |                         |
    % dQg     |  0      0      0     0  |
    %         |                         |
    % dPg(REF)|  0      0      0    Cg' | (only nominal case has Cg', because it is used in cost function)

    Hs_ll =[
        Cb                Cb(:, nPVbus_idx)          sparse(nb, ng+1);%assuming 1 REF gen
        Cb(nPVbus_idx,:)  Cb(nPVbus_idx, nPVbus_idx) sparse(length(nPVbus_idx), ng+1);
                   sparse(ng+1, nb+length(nPVbus_idx)+ng+1);
    ];
    %replicate hess. w.r.t local variables
    %Hs = kron(eye(ns), Hs_ll); 
    
    %set d2Pg(REF) to 1 in nominal case
    if (i==0)
        Hs_ll(nb+length(nPVbus_idx)+ng+1, nb+length(nPVbus_idx)+ng+1) = 1;
    end

    %--- hessian w.r.t local-global variables ---

    %          dVm(PV)  dPg(nREF)
    % dVa     | Cb'     0    | 
    %         |              |
    % dVm(nPV)| Cb'     0    |
    %         |              |
    % dQg     |  0      0    |
    %         |              |
    % dPg(REF)|  0      0    | 
    Hs_lg  = [
       Cb(:, PVbus_idx)           sparse(nb, ng-1);
       Cb(nPVbus_idx, PVbus_idx)  sparse(length(nPVbus_idx), ng-1);
       sparse(ng+length(REFgen_idx), length(PVbus_idx)+ng-1)
    ];
    %Hs_lg = kron(ones(ns,1), Hs_lg);
    
    Hs = [Hs;
          sparse(size(Hs_ll,1), i*size(Hs_ll,2)) Hs_ll sparse(size(Hs_ll,1), (ns-1-i)*size(Hs_ll,2)) Hs_lg];
    Hs_gl = [Hs_gl Hs_lg'];
    
end

% --- hessian w.r.t global variables ---

%        dVm(PV)  dPg(nREF)
% dVm(PV)  | Cb'  0   |
%          |          |
% dPg(nREF)| 0  f_xx' |
Hs_gg =[
    Cb_nominal(PVbus_idx, PVbus_idx)          sparse(length(PVbus_idx), ng-1);
    sparse(ng-1, length(PVbus_idx))               eye(ng-1);
];

% --- Put together local and global hessian ---
% local hessians sits at (1,1) block
% hessian w.r.t global variables is appended to lower right corner (2,2)
% and hessian w.r.t local/global variables to the (1,2) and (2,1) blocks
%        (l)      (g)
% (l) | Hs_ll    Hs_lg |
%     |                |
% (g) | Hs_gl    Hs_gg |
Hs = [Hs;
      Hs_gl   Hs_gg];
      

Hs = tril(Hs);

%% set options struct for IPOPT
options.ipopt = ipopt_options([], mpopt);

%% extra data to pass to functions
options.auxdata = struct( ...
    'om',       om, ...
    'cont',     cont, ...
    'index',    model.index, ...
    'mpopt',    mpopt, ...
    'il',       il, ...
    'A',        A, ...
    'Js',       Js, ...
    'Hs',       Hs    );

%% define variable and constraint bounds
options.lb = xmin;
options.ub = xmax;
options.cl = [repmat([zeros(2*nb, 1);  -Inf(2*nl2, 1)], [ns, 1]); l];
options.cu = [repmat([zeros(2*nb, 1); zeros(2*nl2, 1)], [ns, 1]); u+1e10]; %add 1e10 so that ipopt doesn't remove l==u case

%% assign function handles
funcs.objective         = @objective;
funcs.gradient          = @gradient;
funcs.constraints       = @constraints;
funcs.jacobian          = @jacobian;
funcs.hessian           = @hessian;
funcs.jacobianstructure = @(d) Js;
funcs.hessianstructure  = @(d) Hs;

%% run the optimization, call ipopt
if 1 %have_fcn('ipopt_auxdata')
    [x, info] = ipopt_auxdata(x0,funcs,options);
else
    [x, info] = ipopt(x0,funcs,options);
end

if info.status == 0 || info.status == 1
    success = 1;
else
    success = 0;
    display(['Ipopt finished with error: ', num2str(info.status)]);
end

if isfield(info, 'iter')
    meta.iterations = info.iter;
else
    meta.iterations = [];
end

idx_nom = model.index.getGlobalIndices(mpc, ns, 0); %evaluate cost of nominal case (only Pg/Qg are relevant) 
f = opf_costfcn(x(idx_nom([VAscopf VMscopf PGscopf QGscopf])), om);

% %% update solution data for nominal senario and global vars
% Va = x(vv.i1.Va:vv.iN.Va);
% Vm = x(vv.i1.Vm:vv.iN.Vm);
% Pg = x(ns*2*nb + (1:ng));
% Qg = x(ns*2*nb + ng + (1:ng));
% V = Vm .* exp(1j*Va);
% 
% %%-----  calculate return values  -----
% %% update voltages & generator outputs
% bus(:, VA) = Va * 180/pi;
% bus(:, VM) = Vm;
% gen(:, PG) = Pg * baseMVA;
% gen(:, QG) = Qg * baseMVA;
% gen(:, VG) = Vm(gen(:, GEN_BUS));
% 
% %% compute branch flows
% [Ybus, Yf, Yt] = makeYbus(baseMVA, bus, branch);
% Sf = V(branch(:, F_BUS)) .* conj(Yf * V);  %% cplx pwr at "from" bus, p.u.
% St = V(branch(:, T_BUS)) .* conj(Yt * V);  %% cplx pwr at "to" bus, p.u.
% branch(:, PF) = real(Sf) * baseMVA;
% branch(:, QF) = imag(Sf) * baseMVA;
% branch(:, PT) = real(St) * baseMVA;
% branch(:, QT) = imag(St) * baseMVA;
    
%pack some additional info to output so that we can verify the solution
meta.Ybus = Ybus;
meta.Yf = Yf;
meta.Yt = Yt;
meta.lb = options.lb;
meta.ub = options.ub;
meta.A = A;

raw = struct('info', info.status, 'meta', meta, 'numIter', info.iter, 'overallAlgorithm', info.cpu);
results = struct('f', f, 'x', x);

%% -----  callback functions  -----
function f = objective(x, d)
mpc = get_mpc(d.om);
ns = size(d.cont, 1);           %% number of scenarios (nominal + ncont)

% use nominal case to evaluate cost fcn (only pg/qg are relevant)
idx_nom = d.index.getGlobalIndices(mpc, ns, 0);
[VAscopf, VMscopf, PGscopf, QGscopf] = d.index.getLocalIndicesSCOPF(mpc);

f = opf_costfcn(x(idx_nom([VAscopf VMscopf PGscopf QGscopf])), d.om);

function grad = gradient(x, d)
mpc = get_mpc(d.om);
ns = size(d.cont, 1);           %% number of scenarios (nominal + ncont)

%evaluate grad of nominal case
idx_nom = d.index.getGlobalIndices(mpc, ns, 0);
[VAscopf, VMscopf, PGscopf, QGscopf] = d.index.getLocalIndicesSCOPF(mpc);
[VAopf, VMopf, PGopf, QGopf] = d.index.getLocalIndicesOPF(mpc);

[f, df, d2f] = opf_costfcn(x(idx_nom([VAscopf VMscopf PGscopf QGscopf])), d.om);

grad = zeros(size(x,1),1);
grad(idx_nom(PGscopf)) = df(PGopf); %nonzero only nominal case Pg


function constr = constraints(x, d)
mpc = get_mpc(d.om);
nb = size(mpc.bus, 1);          %% number of buses
ng = size(mpc.gen, 1);          %% number of gens
nl = size(mpc.branch, 1);       %% number of branches
ns = size(d.cont, 1);           %% number of scenarios (nominal + ncont)
NCONSTR = 2*nb + 2*nl;

constr = zeros(ns*(NCONSTR), 1);

[VAscopf, VMscopf, PGscopf, QGscopf] = d.index.getLocalIndicesSCOPF(mpc);
[VAopf, VMopf, PGopf, QGopf] = d.index.getLocalIndicesOPF(mpc);

for i = 0:ns-1
    cont = d.cont(i+1);
    idx = d.index.getGlobalIndices(mpc, ns, i);
    [Ybus, Yf, Yt] = makeYbus(mpc.baseMVA, mpc.bus, mpc.branch, cont);
    [hn_local, gn_local] = opf_consfcn(x(idx([VAscopf VMscopf PGscopf QGscopf])), d.om, Ybus, Yf, Yt, d.mpopt, d.il);
    constr(i*(NCONSTR) + (1:NCONSTR)) = [gn_local; hn_local];
end

if ~isempty(d.A)
    constr = [constr; d.A*x]; %append linear constraints
end


function J = jacobian(x, d)
mpc = get_mpc(d.om);
nb = size(mpc.bus, 1);          %% number of buses
nl = size(mpc.branch, 1);       %% number of branches
ns = size(d.cont, 1);           %% number of scenarios (nominal + ncont)
NCONSTR = 2*nb + 2*nl;          %% number of constraints (eq + ineq)

J = sparse(ns*(NCONSTR), size(x,1));

% get indices of REF gen and PV bus
[REFgen_idx, nREFgen_idx] = d.index.getREFgens(mpc);
[PVbus_idx, nPVbus_idx] = d.index.getXbuses(mpc,2);%2==PV

[VAscopf, VMscopf, PGscopf, QGscopf] = d.index.getLocalIndicesSCOPF(mpc);
[VAopf, VMopf, PGopf, QGopf] = d.index.getLocalIndicesOPF(mpc);

for i = 0:ns-1
    %compute local indices
    idx = d.index.getGlobalIndices(mpc, ns, i);
    
    cont = d.cont(i+1);
    [Ybus, Yf, Yt] = makeYbus(mpc.baseMVA, mpc.bus, mpc.branch, cont);
    [hn, gn, dhn, dgn] = opf_consfcn(x(idx([VAscopf VMscopf PGscopf QGscopf])), d.om, Ybus, Yf, Yt, d.mpopt, d.il);
    dgn = dgn';
    dhn = dhn';
    
    %jacobian wrt local variables
    J(i*NCONSTR + (1:NCONSTR), idx([VAscopf VMscopf(nPVbus_idx) QGscopf PGscopf(REFgen_idx)])) = [dgn(:,[VAopf VMopf(nPVbus_idx) QGopf PGopf(REFgen_idx)]);...
                                                                                                  dhn(:,[VAopf VMopf(nPVbus_idx) QGopf PGopf(REFgen_idx)])];
    %jacobian wrt global variables
    J(i*NCONSTR + (1:NCONSTR), idx([VMscopf(PVbus_idx) PGscopf(nREFgen_idx)])) = [dgn(:, [VMopf(PVbus_idx) PGopf(nREFgen_idx)]);...
                                                                                  dhn(:, [VMopf(PVbus_idx) PGopf(nREFgen_idx)])];
end
J = [J; d.A]; %append Jacobian of linear constraints


function H = hessian(x, sigma, lambda, d)
mpc = get_mpc(d.om);
nb = size(mpc.bus, 1);          %% number of buses
ng = size(mpc.gen, 1);          %% number of gens
nl = size(mpc.branch, 1);       %% number of branches
ns = size(d.cont, 1);           %% number of scenarios (nominal + ncont)
NCONSTR = 2*nb + 2*nl;

H = sparse(size(x,1), size(x,1));

% get indices of REF gen and PV bus
[REFgen_idx, nREFgen_idx] = d.index.getREFgens(mpc);
[PVbus_idx, nPVbus_idx] = d.index.getXbuses(mpc,2);%2==PV

[VAscopf, VMscopf, PGscopf, QGscopf] = d.index.getLocalIndicesSCOPF(mpc);
[VAopf, VMopf, PGopf, QGopf] = d.index.getLocalIndicesOPF(mpc);

for i = 0:ns-1
    %compute local indices and its parts
    idx = d.index.getGlobalIndices(mpc, ns, i);
    
    cont = d.cont(i+1);
    [Ybus, Yf, Yt] = makeYbus(mpc.baseMVA, mpc.bus, mpc.branch, cont);
    
    lam.eqnonlin   = lambda(i*NCONSTR + (1:2*nb));
    lam.ineqnonlin = lambda(i*NCONSTR + 2*nb + (1:2*nl));
    H_local = opf_hessfcn(x(idx([VAscopf VMscopf PGscopf QGscopf])), lam, sigma, d.om, Ybus, Yf, Yt, d.mpopt, d.il);
    
    % H_ll (PG_ref relevant only in nominal case, added to global part)
     H(idx([VAscopf VMscopf(nPVbus_idx) QGscopf]), idx([VAscopf VMscopf(nPVbus_idx) QGscopf])) =...
            H_local([VAopf VMopf(nPVbus_idx) QGopf], [VAopf VMopf(nPVbus_idx) QGopf]);
    
    % H_lg and H_gl (PG parts are implicitly zero, could leave them out)
    H(idx([VAscopf VMscopf(nPVbus_idx) QGscopf PGscopf(REFgen_idx)]), idx([VMscopf(PVbus_idx) PGscopf(nREFgen_idx)])) = ...
            H_local([VAopf VMopf(nPVbus_idx) QGopf PGopf(REFgen_idx)], [VMopf(PVbus_idx) PGopf(nREFgen_idx)]);
    H(idx([VMscopf(PVbus_idx) PGscopf(nREFgen_idx)]), idx([VAscopf VMscopf(nPVbus_idx) QGscopf PGscopf(REFgen_idx)])) = ...
            H_local([VMopf(PVbus_idx) PGopf(nREFgen_idx)], [VAopf VMopf(nPVbus_idx) QGopf PGopf(REFgen_idx)]);
        
    % H_gg hessian w.r.t global variables (and PG_ref_0) 
    if i == 0
        % H_pg at non-reference gens, these are global variables
        H(idx([PGscopf(nREFgen_idx)]), idx([PGscopf(nREFgen_idx)])) = ...
            H_local([PGopf(nREFgen_idx)], [PGopf(nREFgen_idx)]);
        
        % H_pgref is local variable for nominal scenario, but used in f()
        H(idx([PGscopf(REFgen_idx)]), idx([PGscopf(REFgen_idx)])) = ...
            H_local([PGopf(REFgen_idx)], [PGopf(REFgen_idx)]);
    end
    
    %each scenario contributes to hessian w.r.t global VM variables at PV buses
    H(idx([VMscopf(PVbus_idx)]), idx([VMscopf(PVbus_idx)])) = ...
        H(idx([VMscopf(PVbus_idx)]), idx([VMscopf(PVbus_idx)])) + ...
        H_local([VMopf(PVbus_idx)], [VMopf(PVbus_idx)]);
end

H = tril(H);