function [out] = HybridOCPDualSolver_redo(t,x,u,f,g,hX,hU,sX,R,x0,hXT,h,H,d,options)
% The code is a variation of the code provide in https://github.com/pczhao/hybridOCP
% Hybrid optimal control problem - dual solver
% ------------------------------------------------------------------------
% t     -- time indeterminate,      1-by-1 free msspoly
% x     -- state indeterminate,     I-by-1 cell of (n_i)-by-1 free msspoly
% u     -- control indeterminate,   I-by-1 cell of (m_i)-by-1 free msspoly
% f     -- dynamics, part 1,        I-by-1 cell of (n_i)-by-1 msspoly in x{i}
% g     -- dynamics, part 2,        I-by-1 cell of (n_i)-by-(m_i) msspoly in x{i}
% hX    -- domain (X_i),            I-by-1 cell of (~)-by-1 msspoly in x{i}
% hU    -- set U_i,                 I-by-1 cell of (~)-by-1 msspoly in u{i}
% sX    -- guard(i,j),              I-by-I cell of (~)-by-1 msspoly in x{i}
% R     -- reset map(i,j),          I-by-I cell of (n_j)-by-1 msspoly in x{i}
% x0    -- initial point,           I-by-1 cell of (n_i)-by-1 reals
% hXT   -- target set,              I-by-1 cell of (~)-by-1 msspoly in x{i}
% h     -- running cost,            I-by-1 cell of 1-by-1 msspoly in (t,x{i},u{i})
% H     -- terminal cost,           I-by-1 cell of 1-by-1 msspoly in x{i}
% Hp     -- intermediate cost,      I-by-1 cell of 1-by-1 msspoly in x{i}
% d     -- degree of relaxation,    positive even number (scalar)
% Tp     -- intermediate time       I-by-1 cell of positive scalar in [0,1]
% options  -- struct   
% ------------------------------------------------------------------------
% Solves the following hybrid optimal control problem:
% 
% inf  { \int_0^1 h(t,x,u) dt } + H( x(1) )
% s.t. \dot{x_i} = f_i + g_i * u
%      x_j(t+) = R_ij( x_i(t-) ) when { x_i(t-) \in S_ij }
%      x(0) = x0
%      x(t) \in X
%      x(T) \in XT
%      u(t) \in U
% 
% where:
% X_i  = { x | each hX{i}(x) >= 0 }          domain of mode i
% U_i  = { u | each hU{i}(u) >= 0 }          range of control in mode i
% S_ij = { x | each sX{i}(x) >= 0 } <= X_i   guard in mode i
% XT_i = { x | each hXT{i}(x)>= 0 } <= X_i   target set in mode i
% 
% We solve the following *weak formulation* via relaxation of degree 'd':
% With intermediate time cost in addition to the final time cost 
%
% sup  v_i(0,x_0)
% s.t. LFi(v_i) + h_i >= 0
%      v_i(T,x) <= H_i(T)
%      v_i(Ti,x) <= H'_i(Ti) % H'_i(t) is the intermediate time cost
%      function %The support of \mu_Ti is XT_i
%      v_i(t,x) <= v_j( t, R_ij (x) )
% ------------------------------------------------------------------------
% 'options' is a struct that contains:
%     .freeFinalTime:   1 = free final time, 0 = fixed final time (default: 0)
%     .MinimumTime:     1 = minimum time, 0 = o.w. (default: 0)
%     .withInputs:      1 = perform control synthesis, 0 = o.w. (default: 0)
%     .solver_options:  options that will be passed to SDP solver (default: [])
%     .svd_eps:         svd threshold (default: 1e3)
% ------------------------------------------------------------------------
% Attention: T = 1 is fixed number. To solve OCP for different time
% horizons, try scaling the dynamics and cost functions.
% 

%% Sanity check
if mod(d,2) ~= 0
    warning('d is not even. Using d+1 instead.');
    d = d+1;
end
nmodes = length(x);

max_m = 0;
for i = 1 : nmodes
    m = length(u{i});
    if m > max_m
        max_m = m;
    end
    if (length(f{i}) ~= length(x{i})) || (size(g{i},1) ~= length(x{i}))
        error('Inconsistent matrix size.');
    end
    if size(g{i},2) ~= m
        error('Inconsistent matrix size.');
    end
