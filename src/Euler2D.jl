module Euler2D

using LinearAlgebra
using Tullio
using ShockwaveProperties
using Unitful

include("flux1d.jl")
include("flux2d.jl")
include("fvm.jl")
include("simulations.jl")

# boundary condition types
export BoundaryCondition, PeriodicAxis, EdgeBoundary
export PhantomEdge
export StrongWall, FixedPhantomOutside, ExtrapolateToPhantom
export SupersonicInflow

# EulerSim methods
export EulerSim
export cell_boundaries, cell_centers, nth_step

# methods
export interface_signal_speeds, maximum_Δt
export step_euler_hll!, simulate_euler_equations

end