# I always think in "north south east west"... who knows why.
#   anyway
@enum CellBoundaries::UInt8 begin
    NORTH_BOUNDARY = 1
    SOUTH_BOUNDARY = 2
    EAST_BOUNDARY = 3
    WEST_BOUNDARY = 4
    INTERNAL_STRONGWALL = 5
end

@enum CellNeighboring::UInt8 begin
    OTHER_QUADCELL
    BOUNDARY_CONDITION
    IS_PHANTOM
end

"""
    QuadCell

Abstract data type for all cells in a Cartesian grid.

All QuadCells _must_ provide the following methods:

 - `numeric_dtype(::QuadCell)`
 - `update_dtype(::QuadCell)`
"""
abstract type QuadCell end

"""
    PrimalQuadCell{T} <: QuadCell

QuadCell data type for a primal computation.

Type Parameters
---
 - `T`: Numeric data type.

Fields
---
 - `id`: Which quad cell is this?
 - `idx`: Which grid cell does this data represent?
 - `center`: Where is the center of this quad cell?
 - `extent`: How large is this quad cell?
 - `u`: What are the cell-averaged non-dimensionalized conserved properties in this cell?
 - `neighbors`: What are this cell's neighbors?
"""
struct PrimalQuadCell{T} <: QuadCell # TODO:Make normal cells not save unnecessary data
    id::Int
    idx::CartesianIndex{2}
    center::SVector{2,T}
    extent::SVector{2,T}
    u::SVector{4,T}
    # either (:boundary, :cell)
    # and then the ID of the appropriate boundary
    neighbors::NamedTuple{
        (:north, :south, :east, :west),
        NTuple{4,Tuple{CellNeighboring,Int}},
    }
    contains_boundary::Bool
    intersection_points::NTuple{2,SVector{2,T}} # option of Union with Nothing broke writing
    line_integral_val::T
end

"""
    TangentQuadCell{T, NSEEDS,PARAMCOUNT} <: QuadCell

QuadCell data type for a primal computation. Pushes forward `NSEEDS` seed values through the JVP of the flux function.
`PARAMCOUNT` determines the "length" of the underlying `SMatrix` for `u̇`.

Fields
---
 - `id`: Which quad cell is this?
 - `idx`: Which grid cell does this data represent?
 - `center`: Where is the center of this quad cell?
 - `extent`: How large is this quad cell?
 - `u`: What are the cell-averaged non-dimensionalized conserved properties in this cell?
 - `u̇`: What are the cell-averaged pushforwards in this cell?
 - `neighbors`: What are this cell's neighbors?
"""
struct TangentQuadCell{T,NSEEDS,PARAMCOUNT} <: QuadCell # TODO:Make normal cells not save unnecessary data
    id::Int
    idx::CartesianIndex{2}
    center::SVector{2,T}
    extent::SVector{2,T}
    u::SVector{4,T}
    u̇::SMatrix{4,NSEEDS,T,PARAMCOUNT}
    neighbors::NamedTuple{
        (:north, :south, :east, :west),
        NTuple{4,Tuple{CellNeighboring,Int}},
    }
    contains_boundary::Bool
    intersection_points::NTuple{2,SVector{2,T}} # option of Union with Nothing broke writing
    line_integral_val::T
end

numeric_dtype(::PrimalQuadCell{T}) where {T} = T
numeric_dtype(::Type{PrimalQuadCell{T}}) where {T} = T

numeric_dtype(::TangentQuadCell{T,N,P}) where {T,N,P} = T
numeric_dtype(::Type{TangentQuadCell{T,N,P}}) where {T,N,P} = T
n_seeds(::TangentQuadCell{T,N,P}) where {T,N,P} = N
n_seeds(::Type{TangentQuadCell{T,N,P}}) where {T,N,P} = N

@doc """
        numeric_dtype(cell)
        numeric_dtype(::Type{CELL_TYPE})

    Get the numeric data type associated with this cell.
    """ numeric_dtype

update_dtype(::Type{T}) where {T<:PrimalQuadCell} = Tuple{SVector{4,numeric_dtype(T)}}
function update_dtype(::Type{TangentQuadCell{T,N,P}}) where {T,N,P}
    return Tuple{SVector{4,T},SMatrix{4,N,T,P}}
end

@doc """
    update_dtype(::Type{T<:QuadCell})

Get the tuple of update data types that must be enforced upon fetch-ing results out of the worker tasks.
"""

function inward_normals(T::DataType)
    return (
        north = SVector((zero(T), -one(T))...),
        south = SVector((zero(T), one(T))...),
        east = SVector((-one(T), zero(T))...),
        west = SVector((one(T), zero(T))...),
    )
end

function outward_normals(T::DataType)
    return (
        north = SVector((zero(T), one(T))...),
        south = SVector((zero(T), -one(T))...),
        east = SVector((one(T), zero(T))...),
        west = SVector((-one(T), zero(T))...),
    )
end

inward_normals(cell) = inward_normals(numeric_dtype(cell))
outward_normals(cell) = outward_normals(numeric_dtype(cell))

cell_volume(cell) = *(cell.extent...)

