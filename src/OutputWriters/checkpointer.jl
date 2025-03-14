"""
    Checkpointer{I, T, P} <: AbstractOutputWriter

An output writer for checkpointing models to a JLD2 file from which models can be restored.
"""
mutable struct Checkpointer{I, T, P} <: AbstractOutputWriter
    iteration_interval :: I
         time_interval :: T
              previous :: Float64
                   dir :: String
                prefix :: String
            properties :: P
                 force :: Bool
               verbose :: Bool
end

"""
    Checkpointer(model; iteration_interval=nothing, time_interval=nothing, dir=".",
                 prefix="checkpoint", force=false, verbose=false,
                 properties = [:architecture, :boundary_conditions, :grid, :clock, :coriolis,
                               :buoyancy, :closure, :velocities, :tracers, :timestepper])

Construct a `Checkpointer` that checkpoints the model to a JLD2 file every so often as
specified by `iteration_interval` or `time_interval`. The `model.clock.iteration` is included
in the filename to distinguish between multiple checkpoint files.

Note that extra model `properties` can be safely specified, but removing crucial properties
such as `:velocities` will make restoring from the checkpoint impossible.

The checkpoint file is generated by serializing model properties to JLD2. However,
functions cannot be serialized to disk (at least not with JLD2). So if a model property
contains a reference somewhere in its hierarchy it will not be included in the checkpoint
file (and you will have to manually restore them).

Keyword arguments
=================
- `iteration_interval`: Save output every `n` model iterations.
- `time_interval`: Save output every `t` units of model clock time.
- `dir`: Directory to save output to. Default: "." (current working directory).
- `prefix`: Descriptive filename prefixed to all output files. Default: "checkpoint".
- `force`: Remove existing files if their filenames conflict. Default: `false`.
- `verbose`: Log what the output writer is doing with statistics on compute/write times
  and file sizes. Default: `false`.
- `properties`: List of model properties to checkpoint. Some are required.
"""
function Checkpointer(model; iteration_interval=nothing, time_interval=nothing,
                      dir=".", prefix="checkpoint", force=false, verbose=false,
                      properties = [:architecture, :grid, :clock, :coriolis,
                                    :buoyancy, :closure, :velocities, :tracers, :timestepper])

    validate_intervals(iteration_interval, time_interval)

    # Certain properties are required for `restore_from_checkpoint` to work.
    required_properties = (:grid, :architecture, :velocities, :tracers, :timestepper)
    for rp in required_properties
        if rp ∉ properties
            @warn "$rp is required for checkpointing. It will be added to checkpointed properties"
            push!(properties, rp)
        end
    end

    for p in properties
        p isa Symbol || error("Property $p to be checkpointed must be a Symbol.")
        p ∉ propertynames(model) && error("Cannot checkpoint $p, it is not a model property!")

        if has_reference(Function, getproperty(model, p)) && (p ∉ required_properties)
            @warn "model.$p contains a function somewhere in its hierarchy and will not be checkpointed."
            filter!(e -> e != p, properties)
        end
    end

    mkpath(dir)
    return Checkpointer(iteration_interval, time_interval, 0.0, dir, prefix, properties, force, verbose)
end

function write_output(model, c::Checkpointer)
    filepath = joinpath(c.dir, c.prefix * "_iteration" * string(model.clock.iteration) * ".jld2")
    c.verbose && @info "Checkpointing to file $filepath..."

    t1 = time_ns()
    jldopen(filepath, "w") do file
        file["checkpointed_properties"] = c.properties
        serializeproperties!(file, model, c.properties)
    end

    t2, sz = time_ns(), filesize(filepath)
    c.verbose && @info "Checkpointing done: time=$(prettytime((t2-t1)/1e9)), size=$(pretty_filesize(sz))"
end

# This is the default name used in the simulation.output_writers ordered dict.
defaultname(::Checkpointer, nelems) = :checkpointer

function restore_if_not_missing(file, address)
    if !ismissing(file[address])
        return file[address]
    else
        @warn "Checkpoint file does not contain $address. Returning missing. " *
              "You might need to restore $address manually."
        return missing
    end
end

