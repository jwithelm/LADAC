function ap = apCopterDragonflyAutoCreate( copter )

% aggressiveness (0-1)
aggr = 0.5;

is_flipped_allowed = 1;

g = 9.81;

ap.ca = loadParams( 'control_allocation_wls_params_default' );

ap.traj = loadParams( 'traj_params_default');

num_motors = size(copter.config.propPos_c,2);

[k,d] = propMapFitGetFactors(copter.prop.map_fit);
omega_max = motorStaticSpeed(copter.motor.KT,copter.motor.R,copter.bat.V,d,ap.ca.u_max);
omega_min = motorStaticSpeed(copter.motor.KT,copter.motor.R,copter.bat.V,d,ap.ca.u_min);


thrust_max = sum( k*omega_max.^2 );
thrust_min = sum( k*omega_min.^2 );
thrust_hover = copter.body.m * g;

omega_hover = sqrt( thrust_hover / k );

delta_thrust_max = min( thrust_max - thrust_hover, thrust_hover - thrust_min );

omega_delta_max = sqrt( ( thrust_hover + delta_thrust_max ) / k );
omega_delta_min = sqrt( ( thrust_hover - delta_thrust_max ) / k );

torque_delta_max = d * omega_delta_max^2;
torque_delta_min = d * omega_delta_min^2;

acc_up_max = thrust_max / copter.body.m;
acc_down_max = thrust_min / copter.body.m;

ap.psc.rm.accumax = aggr * ( acc_up_max - g );
ap.psc.rm.accdmax = aggr * ( g - acc_down_max );

prop_name_cell = strsplit(copter.prop.name,'x');
prop_diameter = str2num(prop_name_cell{1}) * 2.54/100;
A = num_motors * pi/4 * prop_diameter^2;
[ ~, ~, v_i0 ] = inducedVelocityWithUnitsAngleOfAttack( 0, -pi/2, thrust_hover, 1.225, A );


% temp: to do
ap.psc.rm.veldmax = aggr * v_i0;
ap.psc.rm.velumax = 10;
ap.psc.rm.velxymax = 15;


lean_max = pi/2 - asin( g / ( aggr * acc_up_max ) );
acc_xy_max = acc_up_max * sin( lean_max );
if is_flipped_allowed
    ap.atc.rm.leanmax = 2*pi;
else
    ap.atc.rm.leanmax = lean_max;
end
ap.atc.rm.leandamp = 1;
ap.atc.rm.yawratemax = 2*pi;

ap.psc.rm.accxymax = aggr * acc_xy_max;
ap.psc.rm.veltc = ap.psc.rm.velxymax / ap.psc.rm.accxymax;



M = zeros(3,num_motors);
for i=1:num_motors
    M(:,i) = evalin('caller',['copter.config.M_b_prop',num2str(i)]) * [1;0;0];
end

% propeller control effectiveness parameters
ap.cep.k 	= k;
ap.cep.d	= d;
ap.cep.x	= copter.config.propPos_c(1,:);
ap.cep.y	= copter.config.propPos_c(2,:);
ap.cep.z	= copter.config.propPos_c(3,:);
ap.cep.a	= copter.config.propDir(:)';
ap.cep.nx	= M(1,:);
ap.cep.ny	= M(2,:);
ap.cep.ip	= copter.prop.I;
ap.cep.kt	= copter.motor.KT;
ap.cep.vb	= copter.bat.V;
ap.cep.ri	= copter.motor.R;

% body control effectiveness parameters
ap.ceb.m    = copter.body.m;
ap.ceb.ixx  = copter.body.I(1,1);
ap.ceb.iyy  = copter.body.I(2,2);
ap.ceb.izz  = copter.body.I(3,3);
ap.ceb.ixy  = -copter.body.I(1,2);
ap.ceb.ixz  = -copter.body.I(1,3);
ap.ceb.iyz  = -copter.body.I(2,3);



L = cross( copter.config.propPos_c, M );

thrust_vector = zeros( num_motors, 1 );
torque_vector = zeros( num_motors, 1 );


thrust_vector(L(1,:)'>0) = thrust_hover + delta_thrust_max;
thrust_vector(L(1,:)'<0) = thrust_hover - delta_thrust_max;
roll_moment_max = L(1,:) * thrust_vector;

acc_roll_max = roll_moment_max / copter.body.I(1,1);

thrust_vector(L(2,:)'>0) = thrust_hover + delta_thrust_max;
thrust_vector(L(2,:)'<0) = thrust_hover - delta_thrust_max;
pitch_moment_max = L(2,:) * thrust_vector;

acc_pitch_max = pitch_moment_max / copter.body.I(2,2);

acc_roll_pitch_max = min( acc_roll_max, acc_pitch_max );


torque_vector(ap.cep.a>0) = torque_delta_max;
torque_vector(ap.cep.a<0) = -torque_delta_min;
yaw_moment_max = sum( torque_vector );

acc_yaw_max = yaw_moment_max / copter.body.I(3,3);


ap.atc.rm.leanfreq =  sqrt( aggr * acc_roll_pitch_max / lean_max );
ap.atc.rm.yawratetc = aggr * ap.atc.rm.yawratemax / acc_yaw_max;


ap.mtc = copter.motor.R*copter.prop.I/copter.motor.KT^2;

ap.ts = 0.0025;

% sensor filter
ap.sflt.D = 1;
ap.sflt.omega = 3 * 2/ap.mtc;

% lean angle controller
T_h = ap.mtc + 2/ap.sflt.omega;
max_roll_pitch_atti_error = 2;
k = maxError2FeedbackGain( max_roll_pitch_atti_error, acc_roll_pitch_max, T_h, aggr );
ap.atc.k.lean = k(1);
ap.atc.k.leanrate = k(2);
ap.atc.k.leanacc = k(3);

% yaw controller
max_yaw_atti_error = pi;
k = maxError2FeedbackGain( max_yaw_atti_error, acc_yaw_max, T_h, aggr );
ap.atc.k.yaw = k(1);
ap.atc.k.yawrate = k(2);
ap.atc.k.yawacc = k(3);

% position feedback controller
T_h = T_h + 2/ap.atc.rm.leanfreq;
p = -0.5*[1+1i,1-1i,4] * aggr / T_h;
% p = -0.5*[1,1,1] * aggr / T_h;
p = -0.5*[1.5,1+0.65i,1-0.65i] * aggr / T_h;
k = ndiFeedbackGainPlace(p,T_h);
ap.psc.k.pos = k(1);
ap.psc.k.vel = k(2);
ap.psc.k.acc = k(3);

end

function k = maxError2FeedbackGain( max_error, max_cntrl_input, T_h, aggr )

k_1_max = aggr * max_cntrl_input / max_error;

p_distr = [1,1,1];
p_1 = -( 1/(sum(p_distr)-2) .* k_1_max / T_h )^(1/3);

k = ndiFeedbackGainPlace(p_distr*p_1,T_h);
end