end

svd_eps = 1e3;
if nargin < 15, options = struct(); end
if isfield(options, 'svd_eps'), svd_eps = options.svd_eps; end
if ~isfield(options, 'freeFinalTime'), options.freeFinalTime = 0; end
if ~isfield(options, 'withInputs'), options.withInputs = 0; end

T = 1;
hT = t*(T-t);

if isempty(R)
    R = cell(nmodes,nmodes);
    for i = 1 : nmodes
    for j = 1 : nmodes
        if ~isempty(sX{i,j}), R{i,j} = x{i}; end
    end
    end
end

%% Setup spotless program
% define the program
prog_infos = {};
prog = spotsosprog;
prog = prog.withIndeterminate( t );

% constraints to keep track of
mu_idx = zeros(nmodes, 1);

% Create program variables in each mode
for i = 1 : nmodes
    
    prog = prog.withIndeterminate( x{i} );
    prog = prog.withIndeterminate( u{i} );
    
    % create v(i)
    vmonom{ i } = monomials( [ t; x{ i } ], 0:d );
    [ prog, v{ i }, ~ ] = prog.newFreePoly( vmonom{ i } );
    
%     % create the variables that will be used later
    vT{ i } = subs( v{ i }, t, T );
    dvdt{ i } = diff( v{ i }, t );
    dvdx{ i } = diff( v{ i }, x{ i } );
    Lfv{ i } = dvdt{ i } + dvdx{ i } * f{ i };
    Lgv{ i } = dvdx{ i } * g{ i };
    Lv{ i } = Lfv{ i } + Lgv{ i } * u{ i };
end

% creating the constraints and cost function
obj = 0;
% constraint = [];
for i = 1 : nmodes
    % Lv_i + h_i >= 0                   Dual: mu   
    disp('Adding Liouville dual constraint');   
    [prog,tk] = sosOnK( prog, Lv{ i } + h{ i }, ...
                   [ t; x{ i }; u{ i } ], [ hT; hX{ i }; hU{ i } ], d);
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%           
    sosinfos.var = [ t; x{ i }; u{ i } ];
    sosinfos.constraints = [ hT; hX{ i }; hU{ i } ];
    sosinfos.nbsos = size(sosinfos.constraints,1);
    sosinfos.dualconstraint =  Lv{ i } + h{ i };
    sosinfos.testfonction_degree = d;
    sosinfos.residu_max = 0;
    sosinfos.residu_sum = 0;
    prog_infos = [prog_infos;sosinfos];
    %%%%%%%%%%%%%%%%%%%%%%%%%%%
    mu_idx(i) = size( prog.sosExpr, 1 );
    
    
    % v(T,x) <= H_i(x)                  Dual: muT
    if ~isempty( hXT{ i } )
        disp('Adding Final time constraint');
        if options.freeFinalTime
            assert(0); % Should not be trigger in this version of the tool
            prog = sosOnK( prog, H{ i } - v{ i }, [ t; x{ i } ], [ hT; hXT{ i } ], d );
            %%%%%%%%%%%%%%%%%%%%%%%%%%%
            sosinfos.var = [ t; x{ i } ];
            sosinfos.constraints = [ hT; hXT{ i } ];
            sosinfos.nbsos = size(sosinfos.constraints,1);
            sosinfos.dualconstraint =  H{ i } - v{ i };
            sosinfos.testfonction_degree = d;
            sosinfos.residu_max = 0;
            sosinfos.residu_sum = 0;
            prog_infos = [prog_infos;sosinfos];       
            %%%%%%%%%%%%%%%%%%%%%%%%%%%
        else
            prog = sosOnK( prog, H{ i } - vT{ i }, x{ i }, hXT{ i }, d );
            %%%%%%%%%%%%%%%%%%%%%%%%%%%
            sosinfos.var = x{ i };
            sosinfos.constraints = hXT{ i };
            sosinfos.nbsos = size(sosinfos.constraints,1);
            sosinfos.dualconstraint =  H{ i } - vT{ i };
            sosinfos.testfonction_degree = d;
            sosinfos.residu_max = 0;
            sosinfos.residu_sum = 0;
            prog_infos = [prog_infos;sosinfos];
            %%%%%%%%%%%%%%%%%%%%%%%%%%%
        end
    end
    
    % v_i(t,x) <= v_j (t,R(x))          Dual: muS
    for j = 1 : nmodes
        if ( ~isempty( sX{ i, j } ) ) % if its empty there isn't a guard between these        
            disp('Adding transition constraint');
            vj_helper = subs( v{ j }, x{ j }, R{ i, j } ); 
            prog = sosOnK( prog, vj_helper - v{ i }, [ t; x{ i } ] , [ hT; sX{ i, j } ], d );
            %%%%%%%%%%%%%%%%%%%%%%%%%%%
            sosinfos.var =  [ t; x{ i } ];
            sosinfos.constraints = [ hT; sX{ i, j } ];
            sosinfos.nbsos = size(sosinfos.constraints,1);
            sosinfos.dualconstraint =  vj_helper - v{ i };
            sosinfos.testfonction_degree = d;
            sosinfos.residu_max = 0;
            sosinfos.residu_sum = 0;
            prog_infos = [prog_infos;sosinfos];
            %%%%%%%%%%%%%%%%%%%%%%%%%%%
        end
    end
    
    % Objective function
    if ~isempty( x0{ i } )
        obj = obj + subs( v{ i }, [ t; x{i} ], [ 0; x0{i} ] );
    end