function phantom_neighbor(cell::PrimalQuadCell, dir, bc, gas)
    # HACK use nneighbors as intended.
    @assert dir ∈ (:north, :south, :east, :west) "dir is not a cardinal direction..."
    @assert nneighbors(bc) == 1 "dirty hack alert, this function needs to be extended for bcs with more neighbors"
    phantom = @set cell.id = 0

    @inbounds begin
        reverse_phantom = _dirs_bc_is_reversed[dir] && reverse_right_edge(bc)
        @reset phantom.center = cell.center + outward_normals(cell)[dir] .* cell.extent
        @reset phantom.neighbors =
            NamedTuple{(:north, :south, :east, :west)}(ntuple(Returns((IS_PHANTOM, 0)), 4))

        u = if _dirs_bc_is_reversed[dir]
            flip_velocity(cell.u, _dirs_dim[dir])
        else
            cell.u
        end
        phantom_u = phantom_cell(bc, u, _dirs_dim[dir], gas)
        if reverse_phantom
            @reset phantom.u = flip_velocity(phantom_u, _dirs_dim[dir])
        else
            @reset phantom.u = phantom_u
        end
    end
    return phantom
end

function phantom_neighbor(
    cell::TangentQuadCell{T,NSEEDS,PARAMCOUNT},
    dir,
    bc,
    gas,
) where {T,NSEEDS,PARAMCOUNT}
    # HACK use nneighbors as intended.
    @assert dir ∈ (:north, :south, :east, :west) "dir is not a cardinal direction..."
    @assert nneighbors(bc) == 1 "dirty hack alert, this function needs to be extended for bcs with more neighbors"
    phantom = @set cell.id = 0

    @inbounds begin
        reverse_phantom = _dirs_bc_is_reversed[dir] && reverse_right_edge(bc)
        @reset phantom.center = cell.center + outward_normals(cell)[dir] .* cell.extent
        @reset phantom.neighbors =
            NamedTuple{(:north, :south, :east, :west)}(ntuple(Returns((IS_PHANTOM, 0)), 4))

        # TODO there must be a way to do this with Accessors.jl and "lenses" that makes sense
        # HACK is this utter nonsense????? I do not know.
        dim = _dirs_dim[dir]
        u = _dirs_bc_is_reversed[dir] ? flip_velocity(cell.u, dim) : cell.u
        u̇ = _dirs_bc_is_reversed[dir] ? flip_velocity(cell.u̇, dim) : cell.u̇
        phantom_u = phantom_cell(bc, u, _dirs_dim[dir], gas)
        J_phantom = ForwardDiff.jacobian(u) do u
            phantom_cell(bc, u, _dirs_dim[dir], gas)
        end
        phantom_u̇ = J_phantom * u̇
        if reverse_phantom
            @reset phantom.u = flip_velocity(phantom_u, _dirs_dim[dir])
            @reset phantom.u̇ = flip_velocity(phantom_u̇, _dirs_dim[dir])
        else
            @reset phantom.u = phantom_u
            @reset phantom.u̇ = phantom_u̇
        end
    end
    return phantom
end

"""
    neighbor_cells(cell, active_cells, boundary_conditions, gas)

Extract the states of the neighboring cells to `cell` from `active_cells`.
Will compute phantoms as necessary from `boundary_conditions` and `gas`.
"""
function neighbor_cells(cell, active_cells, boundary_conditions, gas)
    neighbors = cell.neighbors
    map((ntuple(i -> ((keys(neighbors)[i], neighbors[i])), 4))) do (dir, (kind, id))
        res = if kind == BOUNDARY_CONDITION
            @inbounds phantom_neighbor(cell, dir, boundary_conditions[id], gas)
        else
            active_cells[id]
        end
        return res
    end |> NamedTuple{(:north, :south, :east, :west)}
end

function split_axis(len, n)
    l = len ÷ n
    rem = len - (n * l)
    tpl_ranges = [(i * l + 1, (i + 1) * l) for i = 0:(n-1)]
    if rem > 0
        tpl_ranges[end] = (l * (n - 1) + 1, len)
    end
    return tpl_ranges
end

function expand_to_neighbors(left_idx, right_idx, axis_size)
    len = right_idx - left_idx + 1
    if left_idx > 1
        new_l = left_idx - 1
        left_idx = 2
    else
        new_l = 1
        left_idx = 1
    end

    if right_idx < axis_size
        new_r = right_idx + 1
        right_idx = left_idx + len - 1
    else
        new_r = right_idx
        right_idx = left_idx + len - 1
    end
    return (new_l, new_r), (left_idx, right_idx)
end

struct CellGridPartition{T,U}
    id::Int
    # which slice of the global grid was copied into this partition?
    global_extent::NTuple{2,NTuple{2,Int}}
    # which (global) indices is this partition responsible for updating?
    global_computation_indices::NTuple{2,NTuple{2,Int}}
    # which (local) indices is this partition responsible for updating?
    computation_indices::NTuple{2,NTuple{2,Int}}
    # what cell IDs were copied into this partition?
    cells_copied_ids::Array{Int,2}
    #TODO Switch to Dictionaries.jl? Peformance seems fine as of now.
    cells_map::Dict{Int,T}
    cells_update::Dict{Int,U}

    function CellGridPartition(
        id,
        global_extent,
        global_computation_indices,
        computation_indices,
        cells_copied_ids,
        cells_map::Dict{Int,T},
        cells_update::Dict{Int},
    ) where {T<:QuadCell}
        return new{T,update_dtype(T)}(
            id,
            global_extent,
            global_computation_indices,
            computation_indices,
            cells_copied_ids,
            cells_map,
            cells_update,
        )
    end
end