function restore_field(file, address, arch, grid, loc, kwargs)
    field_address = file[address * "/location"]
    data = OffsetArray(convert_to_arch(arch, file[address * "/data"]), grid, loc)

    # Extract field name from address. We use 2:end so "tracers/T "gets extracted
    # as :T while "timestepper/Gⁿ/T" gets extracted as :Gⁿ/T (we don't want to
    # apply the same BCs on T and T tendencies).
    field_name = split(address, "/")[2:end] |> join |> Symbol

    # If the user specified a non-default boundary condition through the kwargs
    # in restore_from_checkpoint, then use them when restoring the field. Otherwise
    # restore the BCs from the checkpoint file as long as they're not missing.
    if :boundary_conditions in keys(kwargs) && field_name in keys(kwargs[:boundary_conditions])
        bcs = kwargs[:boundary_conditions][field_name]
    else
        bcs = restore_if_not_missing(file, address * "/boundary_conditions")
    end

    return Field(field_address, arch, grid, bcs, data)
end

const u_location = (Face, Cell, Cell)
const v_location = (Cell, Face, Cell)
const w_location = (Cell, Cell, Face)
const c_location = (Cell, Cell, Cell)

"""
    restore_from_checkpoint(filepath; kwargs=Dict())

Restore a model from the checkpoint file stored at `filepath`. `kwargs` can be passed
to the model constructor, which can be especially useful if you need to manually
restore forcing functions or boundary conditions that rely on functions.
"""
function restore_from_checkpoint(filepath; kwargs...)
    kwargs = length(kwargs) == 0 ? Dict{Symbol,Any}() : Dict{Symbol,Any}(kwargs)

    file = jldopen(filepath, "r")
    cps = file["checkpointed_properties"]

    if haskey(kwargs, :architecture)
        arch = kwargs[:architecture]
        filter!(p -> p ≠ :architecture, cps)
    else
        arch = file["architecture"]
    end

    grid = file["grid"]

    # Restore velocity fields
    kwargs[:velocities] =
        VelocityFields(arch, grid, u = restore_field(file, "velocities/u", arch, grid, u_location, kwargs),
                                   v = restore_field(file, "velocities/v", arch, grid, v_location, kwargs),
                                   w = restore_field(file, "velocities/w", arch, grid, w_location, kwargs))
    filter!(p -> p ≠ :velocities, cps) # pop :velocities from checkpointed properties

    # Restore tracer fields
    tracer_names = Tuple(Symbol.(keys(file["tracers"])))
    tracer_fields = Tuple(restore_field(file, "tracers/$c", arch, grid, c_location, kwargs) for c in tracer_names)
    tracer_fields_kwargs = NamedTuple{tracer_names}(tracer_fields)
    kwargs[:tracers] = TracerFields(arch, grid, tracer_names; tracer_fields_kwargs...)

    filter!(p -> p ≠ :tracers, cps) # pop :tracers from checkpointed properties

    # Restore time stepper tendency fields
    field_names = (:u, :v, :w, tracer_names...) # field names
    locs = (u_location, v_location, w_location, Tuple(c_location for c in tracer_names)...) # name locations

    G⁻_fields = Tuple(restore_field(file, "timestepper/G⁻/$(field_names[i])", arch, grid, locs[i], kwargs) for i = 1:length(field_names))
    Gⁿ_fields = Tuple(restore_field(file, "timestepper/Gⁿ/$(field_names[i])", arch, grid, locs[i], kwargs) for i = 1:length(field_names))

    G⁻_tendency_field_kwargs = NamedTuple{field_names}(G⁻_fields)
    Gⁿ_tendency_field_kwargs = NamedTuple{field_names}(Gⁿ_fields)

    # Restore time stepper
    kwargs[:timestepper] =
        QuasiAdamsBashforth2TimeStepper(eltype(grid), arch, grid, kwargs[:velocities], tracer_names;
                                        G⁻ = TendencyFields(arch, grid, tracer_names; G⁻_tendency_field_kwargs...),
                                        Gⁿ = TendencyFields(arch, grid, tracer_names; Gⁿ_tendency_field_kwargs...))

    filter!(p -> p ≠ :timestepper, cps) # pop :timestepper from checkpointed properties

    # Restore the remaining checkpointed properties
    for p in cps
        kwargs[p] = file["$p"]
    end

    close(file)

    model = IncompressibleModel(; kwargs...)

    return model
end
