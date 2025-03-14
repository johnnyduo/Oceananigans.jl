#####
##### Navier-Stokes and tracer advection equations
#####

""" Store previous value of the source term and calculate current source term. """
function calculate_interior_tendency_contributions!(G, arch, grid, advection, coriolis, buoyancy, surface_waves, closure, 
                                                    U, C, pHY′, K, F, clock)

    workgroup, worksize = work_layout(grid, :xyz)

    calculate_Gu_kernel! = calculate_Gu!(device(arch), workgroup, worksize)
    calculate_Gv_kernel! = calculate_Gv!(device(arch), workgroup, worksize)
    calculate_Gw_kernel! = calculate_Gw!(device(arch), workgroup, worksize)
    calculate_Gc_kernel! = calculate_Gc!(device(arch), workgroup, worksize)

    barrier = Event(device(arch))

    Gu_event = calculate_Gu_kernel!(G.u, grid, advection, coriolis, surface_waves, closure,
                                    U, C, K, F, pHY′, clock, dependencies=barrier)

    Gv_event = calculate_Gv_kernel!(G.v, grid, advection, coriolis, surface_waves, closure,
                                    U, C, K, F, pHY′, clock, dependencies=barrier)

    Gw_event = calculate_Gw_kernel!(G.w, grid, advection, coriolis, surface_waves, closure,
                                    U, C, K, F, clock, dependencies=barrier)

    events = [Gu_event, Gv_event, Gw_event]

    for tracer_index in 1:length(C)
        @inbounds Gc = G[tracer_index+3]
        @inbounds Fc = F[tracer_index+3]
        @inbounds  c = C[tracer_index]

        Gc_event = calculate_Gc_kernel!(Gc, grid, c, Val(tracer_index), advection, closure,
                                        buoyancy, U, C, K, Fc, clock, dependencies=barrier)

        push!(events, Gc_event)
    end

    wait(device(arch), MultiEvent(Tuple(events)))

    return nothing
end

#####
##### Tendency calculators for u, v, w-velocity
#####

""" Calculate the right-hand-side of the u-velocity equation. """
@kernel function calculate_Gu!(Gu, grid, advection, coriolis, surface_waves, closure, U, C, K, F, pHY′, clock)
    i, j, k = @index(Global, NTuple)

    @inbounds Gu[i, j, k] = u_velocity_tendency(i, j, k, grid, advection, coriolis, surface_waves, 
                                                closure, U, C, K, F, pHY′, clock)
end

""" Calculate the right-hand-side of the v-velocity equation. """
@kernel function calculate_Gv!(Gv, grid, advection, coriolis, surface_waves, closure, U, C, K, F, pHY′, clock)
    i, j, k = @index(Global, NTuple)

    @inbounds Gv[i, j, k] = v_velocity_tendency(i, j, k, grid, advection, coriolis, surface_waves, 
                                                closure, U, C, K, F, pHY′, clock)
end

""" Calculate the right-hand-side of the w-velocity equation. """
@kernel function calculate_Gw!(Gw, grid, advection, coriolis, surface_waves, closure, U, C, K, F, clock)
    i, j, k = @index(Global, NTuple)

    @inbounds Gw[i, j, k] = w_velocity_tendency(i, j, k, grid, advection, coriolis, surface_waves, 
                                                closure, U, C, K, F, clock)
end

#####
##### Tracer(s)
#####

""" Calculate the right-hand-side of the tracer advection-diffusion equation. """
@kernel function calculate_Gc!(Gc, grid, c, tracer_index, advection, closure, buoyancy, U, C, K, Fc, clock)
    i, j, k = @index(Global, NTuple)

    @inbounds Gc[i, j, k] = tracer_tendency(i, j, k, grid, c, tracer_index,
                                            advection, closure, buoyancy, U, C, K, Fc, clock)
end

#####
##### Boundary contributions to tendencies due to user-prescribed fluxes
#####