"""
    numeric_dtype(::CellGridPartition)
    numeric_dtype(::Type{CellGridPartition})

Underlying numeric data type of this partition.
"""
numeric_dtype(::CellGridPartition{T,U}) where {T,U} = numeric_dtype(T)
numeric_dtype(::Type{CellGridPartition{T,U}}) where {T,U} = numeric_dtype(T)

cell_type(::CellGridPartition{T,U}) where {T,U} = T
cell_type(::Type{CellGridPartition{T,U}}) where {T,U} = T

"""
    cells_map_type(::CellGridPartition)
    cells_map_type(::Type{CellGridPartition})
"""
cells_map_type(::CellGridPartition{T}) where {T} = Dict{Int,T}
cells_map_type(::Type{CellGridPartition{T}}) where {T} = Dict{Int,T}

function computation_region_indices(p)
    return (range(p.computation_indices[1]...), range(p.computation_indices[2]...))
end

function computation_region(p)
    return @view p.cells_copied_ids[computation_region_indices(p)...]
end

# TODO if we want to move beyond a structured grid, we have to redo this method. I have no idea how to do this.

function partition_cell_list(
    global_active_cells,
    global_cell_ids,
    tasks_per_axis;
    show_info = false,
)
    # minimum partition size includes i - 1 and i + 1 neighbors
    grid_size = size(global_cell_ids)
    all_part = split_axis.(grid_size, tasks_per_axis)

    cell_type = valtype(global_active_cells)
    update_type = update_dtype(cell_type)
    if show_info
        @info "Partitioning global cell grid into $(*(length.(all_part)...)) partitions." cell_type update_type
    end

    res = map(enumerate(Iterators.product(all_part...))) do (id, (part_x, part_y))
        # adust slice width...
        task_x, task_working_x = expand_to_neighbors(part_x..., grid_size[1])
        task_y, task_working_y = expand_to_neighbors(part_y..., grid_size[2])
        if show_info
            @info "Creating cell partition on grid ids..." id = id global_ids =
                (range(task_x...), range(task_y...)) compute_ids =
                (range(task_working_x...), range(task_working_y...))
        end
        # cells copied for this task
        # we want to copy this...?
        task_cell_ids = global_cell_ids[range(task_x...), range(task_y...)]
        # total number of cells this task has a copy of
        task_cell_count = count(>(0), task_cell_ids)
        cell_ids_map = Dict{Int,cell_type}()
        cell_updates_map = Dict{Int,update_type}()
        sizehint!(cell_ids_map, task_cell_count)
        sizehint!(cell_updates_map, task_cell_count)
        for i ∈ eachindex(task_cell_ids)
            cell_id = task_cell_ids[i]
            cell_id == 0 && continue
            cell_ids_map[cell_id] = global_active_cells[cell_id]
            cell_updates_map[cell_id] = zero.(fieldtypes(update_type))
        end
        return CellGridPartition(
            id,
            (task_x, task_y),
            (part_x, part_y),
            (task_working_x, task_working_y),
            task_cell_ids,
            cell_ids_map,
            cell_updates_map,
        )
    end
    @assert _verify_partitioning(res) "Partition is invalid! Oh no"
    return res
end

function _verify_partitioning(p)
    return all(Iterators.filter(Iterators.product(p, p)) do (p1, p2)
        p1.id != p2.id
    end) do (p1, p2)
        c1 = computation_region(p1)
        c2 = computation_region(p2)
        return !any(c1) do v1
            v1 == 0 && return false
            return any(c2) do v2
                v2 == 0 && return false
                v1 == v2
            end
        end
    end
end

function collect_cell_partitions!(global_cells, cell_partitions)
    for part ∈ cell_partitions
        data_region = computation_region(part)
        for id ∈ data_region
            id == 0 && continue
            global_cells[id] = part.cells_map[id]
        end
    end
end

function collect_cell_partitions(cell_partitions, global_cell_ids)
    u_global = empty(cell_partitions[1].cells_map)
    sizehint!(u_global, count(≠(0), global_cell_ids))
    collect_cell_partitions!(u_global, cell_partitions)
    return u_global
end

function _iface_speed(iface::Tuple{Int,T,T}, gas) where {T<:QuadCell}
    return max(abs.(interface_signal_speeds(iface[2].u, iface[3].u, iface[1], gas))...)
end

function maximum_cell_signal_speeds(
    interfaces::NamedTuple{(:north, :south, :east, :west)},
    gas::CaloricallyPerfectGas,
)
    # doing this with map allocated?!
    return SVector(
        max(_iface_speed(interfaces.north, gas), _iface_speed(interfaces.south, gas)),
        max(_iface_speed(interfaces.east, gas), _iface_speed(interfaces.west, gas)),
    )
end

