% Optimize a simple optimization problem.
function examplehs071_optizelle()
    % Execute the optimization
    main();
end

% Define a simple objective.
function self = MyObj()

    % Evaluation 
    self.eval = @(x) x(1)*x(4)*sum(x(1:3)) + x(3);

    % Gradient
    self.grad = @(x) [x(1)*x(4) + x(4)*sum(x(1:3));
        x(1)*x(4);
        x(1)*x(4) + 1;
        x(1)*sum(x(1:3))];

    % Hessian-vector product
    self.hessvec = @(x,dx) hessvec(x, dx);
end

% Hessian-vector product.
function H_dx = hessvec(x, dx)   
    H  = [2*x(4), x(4), x(4), 2*x(1) + x(2) + x(3);
          x(4),  0,  0, x(1);
          x(4),  0,  0, x(1);
          2*x(1) + x(2) + x(3), x(1), x(1), 0];
    
    % Compute the Hessian-vector product
    H_dx = H * dx;
end

% Define a simple equality
%
% g(x) = [ x(1)^2 + x(2)^2 + x(3)^2 + x(4)^2 = 40]
%
function self = MyEq()

    % y=g(x) 
    self.eval = @(x) sum(x.^2) - 40;

    % y=g'(x)dx
    self.p = @(x,dx) [2*x(1), 2*x(2), 2*x(3), 2*x(4)] * dx;

    % xhat=g'(x)*dy
    self.ps = @(x,dy)  [2*x(1); 2*x(2); 2*x(3); 2*x(4)] .* dy;

    % xhat=(g''(x)dx)*dy
    self.pps = @(x,dx,dy) [2*dx(1); 2*dx(2); 2*dx(3); 2*dx(4)] .* dy; 
end

% Define inequalities, and bounds on x
%
% h(x) = [ x(1)*x(2)*x(3)*x(4) >= 25 ] 
%        [ x(1) >= 1]
%        [ x(2) >= 1]
%        [ x(3) >= 1]
%        [ x(4) >= 1]
%        [x(1) <= 5] = [ -x(1) >= -5]
%        [x(2) <= 5] = [ -x(2) >= -5]
%        [x(3) <= 5] = [ -x(3) >= -5]
%        [x(4) <= 5] = [ -x(4) >= -5]
function self = MyIneq()

    % z=h(x) 
    self.eval = @(x) [prod(x) - 25; 
                      x(1) - 1;
                      x(2) - 1;
                      x(3) - 1;
                      x(4) - 1;
                      -x(1) + 5;
                      -x(2) + 5;
                      -x(3) + 5;
                      -x(4) + 5];

    % z=h'(x)dx
    self.p = @(x,dx) generateJac(x)' * dx;

    % xhat=h'(x)*dz
%     self.ps = @(x,dz) generateJac(x)' * dz;
    self.ps = @(x,dz) generateJac(x, dz);

    % xhat=(h''(x)dx)*dz
    % Since all constraints are affine, we have h''(x) = 0.
    self.pps = @(x,dx,dz) [ 0. ]; 
end

% Generate a dense version of the Jacobian.
function jac = generateJac(x)
   % Jacobian dimension is: number of constraints by number of variables.
   jac = [x(2)*x(3)*x(4), x(1)*x(3)*x(4), x(1)*x(2)*x(4), x(1)*x(2)*x(3);
          1, 0, 0, 0;
          0, 1, 0, 0;
          0, 0, 1, 0;
          0, 0, 0, 1;
          -1, 0, 0, 0;
          0, -1, 0, 0;
          0, 0, -1, 0;
          0, 0, 0, -1];
end

function jac = generateJac2(x)
   % Jacobian dimension is: number of constraints by number of variables.
   jac = [x(2)*x(3)*x(4), x(1)*x(3)*x(4), x(1)*x(2)*x(4), x(1)*x(2)*x(3);
          1, 0, 0, 0;
          0, 1, 0, 0;
          0, 0, 1, 0;
          0, 0, 0, 1;
          -1, 0, 0, 0;
          0, -1, 0, 0;
          0, 0, -1, 0;
          0, 0, 0, -1];
end

% Actually runs the program
function main()

    % Grab the Optizelle library
    global Optizelle;
    setupOptizelle();

    % Generate an initial guess 
    x = [1; 4.9; 3.5; 1.2];
    
    % Allocate memory for the equality multiplier 
    y = [0];

    % Allocate memory for the inequality multiplier 
    z = zeros(9, 1);
    
    % Create an optimization state
    state = Optizelle.Constrained.State.t( ...
        Optizelle.Rm,Optizelle.Rm,Optizelle.Rm,x,y,z);

    % Create a bundle of functions
    fns = Optizelle.Constrained.Functions.t;
    fns.f = MyObj();
    fns.g = MyEq();
    fns.h = MyIneq();

    % Solve the optimization problem
    state = Optizelle.Constrained.Algorithms.getMin( ...
        Optizelle.Rm,Optizelle.Rm,Optizelle.Rm,Optizelle.Messaging.stdout, ...
        fns,state);

    % Print out the reason for convergence
    fprintf('The algorithm converged due to: %s\n', ...
        Optizelle.OptimizationStop.to_string(state.opt_stop));

    % Print out the final answer
    fprintf('The optimal point is: (%e,%e,%e,%e)\n', state.x(1), state.x(2), ...
                                                     state.x(3), state.x(4));
end