""" Apply boundary conditions by adding flux divergences to the right-hand-side. """
function calculate_boundary_tendency_contributions!(Gⁿ, arch, U, C, clock, state)

    barrier = Event(device(arch))

    events = []

    # Velocity fields
    for i in 1:3
        x_bcs_event = apply_x_bcs!(Gⁿ[i], U[i], arch, barrier, clock, state)
        y_bcs_event = apply_y_bcs!(Gⁿ[i], U[i], arch, barrier, clock, state)
        z_bcs_event = apply_z_bcs!(Gⁿ[i], U[i], arch, barrier, clock, state)

        push!(events, x_bcs_event, y_bcs_event, z_bcs_event)
    end

    # Tracer fields
    for i in 4:length(Gⁿ)
        x_bcs_event = apply_x_bcs!(Gⁿ[i], C[i-3], arch, barrier, clock, state)
        y_bcs_event = apply_y_bcs!(Gⁿ[i], C[i-3], arch, barrier, clock, state)
        z_bcs_event = apply_z_bcs!(Gⁿ[i], C[i-3], arch, barrier, clock, state)

        push!(events, x_bcs_event, y_bcs_event, z_bcs_event)
    end

    events = filter(e -> typeof(e) <: Event, events)

    wait(device(arch), MultiEvent(Tuple(events)))

    return nothing
end

#####
##### Vertical integrals
#####

"""
Update the hydrostatic pressure perturbation pHY′. This is done by integrating
the `buoyancy_perturbation` downwards:

    `pHY′ = ∫ buoyancy_perturbation dz` from `z=0` down to `z=-Lz`
"""
@kernel function update_hydrostatic_pressure!(pHY′, grid, buoyancy, C)
    i, j = @index(Global, NTuple)

    @inbounds pHY′[i, j, grid.Nz] = - ℑzᵃᵃᶠ(i, j, grid.Nz+1, grid, buoyancy_perturbation, buoyancy, C) * ΔzF(i, j, grid.Nz+1, grid)

    @unroll for k in grid.Nz-1 : -1 : 1
        @inbounds pHY′[i, j, k] =
            pHY′[i, j, k+1] - ℑzᵃᵃᶠ(i, j, k+1, grid, buoyancy_perturbation, buoyancy, C) * ΔzF(i, j, k+1, grid)
    end
end

#####
##### Source term storage
#####

""" Store source terms for `u`, `v`, and `w`. """
@kernel function store_velocity_tendencies!(G⁻, grid::AbstractGrid{FT}, G⁰) where FT
    i, j, k = @index(Global, NTuple)
    @inbounds G⁻.u[i, j, k] = G⁰.u[i, j, k]
    @inbounds G⁻.v[i, j, k] = G⁰.v[i, j, k]
    @inbounds G⁻.w[i, j, k] = G⁰.w[i, j, k]
end

""" Store previous source terms for a tracer before updating them. """
@kernel function store_tracer_tendency!(Gc⁻, grid::AbstractGrid{FT}, Gc⁰) where FT
    i, j, k = @index(Global, NTuple)
    @inbounds Gc⁻[i, j, k] = Gc⁰[i, j, k]
end

""" Store previous source terms before updating them. """
function store_tendencies!(G⁻, arch, grid, G⁰)

    barrier = Event(device(arch))

    workgroup, worksize = work_layout(grid, :xyz)

    store_velocity_tendencies_kernel! = store_velocity_tendencies!(device(arch), workgroup, worksize)
    store_tracer_tendency_kernel! = store_tracer_tendency!(device(arch), workgroup, worksize)

    velocities_event = store_velocity_tendencies_kernel!(G⁻, grid, G⁰, dependencies=barrier)

    events = [velocities_event]

    # Tracer fields
    for i in 4:length(G⁻)
        @inbounds Gc⁻ = G⁻[i]
        @inbounds Gc⁰ = G⁰[i]
        tracer_event = store_tracer_tendency_kernel!(Gc⁻, grid, Gc⁰, dependencies=barrier)
        push!(events, tracer_event)
    end

    wait(device(arch), MultiEvent(Tuple(events)))

    return nothing
end