"""
    compute_cell_update_and_max_Δt(cell, active_cells, boundary_conditions, gas)

Computes the update (of type `update_dtype(typeof(cell))`) for a given cell.

Arguments
---
- `cell`
- `active_cells`: The active cell partition or simulation. Usually a `Dict` that maps `id => typeof(cell)`
- `boundary_conditions`: The boundary conditions
- `gas::CaloricallyPerfectGas`: The simulation fluid.

Returns
---
`(update, Δt_max)`: A tuple of the cell update and the maximum time step size allowed by the CFL condition.
"""
function compute_cell_update_and_max_Δt(
    cell::PrimalQuadCell,
    active_cells,
    boundary_conditions,
    gas,
    obstacles,
)
    neighbors = neighbor_cells(cell, active_cells, boundary_conditions, gas)
    ifaces = (
        north = (2, cell, neighbors.north),
        south = (2, neighbors.south, cell),
        east  = (1, cell, neighbors.east),
        west  = (1, neighbors.west, cell),
    )
    a = maximum_cell_signal_speeds(ifaces, gas)
    Δt_max = min((cell.extent ./ a)...)

    ϕ = map(ifaces) do (dim, cell_L, cell_R)
        return ϕ_hll(cell_L.u, cell_R.u, dim, gas)
    end

    Δx = map(ifaces) do (dim, cell_L, cell_R)
        (cell_L.extent[dim] + cell_R.extent[dim]) / 2
    end

    Δu = (
        inv(Δx.west) * ϕ.west - inv(Δx.east) * ϕ.east + inv(Δx.south) * ϕ.south -
        inv(Δx.north) * ϕ.north
    )

    # Define Φ (function added to update rule Δu) in the cell only if intersection points were calculated
    if !cell.contains_boundary
        return (Δt_max, (Δu,))
    else
        Φ = zeros(4)
        pressure = _pressure(cell.u,gas)
        S = cell.line_integral_val
        Φ = [0.0, -pressure * S, -pressure * S, 0.0]
    
        Δu_total = Δu + Φ
        # tuple madness
        return (Δt_max, (Δu_total,))
    end
end

function compute_cell_update_and_max_Δt(
    cell::TangentQuadCell{T,N,P},
    active_cells,
    boundary_conditions,
    gas,
    obstacles,
) where {T,N,P}
    neighbors = neighbor_cells(cell, active_cells, boundary_conditions, gas)
    ifaces = (
        north = (2, cell, neighbors.north),
        south = (2, neighbors.south, cell),
        east  = (1, cell, neighbors.east),
        west  = (1, neighbors.west, cell),
    )
    a = maximum_cell_signal_speeds(ifaces, gas)
    Δt_max = min((cell.extent ./ a)...)

    ϕ = map(ifaces) do (dim, cell_L, cell_R)
        return ϕ_hll(cell_L.u, cell_R.u, dim, gas)
    end
    ϕ_jvp = map(ifaces) do (dim, cell_L, cell_R)
        return ϕ_hll_jvp(cell_L.u, cell_L.u̇, cell_R.u, cell_R.u̇, dim, gas)
    end

    Δx = map(ifaces) do (dim, cell_L, cell_R)
        (cell_L.extent[dim] + cell_R.extent[dim]) / 2
    end

    # Interface flux accumulation
    Δu_primal = (
        inv(Δx.west) * ϕ.west -
        inv(Δx.east) * ϕ.east +
        inv(Δx.south) * ϕ.south -
        inv(Δx.north) * ϕ.north
    )
    Δu_tangent = (
        inv(Δx.west) * ϕ_jvp.west -
        inv(Δx.east) * ϕ_jvp.east +
        inv(Δx.south) * ϕ_jvp.south -
        inv(Δx.north) * ϕ_jvp.north
    )

    if !cell.contains_boundary
        Δu = (Δu_primal, Δu_tangent)
        return (Δt_max, Δu)
    else
        obstacle = obstacles[1] # TODO: only for one
        a, b = cell.intersection_points
        nseeds = n_seeds(cell)

        function boundary_flux(u, r)
            pressure = _pressure(u, gas)
            obstacle_new = CircularObstacle(obstacle.center, r)
            S = calculate_line_integral(obstacle_new, a[1], b[1], cell.center)
            return @SVector [0.0, -pressure * S, -pressure * S, 0.0]
        end

        function combined_flux(x)
            u_part = SVector(x[1], x[2], x[3], x[4])
            r_part = x[5]
            return boundary_flux(u_part, r_part)
        end
        
        arg = SVector{5}(cell.u..., obstacle.radius)
        J_combined = ForwardDiff.jacobian(combined_flux, arg)
        combined_tangent = vcat(cell.u̇, SMatrix{1, nseeds}(ones(nseeds)...))
        Φ = boundary_flux(cell.u, obstacle.radius)
        Φ_jvp = J_combined * combined_tangent

        Δu_primal_total  = Δu_primal  + Φ
        Δu_tangent_total = Δu_tangent + Φ_jvp

        Δu = (Δu_primal_total, Δu_tangent_total)
        return (Δt_max, Δu)
    end
end

# no longer allocates since we pre-allocate the update dict in the struct itself!
function compute_partition_update_and_max_Δt!(
    cell_partition::CellGridPartition{T},
    boundary_conditions,
    gas::CaloricallyPerfectGas,
    obstacles::Vector{<:Obstacle},
) where {T}
    computation_region = view(
        cell_partition.cells_copied_ids,
        range(cell_partition.computation_indices[1]...),
        range(cell_partition.computation_indices[2]...),
    )
    Δt_max = typemax(numeric_dtype(T))
    for cell_id ∈ computation_region
        cell_id == 0 && continue
        cell_Δt_max, cell_Δu = compute_cell_update_and_max_Δt(
            cell_partition.cells_map[cell_id],
            cell_partition.cells_map,
            boundary_conditions,
            gas,
            obstacles,
        )
        Δt_max = min(Δt_max, cell_Δt_max)
        cell_partition.cells_update[cell_id] = cell_Δu
    end

    return Δt_max
end

