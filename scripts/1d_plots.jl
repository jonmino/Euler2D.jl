using Euler2D
using ShockwaveProperties
using Unitful

##

function simulate_euler_1d(
    x_min::Float64,
    x_max::Float64,
    ncells_x::Int,
    x_bcs::BoundaryCondition,
    T::Float64,
    u0::Function;
    gas::CaloricallyPerfectGas = DRY_AIR,
    CFL = 0.75,
    max_tsteps = typemax(Int),
    write_output = true,
    output_tag = "euler_1d",
)
    write_output = write_output && !isempty(output_tag)
    if write_output
        tape_file = joinpath("data", output_tag * ".tape")
        u_tape = open(tape_file; write = true, read = true, create = true)
    end

    xs = range(x_min, x_max; length = ncells_x + 1)
    Δx = step(xs)
    u = stack([u0(x + Δx / 2) for x ∈ xs[1:end-1]])
    u_next = zeros(eltype(u), size(u))
    t = [0.0]

    write_output && write(u_tape, u)

    while ((!(t[end] > T || t[end] ≈ T)) && length(t) <= max_tsteps)
        try
            Δt = maximum_Δt(x_bcs, u, Δx, CFL, 1; gas = gas)
        catch err
            @show length(t), t[end]
            println("Δt calculation failed.")
            break
        end
        if t[end] + Δt > T
            Δt = T - t[end]
        end
        (length(t) % 10 == 0) && @show length(t), t[end], Δt
        step_euler_hll!(u_next, u, Δt, Δx, x_bcs; gas = gas)
        u = u_next
        push!(t, t[end] + Δt)
        write_output && write(u_tape, u)
    end

    if write_output
        out_file = joinpath("data", output_tag * ".out")
        open(out_file; write = true) do f
            write(f, size(u)...)
            write(f, first(xs), last(xs))
            write(f, length(t))
            write(f, t)
            p = position(u_tape)
            seekstart(u_tape)
            # this could be slow. very slow.
            write(f, read(u_tape))
        end
        close(u_tape)
    end
    return (t[end], u_next)
end

##
# SHOCK SCENARIO ONE
# SHOCK AT X = 0
# SUPERSONIC FLOW IMPACTS STATIC ATMOSPHERIC AIR

uL_1 = ConservedState(PrimitiveState(1.225, [2.0], 300.); gas = DRY_AIR)
uR_1 = ConservedState(PrimitiveState(1.225, [0.0], 350.); gas = DRY_AIR)

u1(x) = x < 0 ? uL_1 : uR_1
left_bc_1 = SupersonicInflow(uL_1)
# convert pressure at outflow to Pascals 
# before stripping units (just to be safe)
right_bc_1 = FixedPressureOutflow(ustrip(u"Pa", pressure(uR_1; gas=DRY_AIR)))
bcs_1 = EdgeBoundary(left_bc_1, right_bc_1)

simulate_euler_1d(-100.0, 100.0, 2000, bcs_1, 0.1, u1; gas = DRY_AIR, CFL = 0.75, output_tag="euler_scenario_1")

##
## NOTES FROM FRIDAY
## WTF is wrong with my boundary conditions?
## maybe I should email Herty / Müller...
## Maybe I should also switch to HLL-C to correct the contact wave rather than smearing out the data.
## hmmmm. 