end


% set options
spot_options = spot_sdp_default_options();
spot_options.verbose = 1;

if isfield(options, 'solver_options')
    spot_options.solver_options = options.solver_options;
end

%% Solve with mosek SDP/SoS solver
tic;
[sol, y, dual_basis, ~] = prog.minimize( -obj, @spot_mosek, spot_options );
% [sol] = prog.minimize( -obj, @spot_mosek, spot_options );

%%%%%%%%%%%%%%%%%%%%%%%%%%% Numerical accuracy evaluation
Glist  = sol.gramMatrices;
Gramlist={};
for i=1:length(Glist)...
Glistnum = fn(sol.eval(Glist{i}));
mineig(i) = min(eig(Glistnum(0)));
Gramlist{i} = Glistnum(0);
Grammono{i} = sol.eval( sol.gramMonomials{i});
sos_approx{i} = Grammono{i}'*Gramlist{i}*Grammono{i};
end
SDP = mineig<0;
%%%%%%%%%%%%%%%%%%%%%%%%%%%

sos_solution = [sol.eval(sol.prog.sosExpr(:))];
c = 1;

%%%%%%%%%%%%%%%%%%%%%%%%%%%
for i = 1:length(prog_infos)
    infos_tmp = prog_infos{i};
    tmpsos = sos_solution(c:c+infos_tmp.nbsos-1);
    s0 = sos_solution(c+infos_tmp.nbsos);
    sos_residu = sol.eval(infos_tmp.dualconstraint) - (s0 + tmpsos'*infos_tmp.constraints);
    prog_infos{i}.residu_max = max(abs(sos_residu.coeff));
    prog_infos{i}.residu_sum = sum(abs(sos_residu.coeff));   

    for j = 1:infos_tmp.nbsos
        sos_subresidu = sos_solution(c+j-1) - sos_approx{c+j-1};
        prog_infos{i}.subresidu_max(j) = max(abs(sos_subresidu.coeff));
    end
      sos_subresidu = sos_solution(c+infos_tmp.nbsos) - sos_approx{c+infos_tmp.nbsos};
      prog_infos{i}.subresidu_max(infos_tmp.nbsos+1) = max(abs(sos_subresidu.coeff));

    c = c+infos_tmp.nbsos+1;
end
prog_infos{:};
%%%%%%%%%%%%%%%%%%%%%%%%%%%

out.time = toc;

out.pval = double(sol.eval(obj));
out.sol = sol;
out.infos = prog_infos;
%% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% return;
%% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Store control Synthesis information for later
if ~options.withInputs
    out.u = [];
    return;
end

u_infos.nmodes = nmodes;
u_infos.uout = cell( nmodes, max_m );
u_infos.u_real_basis = cell( nmodes, 1 );
u_infos.mu_idx = mu_idx;
u_infos.svd_eps = svd_eps;
u_infos.dual_basis = dual_basis;
u_infos.y = y;
out.u_infos = u_infos;