"""
    propagate_updates_to!(dest, src, global_cell_ids)

After computing the cell updates for the regions
that a partition is responsible for, propagate the updates
to other partitions.

Returns the number of cells updated.
"""
function propagate_updates_to!(
    dest::CellGridPartition{T},
    src::CellGridPartition{T},
) where {T}
    count = 0
    src_compute = computation_region(src)
    for src_id ∈ src_compute
        src_id == 0 && continue
        for dest_id ∈ dest.cells_copied_ids
            if src_id == dest_id
                dest.cells_update[src_id] = src.cells_update[src_id]
                count += 1
            end
        end
    end
    return count
end

# zeroing out the update is not technically necessary, but it's also very cheap
# ( I hope )
function apply_partition_update!(
    partition::CellGridPartition{T,U},
    Δt,
) where {T<:PrimalQuadCell,U}
    for (k, v) ∈ partition.cells_update
        cell = partition.cells_map[k]
        @reset cell.u = cell.u + Δt * v[1]
        partition.cells_map[k] = cell
        partition.cells_update[k] = zero.(fieldtypes(U))
    end
end

function apply_partition_update!(
    partition::CellGridPartition{T,U},
    Δt,
) where {T<:TangentQuadCell,U}
    for (k, v) ∈ partition.cells_update
        cell = partition.cells_map[k]
        @reset cell.u = cell.u + Δt * v[1]
        @reset cell.u̇ = cell.u̇ + Δt * v[2]
        partition.cells_map[k] = cell
        partition.cells_update[k] = zero.(fieldtypes(U))
    end
end

function step_cell_simulation!(
    cell_partitions,
    Δt_maximum,
    boundary_conditions,
    cfl_limit,
    gas::CaloricallyPerfectGas,
    obstacles::Vector{<:Obstacle},
)
    T = numeric_dtype(eltype(cell_partitions))
    # compute Δu from flux functions
    compute_partition_update_tasks = map(cell_partitions) do cell_partition
        Threads.@spawn begin
            # not sure what to interpolate here
            compute_partition_update_and_max_Δt!(cell_partition, $boundary_conditions, $gas, obstacles)
        end
    end
    partition_max_Δts::Array{T,length(size(compute_partition_update_tasks))} =
        fetch.(compute_partition_update_tasks)
    # find Δt
    Δt = mapreduce(min, partition_max_Δts; init = Δt_maximum) do val
        cfl_limit * val
    end

    propagate_tasks = map(
        Iterators.filter(Iterators.product(cell_partitions, cell_partitions)) do (p1, p2)
            p1.id != p2.id
        end,
    ) do (p1, p2)
        Threads.@spawn begin
            propagate_updates_to!(p1, p2)
            #@info "Sent data between partitions..." src_id = p2.id dest_id = p1.id count
        end
    end
    wait.(propagate_tasks)

    update_tasks = map(cell_partitions) do p
        Threads.@spawn begin
            apply_partition_update!(p, Δt)
        end
    end
    wait.(update_tasks)

    return Δt
end

# TODO we should actually be more serious about compting these overlaps
#  and then computing volume-averaged quantities
point_inside(s::Obstacle, q) = point_inside(s, q.center)

function vertices(cell_center::SVector, dx, dy)
    return (
        e = cell_center + 0.5 * @SVector([dx, 0]),
        se = cell_center + 0.5 * @SVector([dx, -dy]),
        s = cell_center + 0.5 * @SVector([0, -dy]),
        sw = cell_center + 0.5 * @SVector([-dx, -dy]),
        w = cell_center + 0.5 * @SVector([-dx, 0]),
        nw = cell_center + 0.5 * @SVector([-dx, dy]),
        n = cell_center + 0.5 * @SVector([0, dy]),
        ne = cell_center + 0.5 * @SVector([dx, dy]),
    )
end

function get_intersection_points(
    obstacles,
    cell_center::SVector,
    extent::SVector,
    neighbors::NamedTuple,
)::NTuple{2,SVector{2}}
    vert = vertices(cell_center, extent...)
    intersectionPoints = Vector[]
    for o ∈ obstacles
        id = return_cell_type_id(o, cell_center, extent)
        id == -1 || continue
        for dir in keys(neighbors)
            if neighbors[dir][2] < 0 ||
               (neighbors[dir][1] == Euler2D.BOUNDARY_CONDITION && neighbors[dir][2] != 5)
                push!(intersectionPoints, intersection_point(o, vert, dir))
            end
        end
    end
    return (intersectionPoints[1], intersectionPoints[2])
end

function intersection_point(immersed_boundary::Obstacle, vertices::NamedTuple, dir::Symbol)
    if dir == :north
        vtx_left = vertices.nw
        vtx_right = vertices.ne
        @assert vtx_left[2] == vtx_right[2]
        x = find_intersection(immersed_boundary, vtx_left[2], vtx_left[1], vtx_right[1], 1)
        return SVector(x, vtx_left[2])
    elseif dir == :south
        vtx_left = vertices.sw
        vtx_right = vertices.se
        @assert vtx_left[2] == vtx_right[2]
        x = find_intersection(immersed_boundary, vtx_left[2], vtx_left[1], vtx_right[1], 1)
        return SVector(x, vtx_left[2])
    elseif dir == :west
        vtx_bottom = vertices.sw
        vtx_top = vertices.nw
        @assert vtx_bottom[1] == vtx_top[1]
        y = find_intersection(immersed_boundary, vtx_bottom[1], vtx_bottom[2], vtx_top[2], 2)
        return SVector(vtx_bottom[1], y)
    else
        vtx_bottom = vertices.se
        vtx_top = vertices.ne
        @assert vtx_bottom[1] == vtx_top[1]
        y = find_intersection(immersed_boundary, vtx_bottom[1], vtx_bottom[2], vtx_top[2], 2)
        return SVector(vtx_bottom[1], y)
    end
