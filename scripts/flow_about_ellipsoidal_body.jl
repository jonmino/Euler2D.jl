using Euler2D
using LinearAlgebra
using Unitful
using ShockwaveProperties
using StaticArrays

"""
    u0(x, p)

Accepts ``x∈ℝ^2`` and a vector of three parameters: free stream density, mach number, and temperature (understood in metric base units)
"""
function u0(x, p)
    pp = PrimitiveProps(p[1], SVector(p[2], 0.0), p[3])
    return ConservedProps(pp, DRY_AIR)
end

starting_parameters = SVector(0.662, 4.0, 220.0)
ambient = u0(nothing, starting_parameters)

x0 = 1.0u"m"
a0 = speed_of_sound(ambient, DRY_AIR)
ρ0 = density(ambient)
scale = EulerEqnsScaling(x0, ρ0, a0)

bcs = (
    ExtrapolateToPhantom(), # north 
    ExtrapolateToPhantom(), # south
    ExtrapolateToPhantom(), # east
    ExtrapolateToPhantom(), # west
    StrongWall(), # walls
)
bounds = ((-2.0, 0.0), (-1.5, 1.5))


x_ell = (t, params) -> params.h + params.a * cos(t)
y_ell = (t, params) -> params.k + params.b * sin(t)
params_ell = (a = 0.5, b = 1.5, h = 0.0, k = 0.0)

ell_obstacle = [ParametricObstacle(x_ell, y_ell, params_ell, :ellipse)]
ncells = (100, 150)

##

Euler2D.simulate_euler_equations_cells(
    u0,
    starting_parameters,
    1.0,
    bcs,
    ell_obstacle,
    bounds,
    ncells;
    mode = Euler2D.PRIMAL,
    gas = DRY_AIR,
    scale = scale,
    info_frequency = 20,
    write_frequency = 10,
    max_tsteps = 1000,
    output_tag = "ellipse_obstacle_primal",
    output_channel_size = 2,
    tasks_per_axis = 2,
);

##

Euler2D.simulate_euler_equations_cells(
    u0,
    starting_parameters,
    1.0,
    bcs,
    ell_obstacle,
    bounds,
    ncells;
    mode = Euler2D.TANGENT,
    gas = DRY_AIR,
    scale = scale,
    info_frequency = 20,
    write_frequency = 10,
    max_tsteps = 1000,
    output_tag = "ellipse_obstacle_tangent",
    output_channel_size = 2,
    tasks_per_axis = 2,
);

##

primal=load_cell_sim("data/ellipse_obstacle_primal.celltape");
tangent=load_cell_sim("data/ellipse_obstacle_tangent.celltape");