end

"function find_intersection(circ::ParametricObstacle, coord, min, max, idx) #FIX: It is only working for circular parametric obstacle.
    c1 = min - circ.center[idx]
    c2 = max - circ.center[idx]
    coordTick = coord - circ.center[3-idx]
    intPoint = sqrt(circ.parameters.r^2 - coordTick^2)
    if c1 < intPoint < c2
        return intPoint + circ.center[idx]
    else
        return -intPoint + circ.center[idx]
    end
end"

function find_intersection(obstacle::ParametricObstacle, coord, min, max, idx) #FIX: Not working for polynomial
    params = obstacle.parameters
    center = obstacle.center
    shape_type = obstacle.shape_type
    c1 = min - center[idx]
    c2 = max - center[idx]
    coordTick = coord - center[3-idx]

    if shape_type == :circle
        r = params.r
    elseif shape_type == :ellipse || shape_type == :hyperbola
        a = params.a
        b = params.b
        h = params.h
        k = params.k
        if idx == 1
            t_idx = shape_type == :ellipse ? asin((coord - k) / b) - π : atan((coord - k) / b) - π
        elseif idx == 2
            t_idx = shape_type == :ellipse ? acos((coord - h) / a) - π : asec((coord - h) / a) - π
        end

        if shape_type == :ellipse
            r = sqrt((a * cos(t_idx))^2 + (b * sin(t_idx))^2)
        else # :hyperbola
            r = sqrt((a * sec(t_idx))^2 + (b * tan(t_idx))^2)
        end
    else
        throw(ArgumentError("Unsupported shape type: $shape_type"))
    end
    intPoint = sqrt(r^2 - coordTick^2)
    if c1 < intPoint < c2
        return intPoint + center[idx]
    else
        return -intPoint + center[idx]
    end
end

function find_intersection(circ::CircularObstacle, coord, min, max, idx)
    c1 = min - circ.center[idx]
    c2 = max - circ.center[idx]
    coordTick = coord - circ.center[3-idx]
    intPoint = sqrt(circ.radius^2 - coordTick^2)
    if c1 < intPoint < c2
        return intPoint + circ.center[idx]
    else
        return -intPoint + circ.center[idx]
    end
end


function atan2(y, x, shape_type)
    
    if (shape_type == :hyperbola)
        return -π + atan(y)
    elseif x > 0
        return atan(y / x)
    elseif x < 0 && y >= 0
        return atan(y / x) + π
    elseif x < 0 && y < 0
        return atan(y / x) - π
    elseif x == 0 && y > 0
        return π / 2
    elseif x == 0 && y < 0
        return -π / 2
    else
        throw(ArgumentError("Undefined atan2 for (y, x) = ($y, $x)"))
    end

end

function from_cartesian_to_polar(a::SVector{2, Float64}, b::SVector{2, Float64}, shape, params)
    ax, bx = min(a[1],b[1]), max(a[1], b[1])
    ay, by = min(a[2],b[2]), max(a[2], b[2])
    if (shape == :circle)
        h, k, r = params.h, params.k, params.r
        t_a = atan2(ay - k, ax - h, shape)
        t_b = atan2(by - k, bx - h, shape)
    elseif (shape == :ellipse)
        h, k, a, b = params.h, params.k, params.a, params.b
        t_a = atan2((ay - k) / b, (ax - h) / a, shape)
        t_b = atan2((by - k) / b, (bx - h) / a, shape)
    elseif (shape == :hyperbola)
        h, k, a, b = params.h, params.k, params.a, params.b
        tan_t_a = (ay - k) / b
        tan_t_b = (by - k) / b
        t_a = atan2((tan_t_a) , 0, shape)
        t_b = atan2((tan_t_b) , 0, shape)
    elseif (shape == :polynomial)
        t_a, t_b = ax, bx
    else 
        throw(ArgumentError("Unsupported shape type: $shape"))
    end
    t_c = t_b + (t_a - t_b) / 2

    return t_a, t_b, t_c, ax, bx, ay, by
end

function calculate_normal_vector(spline::ParametricObstacle, a::SVector{2, Float64}, b::SVector{2, Float64}, bound::Float64)

    # Extract calculation parameters
    x_fun, y_fun, params, shape = spline.x_func, spline.y_func, spline.parameters, spline.shape_type
    _, _, t_c, ax, bx, ay, by = from_cartesian_to_polar(a,b,shape,params)

    # Calculate derivatives for normal vector calculation
    x_wrapped = t -> x_fun(t, params)
    y_wrapped = t -> y_fun(t, params)
    dx_dt = ForwardDiff.derivative(x_wrapped, t_c)
    dy_dt = ForwardDiff.derivative(y_wrapped, t_c)

    # Determine and normalize normal vector
    tangent = SVector{2, Float64}(dx_dt, dy_dt)
    n = SVector(-tangent[2], tangent[1])
    n_norm = normalize(n)

    # Check direction of n_norm
    P_curve = SVector(x_fun(t_c, params), y_fun(t_c,params))
    P_test = P_curve + SVector(bound, 0.0)
    if dot(n_norm, P_test - P_curve)<0
        n_norm = -n_norm
    end

    return n_norm  # Return the unit normal vector
end

function calculate_normal_vector(circ::CircularObstacle, a, b, cell_center::SVector)
    center = circ.center
    xa, xb = min(a, b), max(a, b)
    x_point = xa + (xb - xa) / 2
    if (cell_center[2] - center[2] < 0)
        y_point = center[2] - sqrt(circ.radius^2 - (x_point - center[1])^2)
    elseif (cell_center[2] - center[2] >= 0 && a != b)
        y_point = center[2] + sqrt(circ.radius^2 - (x_point - center[1])^2)
    elseif (xa == xb)
        y_point = center[2]
    end
    point = SVector(x_point, y_point)
    n = point - center
    return normalize(n)
end

function calculate_line_integral(spline::ParametricObstacle, a::SVector{2, Float64}, b::SVector{2, Float64}, bound::Float64)

    # Extract calculation parameters
    x_fun, y_fun, params, shape = spline.x_func, spline.y_func, spline.parameters, spline.shape_type
    t_a, t_b, t_c, ax, bx, ay, by = from_cartesian_to_polar(a,b,shape,params)
    n = calculate_normal_vector(spline,a,b,bound)
    
    # Calculate value of line integral
    if (shape== :polynomial)
        integral = n[1] * (x_fun(bx, params) - x_fun(ax, params)) + n[2] * (y_fun(bx, params) - y_fun(ax, params))
    else
        integral = n[1] * (x_fun(t_b, params) - x_fun(t_a, params)) + n[2] * (y_fun(t_b, params) - y_fun(t_a, params))
    end

    return integral
end

function calculate_line_integral(obstacle::CircularObstacle, a, b, cell_center::SVector)
    center, radius = obstacle.center, obstacle.radius
    z_x, z_y = center[1], center[2]
    xa, xb = max(a, z_x - radius), min(b, z_x + radius)
    y_a = sqrt(radius^2 - (xa - z_x)^2)
    y_b = sqrt(radius^2 - (xb - z_x)^2)

    n = calculate_normal_vector(obstacle, xa, xb, cell_center)

    if (cell_center[2] - z_y < 0) # Calculation bellow x-axis
        integral = n[1] * (xb - xa) + n[2] * (y_b - y_a)
    elseif (cell_center[2] - z_y > 0) # # Calculation above x-axis
        integral = n[1] * (xb - xa) - n[2] * (y_b - y_a)
    else # Case when xa = xb
        n_a = calculate_normal_vector(obstacle, a, radius, cell_center)
        y_r = sqrt(radius^2 - (radius - z_x)^2)
        integral = 2 * (n_a[1] * (radius - xb) - n_a[2] * (y_r - y_b))
        if (xb < 0)
            integral = -integral
        end
    end
    return integral
end

function return_cell_type_id(obs::Obstacle, cell_center::SVector, extent::SVector)
    vert = vertices(cell_center, extent...)
    if any(v -> point_inside(obs, v), vert)
        if any(v -> !point_inside(obs, v), vert)
            return -1
        end
        return 0
    end
    return 1
end

function active_cell_mask(cell_centers, extent, obstacles)
    return map(Iterators.product(cell_centers...)) do (x, y)
        cell_center = SVector{2}(x, y)
        contains_boundary = false
        for o ∈ obstacles
            id = return_cell_type_id(o, cell_center, extent)
            if id == 0
                return 0
            elseif id == -1
                contains_boundary = true
            end
        end
        return contains_boundary ? -1 : 1
    end
end

function active_cell_ids_from_mask(active_mask)::Array{Int,2}
    cell_ids = zeros(Int, size(active_mask))
    live_count = 0
    boundary_count = 0
    for i ∈ eachindex(IndexLinear(), active_mask, cell_ids)
        if active_mask[i] == 1
            live_count += active_mask[i]
            cell_ids[i] = live_count
        elseif active_mask[i] == -1
            boundary_count += active_mask[i]
            cell_ids[i] = boundary_count
        end
    end
    return cell_ids
end

function cell_neighbor_status(i, cell_ids)
    idx = CartesianIndices(cell_ids)[i]
    _cell_neighbor_offsets = (
        north = CartesianIndex(0, 1),
        south = CartesianIndex(0, -1),
        east = CartesianIndex(1, 0),
        west = CartesianIndex(-1, 0),
    )
    map(_cell_neighbor_offsets) do offset
        neighbor = idx + offset
        if neighbor[1] < 1
            return (BOUNDARY_CONDITION, Int(WEST_BOUNDARY))
        elseif neighbor[1] > size(cell_ids)[1]
            return (BOUNDARY_CONDITION, Int(EAST_BOUNDARY))
        elseif neighbor[2] < 1
            return (BOUNDARY_CONDITION, Int(SOUTH_BOUNDARY))
        elseif neighbor[2] > size(cell_ids)[2]
            return (BOUNDARY_CONDITION, Int(NORTH_BOUNDARY))
        elseif cell_ids[neighbor] == 0
            return (BOUNDARY_CONDITION, Int(INTERNAL_STRONGWALL))
        else
            return (OTHER_QUADCELL, cell_ids[neighbor])
        end
    end
end

"""
    primal_quadcell_list_and_id_grid(u0, bounds, ncells, obstacles)

Computes a collection of active cells and their locations in a grid determined by `bounds` and `ncells`.
`Obstacles` can be placed into the simulation grid.
"""
function primal_quadcell_list_and_id_grid(u0, params, bounds, ncells, scaling, obstacles)
    centers = map(zip(bounds, ncells)) do (b, n)
        v = range(b...; length = n + 1)
        return v[1:end-1] .+ step(v) / 2
    end
    extent = SVector{2}(step.(centers)...)
    pts = Iterators.product(centers...)

    # u0 is probably cheap, right?
    _u0_func(x) = nondimensionalize(u0(x, params), scaling)
    u0_type = typeof(_u0_func(first(pts)))
    T = eltype(u0_type)
    @show T

    u0_grid = map(_u0_func, pts)
    active_mask = active_cell_mask(centers, extent, obstacles)
    active_ids = active_cell_ids_from_mask(active_mask)
    @assert sum(active_mask[active_mask.>0]) == last(active_ids[active_ids.>0])
    @assert sum(active_mask[active_mask.<0]) == last(active_ids[active_ids.<0])
    cell_list = Dict{Int,PrimalQuadCell{eltype(eltype(u0_grid))}}()
    sizehint!(cell_list, sum(active_mask))
    for i ∈ eachindex(IndexCartesian(), active_ids, active_mask)
        active_mask[i] != 0 || continue
        cell_id = active_ids[i]
        (m, n) = Tuple(i)
        x_i = centers[1][m]
        y_j = centers[2][n]
        cell_center = SVector(x_i, y_j)
        neighbors = cell_neighbor_status(i, active_ids)
        if active_mask[i] == 1
            cell_list[cell_id] = PrimalQuadCell(
                cell_id,
                i,
                cell_center,
                extent,
                u0_grid[i],
                neighbors,
                false,
                (SVector(0.0, 0.0), SVector(0.0, 0.0)), # HACK:Because writing broke
                0.0,
            )
            continue
        end
        a, b = get_intersection_points(obstacles, cell_center, extent, neighbors)
        if isa(obstacles[1], CircularObstacle)
            line_integral_value = calculate_line_integral(obstacles[1], a[1], b[1], cell_center)
        elseif isa(obstacles[1], ParametricObstacle)
            line_integral_value = calculate_line_integral(obstacles[1],a,b,bounds[1][1])
        else
            println("Unsupported obstacle type.")
        end
        cell_list[cell_id] = PrimalQuadCell(
            cell_id,
            i,
            cell_center,
            extent,
            u0_grid[i],
            neighbors,
            true,
            (a, b), # FIX:Only works for 1 Cirular Obstacle
            line_integral_value,
        )
    end
    return cell_list, active_ids
end

"""
    tangent_quadcell_list_and_id_grid(u0, bounds, ncells, obstacles)

Computes a collection of active cells and their locations in a grid determined by `bounds` and `ncells`.
`Obstacles` can be placed into the simulation grid.
"""
function tangent_quadcell_list_and_id_grid(u0, params, bounds, ncells, scaling, obstacles)
    centers = map(zip(bounds, ncells)) do (b, n)
        v = range(b...; length = n + 1)
        return v[1:end-1] .+ step(v) / 2
    end
    pts = Iterators.product(centers...)
    extent = SVector{2}(step.(centers)...)

    # u0 is probably cheap, right?
    _u0_func(x) = nondimensionalize(u0(x, params), scaling)
    _u̇0_func(x) = begin
        J = ForwardDiff.jacobian(params) do p
            nondimensionalize(u0(x, p), scaling)
        end
        return J * I
    end

    u0_type = typeof(_u0_func(first(pts)))
    T = eltype(u0_type)
    u̇0_type = typeof(_u̇0_func(first(pts)))

    NSEEDS = ncols_smatrix(u̇0_type)
    @show T, NSEEDS

    u0_grid = map(_u0_func, pts)
    u̇0_grid = map(_u̇0_func, pts)
    active_mask = active_cell_mask(centers, extent, obstacles)
    active_ids = active_cell_ids_from_mask(active_mask)
    @assert sum(active_mask[active_mask.>0]) == last(active_ids[active_ids.>0])
    @assert sum(active_mask[active_mask.<0]) == last(active_ids[active_ids.<0])

    cell_list = Dict{Int,TangentQuadCell{T,NSEEDS,4 * NSEEDS}}()
    sizehint!(cell_list, sum(active_mask))
    for i ∈ eachindex(IndexCartesian(), active_ids, active_mask)
        active_mask[i] != 0 || continue
        cell_id = active_ids[i]
        (m, n) = Tuple(i)
        x_i = centers[1][m]
        y_j = centers[2][n]
        cell_center = SVector(x_i, y_j)
        neighbors = cell_neighbor_status(i, active_ids)
        if active_mask[i] == 1
            cell_list[cell_id] = TangentQuadCell(
                cell_id,
                i,
                cell_center,
                extent,
                u0_grid[i],
                u̇0_grid[i],
                neighbors,
                false,
                (SVector(0.0, 0.0), SVector(0.0, 0.0)), # HACK:Because writing broke
                0.0,
            )
            continue
        end
        a, b = get_intersection_points(obstacles, cell_center, extent, neighbors)
        if isa(obstacles[1], CircularObstacle)
            line_integral_value = calculate_line_integral(obstacles[1], a[1], b[1], cell_center)
        elseif isa(obstacles[1], ParametricObstacle)
            line_integral_value = calculate_line_integral(obstacles[1],a,b,bounds[1][1])
        else
            println("Unsupported obstacle type.")
        end
        cell_list[cell_id] = TangentQuadCell(
            cell_id,
            i,
            cell_center,
            extent,
            u0_grid[i],
            u̇0_grid[i],
            neighbors,
            true,
            (a, b), # FIX:Only works for 1 Cirular Obstacle
            line_integral_value,
        )
    end
    return cell_list, active_ids
end
