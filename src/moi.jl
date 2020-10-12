const SVF = MOI.SingleVariable
const VVF = MOI.VectorOfVariables
const SAF{T} = MOI.ScalarAffineFunction{T}
const VAF{T} = MOI.VectorAffineFunction{T}

const VI = MOI.VariableIndex
const CI = MOI.ConstraintIndex

const GT = MOI.GreaterThan
const LT = MOI.LessThan
const ET = MOI.EqualTo

const SCALAR_SETS = Union{
    MOI.GreaterThan{Float64},
    MOI.LessThan{Float64},
    MOI.EqualTo{Float64},
}

const VECTOR_SETS = Union{
    MOI.SecondOrderCone,
    MOI.RotatedSecondOrderCone,
}

# dual variable info
mutable struct ConstraintInfo{T<:Union{Float64, Vector{Float64}}}
    start::T
    upper::T
    lower::T
    function ConstraintInfo{Float64}()
        new(NaN, NaN, NaN)
    end
    function ConstraintInfo{Vector{Float64}}(N::Integer)
        new(fill(NaN, N), fill(NaN, N), fill(NaN, N))
    end
end

mutable struct VariableInfo{T<:Union{Float64, Vector{Float64}}}
    upper::T
    lower::T
    function VariableInfo{Float64}()
        new(NaN, NaN)
    end
    function VariableInfo{Vector{Float64}}(N::Integer)
        new(fill(NaN, N), fill(NaN, N))
    end
end
function VariableInfo(_info::ConstraintInfo{T}) where T
    info = VariableInfo{Float64}()
    info.lower = _info.lower
    info.upper = _info.upper
    return info
end

# abstract type AsbtractBilevelOptimizer end
# struct SOS1Optimizer{O} <: AsbtractBilevelOptimizer
#     solver::O
#     # options
# end
# function SOS1Optimizer(solver::O) where O
#     return SOS1Optimizer{O}(solver)
# end

struct Complement#{M1 <: MOI.ModelLike, M2 <: MOI.ModelLike, F, S}
    is_vec
    # primal::M1
    func_w_cte#::F
    set_w_zero#::S
    # dual::M2
    variable#::VI
    # var_set#::S2
end

abstract type BilevelSolverMode{T} end

mutable struct NoMode{T} <: BilevelSolverMode{T}
end

mutable struct SOS1Mode{T} <: BilevelSolverMode{T}
    function SOS1Mode()
        return new{Float64}()
    end
end

mutable struct PositiveSOS1Mode{T} <: BilevelSolverMode{T}
    function PositiveSOS1Mode()
        return new{Float64}()
    end
end

mutable struct ComplementMode{T} <: BilevelSolverMode{T}
    with_slack::Bool
    function ComplementMode(;with_slack = false)
        return new{Float64}(with_slack)
    end
end

mutable struct ProductMode{T} <: BilevelSolverMode{T}
    epsilon::T
    with_slack::Bool
    function ProductMode(eps::T=zero(Float64); with_slack = false) where T
        return new{Float64}(eps, with_slack)
    end
end

@enum IndicatorSetting ZERO_ONE ZERO_ZERO ONE_ONE

mutable struct IndicatorMode{T} <: BilevelSolverMode{T}
    mode::IndicatorSetting
    function IndicatorMode()
        return new{Float64}(ONE_ONE)
    end
end

mutable struct FortunyAmatMcCarlMode{T} <: BilevelSolverMode{T}
    with_slack::Bool
    safe::Bool # check variables bounds before MOI
    primal_big_M::Float64
    dual_big_M::Float64
    # internal usage
    upper::Dict{VI, VariableInfo}
    lower::Dict{VI, VariableInfo}
    ldual::Dict{CI, ConstraintInfo}
    # full map
    map::Dict{VI, VariableInfo}
    function FortunyAmatMcCarlMode(;with_slack = false, safe = true,
        primal_big_M = Inf, dual_big_M = Inf)
        return new{Float64}(
            with_slack,
            safe,
            primal_big_M,
            dual_big_M,
            Dict{VI, VariableInfo}(),
            Dict{VI, VariableInfo}(),
            Dict{CI, ConstraintInfo}(),
            Dict{VI, VariableInfo}(),
        )
    end
end

function appush!(col, element::AbstractVector)
    append!(col, element)
    return nothing
end
function appush!(col, element)
    push!(col, element)
    return nothing
end

function build_full_map!(mode,
    upper_idxmap, lower_idxmap, lower_dual_idxmap, lower_primal_dual_map)
    return nothing
end
function build_full_map!(mode::FortunyAmatMcCarlMode,
    upper_idxmap, lower_idxmap, lower_dual_idxmap, lower_primal_dual_map)
    empty!(mode.map)
    for (k,v) in mode.upper
        mode.map[upper_idxmap[k]] = v
    end
    for (k,v) in mode.lower
        mode.map[lower_idxmap[k]] = v
    end
    for (k,v) in mode.ldual
        vec = lower_primal_dual_map.primal_con_dual_var[k]#[1] # TODO check this scalar
        # @show typeof(vec)
        for var in vec
            mode.map[lower_dual_idxmap[var]] = VariableInfo(v)
        end
    end
    return nothing
end

abstract type StrongDualityMode{T} <: BilevelSolverMode{T} end

mutable struct StrongDualityEqualityMode{T} <: StrongDualityMode{T}
    function StrongDualityEqualityMode()
        return new{Float64}()
    end
end
mutable struct StrongDualityInequalityMode{T} <: StrongDualityMode{T}
    epsilon::T
    function StrongDualityInequalityMode()
        return new{Float64}(zero(Float64))
    end
    function StrongDualityInequalityMode(eps::T) where T
        return new{Float64}(eps)
    end
end

ignore_dual_objective(::BilevelSolverMode{T}) where T = true
ignore_dual_objective(::StrongDualityMode{T}) where T = false

function accept_vector_set(mode::BilevelSolverMode{T}, con::Complement) where T
    if con.is_vec
        error("Set $(typeof(con.set_w_zero)) is not accepted when solution method is $(typeof(mode))")
    end
    return nothing
end
accept_vector_set(::ProductMode{T}, ::Complement) where T = nothing

function get_canonical_complements(primal_model, primal_dual_map)
    map = primal_dual_map.primal_con_dual_var
    out = Complement[]
    for ci in keys(map)
        con = get_canonical_complement(primal_model, map, ci)
        push!(out, con)
    end
    return out
end
function get_canonical_complement(primal_model, map,
    ci::CI{F,S}) where {F, S<:VECTOR_SETS}
    T = Float64
    func = MOI.copy(MOI.get(primal_model, MOI.ConstraintFunction(), ci))::F
    set = MOI.copy(MOI.get(primal_model, MOI.ConstraintSet(), ci))::S
    dim = MOI.dimension(set)
    # vector sets have no constant
    # for i in 1:dim
    #     func.constant[i] = Dualization.set_dot(i, set, T) *
    #         Dualization.get_scalar_term(primal_model, i, ci)
    # end
    # todo - set dot on function
    con = Complement(true, func, set_with_zero(set), map[ci])
    return con
end
function get_canonical_complement(primal_model, map,
    ci::CI{F,S}) where {F, S<:SCALAR_SETS}
    T = Float64
    func = MOI.copy(MOI.get(primal_model, MOI.ConstraintFunction(), ci))::F
    set = MOI.copy(MOI.get(primal_model, MOI.ConstraintSet(), ci))::S
    constant = Dualization.set_dot(1, set, T) *
        Dualization.get_scalar_term(primal_model, 1, ci)
    if F == MOI.SingleVariable
        func = MOIU.operate(+, T, func, constant)
    else
        func.constant = constant
    end
    # todo - set dot on function
    con = Complement(false, func, set_with_zero(set), map[ci][1])
    return con
end

function set_with_zero(set::S) where {S<:SCALAR_SETS} where T
    return S(0.0)
end
function set_with_zero(set)
    return MOI.copy(set)
end

function build_bilevel(
    upper::MOI.ModelLike, lower::MOI.ModelLike,
    link::Dict{VI,VI}, upper_variables::Vector{VI},
    mode,
    upper_var_lower_ctr::Dict{VI,CI} = Dict{VI,CI}();
    copy_names::Bool = false,
    pass_start::Bool = false
    )

    # Start with an empty problem
    moi_mode = MOIU.AUTOMATIC
    # m = MOIU.CachingOptimizer(MOIU.Model{Float64}(), moi_mode)
    m = MOIU.CachingOptimizer(MOIU.UniversalFallback(MOIU.Model{Float64}()), moi_mode)

    #=
        Initialize Lower DUAL level model
    =#
    # dualize the second level
    dual_problem = dualize(lower,
        dual_names = DualNames("dual_","dual_"),
        variable_parameters = upper_variables,
        ignore_objective = ignore_dual_objective(mode))
    lower_dual = dual_problem.dual_model
    lower_primal_dual_map = dual_problem.primal_dual_map

    #=
        Pass Upper level model
    =#

    # key are from src, value are from dest
    upper_idxmap = MOIU.default_copy_to(m, upper, copy_names)
    if copy_names
        pass_names(m, upper, upper_idxmap)
    end

    #=
        Pass Lower level model
    =#

    handle_lower_objective_sense(lower)

    # cache and delete lower objective
    if !ignore_dual_objective(mode)
        # get primal obj
        tp_primal_obj = MOI.get(lower, MOI.ObjectiveFunctionType())
        @assert tp_primal_obj !== nothing
        lower_primal_obj = MOI.get(lower, MOI.ObjectiveFunction{tp_primal_obj}())
        # deepcopy and delete dual obj
        # MOI.set(lower, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(), MOI.ScalarAffineFunction(MOI.ScalarAffineTerm{Float64}[], 0.0))
    end

    # initialize map to lower level model
    lower_idxmap = MOIU.IndexMap()
    for (upper_key, lower_val) in link
        lower_idxmap[lower_val] = upper_idxmap[upper_key]
    end

    # append the second level primal
    append_to(m, lower, lower_idxmap, copy_names, allow_single_bounds = true)
    if copy_names
        pass_names(m, lower, lower_idxmap)
    end

    #=
        Pass Dual of Lower level model
    =#

    # initialize map to lower level model
    if !ignore_dual_objective(mode)
        # get dual obj
        tp_dual_obj = MOI.get(lower_dual, MOI.ObjectiveFunctionType())
        @assert tp_dual_obj !== nothing
        lower_dual_obj = MOI.get(lower_dual, MOI.ObjectiveFunction{tp_dual_obj}())
        # delete dual obj
        # MOI.set(lower_dual, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(), MOI.ScalarAffineFunction(MOI.ScalarAffineTerm{Float64}[], 0.0))
    end

    # initialize map to lower level model
    lower_dual_idxmap = MOIU.IndexMap()
    # for QP's there are dual variable that are tied to:
    # primal variables
    for (lower_primal_var_key, lower_dual_quad_slack_val) in lower_primal_dual_map.primal_var_dual_quad_slack
        lower_dual_idxmap[lower_dual_quad_slack_val] = lower_idxmap[lower_primal_var_key]
    end
    # and to upper level variable which are lower level parameters
    for (lower_primal_param_key, lower_dual_param_val) in lower_primal_dual_map.primal_parameter
        lower_dual_idxmap[lower_dual_param_val] = lower_idxmap[lower_primal_param_key]
    end
    # Dual variables might appear in the upper level
    for (upper_var, lower_con) in upper_var_lower_ctr
        var = lower_primal_dual_map.primal_con_dual_var[lower_con][1] # TODO check this scalar
        lower_dual_idxmap[var] = upper_idxmap[upper_var]
    end

    # append the second level dual
    append_to(m, lower_dual, lower_dual_idxmap, copy_names)
    if copy_names
        pass_names(m, lower_dual, lower_dual_idxmap)
    end

    #=
        Additional Optimiality conditions (to complete the KKT)
    =#

    # build map bound map for FortunyAmatMcCarlMode
    build_full_map!(mode,
    upper_idxmap, lower_idxmap, lower_dual_idxmap, lower_primal_dual_map)

    if ignore_dual_objective(mode)
        # complementary slackness
        comps = get_canonical_complements(lower, lower_primal_dual_map)
        for comp in comps
            if !is_equality(comp.set_w_zero)
                accept_vector_set(mode, comp)
                add_complement(mode, m, comp,
                    lower_idxmap, lower_dual_idxmap, copy_names, pass_start)
            else
                # println("eq in complement")
            end
        end
    else
        # strong duality
        lower_dual_obj
        lower_primal_obj
        add_strong_duality(mode, m, lower_primal_obj, lower_dual_obj, lower_idxmap, lower_dual_idxmap)
    end

    return m, upper_idxmap, lower_idxmap, lower_primal_dual_map, lower_dual_idxmap
end

function add_strong_duality(mode::StrongDualityEqualityMode{T}, m, primal_obj, dual_obj,
    idxmap_primal, idxmap_dual) where T

    primal = MOIU.map_indices.(Ref(idxmap_primal), primal_obj)
    dual   = MOIU.map_indices.(Ref(idxmap_dual), dual_obj)

    func = MOIU.operate(-, T, primal, dual)

    c = MOI.add_constraint(m, func, MOI.EqualTo(zero(T)))

    MOI.set(m, MOI.ConstraintName(), c, "lower_strong_duality")

    return c
end
function add_strong_duality(mode::StrongDualityInequalityMode{T}, m, primal_obj, dual_obj,
    idxmap_primal, idxmap_dual) where T

    primal = MOIU.map_indices.(Ref(idxmap_primal), primal_obj)
    dual   = MOIU.map_indices.(Ref(idxmap_dual), dual_obj)

    func = MOIU.operate(-, T, primal, dual)

    func_up = MOIU.operate(-, T, func, mode.epsilon)
    c_up = MOI.add_constraint(m, func_up, MOI.LessThan(zero(T)))
    MOI.set(m, MOI.ConstraintName(), c_up, "lower_strong_duality_up")

    func_lo = MOIU.operate(+, T, func, mode.epsilon)
    c_lo = MOI.add_constraint(m, func_lo, MOI.GreaterThan(zero(T)))
    MOI.set(m, MOI.ConstraintName(), c_lo, "lower_strong_duality_lo")

    return c_up, c_lo
end

function add_complement(mode::ComplementMode{T}, m, comp::Complement,
    idxmap_primal, idxmap_dual, copy_names::Bool, pass_start::Bool) where T
    f = comp.func_w_cte
    s = comp.set_w_zero
    v = comp.variable
    out_var = VI[]
    out_ctr = CI[]

    with_slack = mode.with_slack

    f_dest = MOIU.map_indices.(Ref(idxmap_primal), f)

    dual = idxmap_dual[v]

    if with_slack
        slack, slack_in_set = MOI.add_constrained_variable(m, s)
        new_f = MOIU.operate(-, T, f_dest, MOI.SingleVariable(slack))
        equality = MOIU.normalize_and_add_constraint(m, new_f, MOI.EqualTo(zero(T)))

        if pass_start
            val = MOIU.eval_variables(
                x-> nothing_to_nan(MOI.get(m, MOI.VariablePrimalStart(), x)), f_dest)
            if !isnan(val)
                MOI.set(m, MOI.VariablePrimalStart(), slack, val)
            end
        end

        c = MOI.add_constraint(m, 
            MOI.VectorOfVariables([slack, dual]),
            MOI.Complements(1))
        if copy_names
            nm = MOI.get(m, MOI.VariableName(), dual)
            MOI.set(m, MOI.VariableName(), slack, "slk_($(nm))")
            MOI.set(m, MOI.ConstraintName(), slack_in_set, "bound_slk_($(nm))")
            MOI.set(m, MOI.ConstraintName(), equality, "eq_slk_($(nm))")
            MOI.set(m, MOI.ConstraintName(), c, "compl_complWslk_($(nm))")
        end

        appush!(out_var, slack)
        appush!(out_ctr, slack_in_set)
        appush!(out_ctr, equality)
        appush!(out_ctr, c)
    else
        new_f = MOIU.operate(vcat, T, f_dest, MOI.SingleVariable(dual))

        c = MOI.add_constraint(m, 
            new_f,
            MOI.Complements(1))

        if copy_names
            nm = MOI.get(m, MOI.VariableName(), dual)
            MOI.set(m, MOI.ConstraintName(), c, "compl_compl_($(nm))")
        end

        appush!(out_ctr, c)
    end

    return out_var, out_ctr
end

function add_complement(mode::SOS1Mode{T}, m, comp::Complement,
    idxmap_primal, idxmap_dual, copy_names::Bool, pass_start::Bool) where T
    f = comp.func_w_cte
    s = comp.set_w_zero
    v = comp.variable

    if comp.is_vec
        error("Vector constraint is not supported by SOS1 mode")
    end

    slack, slack_in_set = MOI.add_constrained_variable(m, s)
    f_dest = MOIU.map_indices.(Ref(idxmap_primal), f)
    new_f = MOIU.operate(-, T, f_dest, MOI.SingleVariable(slack))
    equality = MOIU.normalize_and_add_constraint(m, new_f, MOI.EqualTo(zero(T)))

    dual = idxmap_dual[v]
    c1 = MOI.add_constraint(m, 
        MOI.VectorOfVariables([slack, dual]),
        MOI.SOS1([1.0, 2.0]))

    if copy_names
        nm = MOI.get(m, MOI.VariableName(), dual)
        MOI.set(m, MOI.VariableName(), slack, "slk_($(nm))")
        MOI.set(m, MOI.ConstraintName(), slack_in_set, "bound_slk_($(nm))")
        MOI.set(m, MOI.ConstraintName(), equality, "eq_slk_($(nm))")
        MOI.set(m, MOI.ConstraintName(), c1, "compl_sos1_($(nm))")
    end

    return slack, slack_in_set, equality, c1
end

function add_complement(mode::PositiveSOS1Mode{T}, m, comp::Complement,
    idxmap_primal, idxmap_dual, copy_names::Bool, pass_start::Bool) where T
    f = comp.func_w_cte
    s = comp.set_w_zero
    v = comp.variable

    if comp.is_vec
        error("Vector constraint is not supported by PositiveSOS1 mode")
    end

    f_dest = MOIU.map_indices.(Ref(idxmap_primal), f)

    if typeof(s) <: MOI.LessThan # 0
        # requires flipping
        # flipped slack
        slack, slack_in_set = MOI.add_constrained_variable(m, MOI.GreaterThan{T}(0.0))
        new_f = MOIU.operate(+, T, f_dest, MOI.SingleVariable(slack))
        # flipped dual
        real_dual = idxmap_dual[v]
        dual, dual_in_set = MOI.add_constrained_variable(m, MOI.GreaterThan{T}(0.0))
        # dual + real_dual == 0
        opposite = MOIU.normalize_and_add_constraint(m,
            MOI.ScalarAffineFunction(
                [MOI.ScalarAffineTerm(1.0, real_dual),
                 MOI.ScalarAffineTerm(1.0, dual)],
                0.0),
            MOI.EqualTo(zero(T)))
        if copy_names
            nm = MOI.get(m, MOI.VariableName(), dual)
            MOI.set(m, MOI.VariableName(), slack, "flip_dual_($(nm))")
            MOI.set(m, MOI.ConstraintName(), slack_in_set, "flip_dual_in_set_($(nm))")
            MOI.set(m, MOI.ConstraintName(), opposite, "flip_dual_eq_($(nm))")
        end
    elseif typeof(s) <: MOI.GreaterThan # 0
        slack, slack_in_set = MOI.add_constrained_variable(m, s)
        new_f = MOIU.operate(-, T, f_dest, MOI.SingleVariable(slack))
        dual = idxmap_dual[v]
    else
        error("Unexpected set type: $s, while building complment constraints.")
    end

    equality = MOIU.normalize_and_add_constraint(m, new_f, MOI.EqualTo(zero(T)))

    c1 = MOI.add_constraint(m, 
        MOI.VectorOfVariables([slack, dual]),
        MOI.SOS1([1.0, 2.0]))

    if copy_names
        nm = MOI.get(m, MOI.VariableName(), dual)
        MOI.set(m, MOI.VariableName(), slack, "slk_($(nm))")
        MOI.set(m, MOI.ConstraintName(), slack_in_set, "bound_slk_($(nm))")
        MOI.set(m, MOI.ConstraintName(), equality, "eq_slk_($(nm))")
        MOI.set(m, MOI.ConstraintName(), c1, "compl_sos1_($(nm))")
    end
    return slack, slack_in_set, equality, c1
end

function flip_set(set::MOI.LessThan{T}) where T
    return MOI.GreaterThan{T}(0.0)
end
function flip_set(set::MOI.GreaterThan{T}) where T
    return MOI.LessThan{T}(0.0)
end
is_equality(set::S) where {S<:MOI.AbstractSet} = false
is_equality(set::MOI.EqualTo{T}) where T = true
is_equality(set::MOI.Zeros) = true

only_variable_functions(v::MOI.VariableIndex) = MOI.SingleVariable(v)
only_variable_functions(v::Vector{MOI.VariableIndex}) = MOI.VectorOfVariables(v)

nothing_to_nan(val) = ifelse(val === nothing, NaN, val)

function add_complement(mode::ProductMode{T}, m, comp::Complement,
    idxmap_primal, idxmap_dual, copy_names::Bool, pass_start::Bool) where T
    f = comp.func_w_cte
    s = comp.set_w_zero
    v = comp.variable

    out_var = VI[]
    out_ctr = CI[]

    eps = mode.epsilon
    with_slack = mode.with_slack

    f_dest = MOIU.map_indices(x->idxmap_primal[x], f)

    dual = comp.is_vec ? map(x->idxmap_dual[x], v) : idxmap_dual[v]

    if with_slack
        slack, slack_in_set = if comp.is_vec
            MOI.add_constrained_variables(m, s)
        else
            MOI.add_constrained_variable(m, s)
        end
        new_f = MOIU.operate(-, T, f_dest, only_variable_functions(slack))
        if comp.is_vec
            equality = MOIU.normalize_and_add_constraint(m, new_f, MOI.Zeros(length(slack)))
        else
            equality = MOIU.normalize_and_add_constraint(m, new_f, MOI.EqualTo(zero(T)))
        end

        prod_f = MOIU.operate(dot, T, only_variable_functions(slack), only_variable_functions(dual))

        prod_f1 = MOIU.operate(-, T, prod_f, eps)
        c1 = MOIU.normalize_and_add_constraint(m, 
            prod_f1,
            MOI.LessThan{Float64}(0.0))
        if comp.is_vec
            prod_f2 = MOIU.operate(+, T, prod_f, eps)
            c2 = MOIU.normalize_and_add_constraint(m, 
                prod_f2,
                MOI.GreaterThan{Float64}(0.0))
        end

        appush!(out_var, slack)
        appush!(out_ctr, slack_in_set)
        appush!(out_ctr, equality)
        appush!(out_ctr, c1)
        if comp.is_vec
            appush!(out_ctr, c2)
        end

        if pass_start
            val = MOIU.eval_variables(
                x-> nothing_to_nan(MOI.get(m, MOI.VariablePrimalStart(), x)), f_dest)
            if comp.is_vec
                for i in eachindex(val)
                    if !isnan(val[i])
                        MOI.set(m, MOI.VariablePrimalStart(), slack[i], val[i])
                    end
                end
            else
                if !isnan(val)
                    MOI.set(m, MOI.VariablePrimalStart(), slack, val)
                end
            end
        end

        if copy_names
            nm = MOI.get(m, MOI.VariableName(), dual)
            MOI.set(m, MOI.VariableName(), slack, "slk_($(nm))")
            MOI.set(m, MOI.ConstraintName(), slack_in_set, "bound_slk_($(nm))")
            MOI.set(m, MOI.ConstraintName(), equality, "eq_slk_($(nm))")
            MOI.set(m, MOI.ConstraintName(), c1, "compl_prodWslk_($(nm))")
            if comp.is_vec
                MOI.set(m, MOI.ConstraintName(), c1, "compl_prodWslk2_($(nm))")
            end
        end
    else
        new_f = MOIU.operate(dot, T, f_dest, only_variable_functions(dual))
        new_f1 = MOIU.operate(-, T, new_f, eps)
        c1 = MOIU.normalize_and_add_constraint(m, 
            new_f1,
            MOI.LessThan{T}(0.0))
        if comp.is_vec # conic
            new_f2 = MOIU.operate(+, T, new_f, eps)
            c2 = MOIU.normalize_and_add_constraint(m, 
                new_f2,
                MOI.GreaterThan{T}(0.0))
        end

        # TODO(?): if eps == 0 then add equality

        appush!(out_ctr, c1)
        if comp.is_vec
            appush!(out_ctr, c2)
        end

        if copy_names
            nm = if comp.is_vec
                MOI.get.(m, MOI.VariableName(), dual)
            else
                MOI.get(m, MOI.VariableName(), dual)
            end
            MOI.set(m, MOI.ConstraintName(), c1, "compl_prod_($(nm))")
            if comp.is_vec
                MOI.set(m, MOI.ConstraintName(), c2, "compl_prod2_($(nm))")
            end
        end
    end
    return out_var, out_ctr
end

function add_complement(mode::IndicatorMode{T}, m, comp::Complement,
    idxmap_primal, idxmap_dual, copy_names::Bool, pass_start::Bool) where T
    f = comp.func_w_cte
    s = comp.set_w_zero
    v = comp.variable

    method = mode.mode

    is_tight = false
    has_start = false

    f_dest = MOIU.map_indices(x->idxmap_primal[x], f)

    dual = idxmap_dual[v]

    if comp.is_vec
        error("Vector constraint is (currently) not supported by indicator mode")
    end

    if copy_names
        nm = if comp.is_vec
            MOI.get.(m, MOI.VariableName(), dual)
        else
            MOI.get(m, MOI.VariableName(), dual)
        end
    end

    vb1 = MOI.add_variable(m)
    if copy_names
        MOI.set(m, MOI.VariableName(), vb1, "compl_bin1_($(nm))")
    end

    cb1 = MOI.add_constraint(m, SVF(vb1), MOI.ZeroOne())
    if method == ONE_ONE || method == ZERO_ZERO
        # second binary
        vb2 = MOI.add_variable(m)
        cb2 = MOI.add_constraint(m, SVF(vb2), MOI.ZeroOne())
        if copy_names
            MOI.set(m, MOI.VariableName(), vb2, "compl_bin2_($(nm))")
        end

        # z1 + z2 == 1
        fb = MOIU.operate(+, T, SVF(vb1), SVF(vb2))
        cb = MOI.add_constraint(m, fb, MOI.EqualTo{T}(one(T)))
        if copy_names
            MOI.set(m, MOI.ConstraintName(), cb, "compl_sum_bin_($(nm))")
        end
    else
        vb2 = vb1
    end

    f1 = MOIU.operate(vcat, T, SVF(vb1), f_dest)
    f2 = MOIU.operate(vcat, T, SVF(vb2), SVF(dual))

    if pass_start
        val = MOIU.eval_variables(
            x-> nothing_to_nan(MOI.get(m, MOI.VariablePrimalStart(), x)), f_dest)
        if !isnan(val)
            is_tight = abs(val) < 1e-8
            has_start = true
        end
    end

    if method == ONE_ONE
        s1 = MOI.IndicatorSet{MOI.ACTIVATE_ON_ONE}(MOI.EqualTo(zero(T)))
        s2 = MOI.IndicatorSet{MOI.ACTIVATE_ON_ONE}(MOI.EqualTo(zero(T)))
        if pass_start && has_start
            MOI.set(m, MOI.VariablePrimalStart(), vb1, ifelse(is_tight, 1.0, 0.0))
            MOI.set(m, MOI.VariablePrimalStart(), vb2, ifelse(is_tight, 0.0, 1.0))
        end
    elseif method == ZERO_ZERO
        s1 = MOI.IndicatorSet{MOI.ACTIVATE_ON_ZERO}(MOI.EqualTo(zero(T)))
        s2 = MOI.IndicatorSet{MOI.ACTIVATE_ON_ZERO}(MOI.EqualTo(zero(T)))
        if pass_start && has_start
            MOI.set(m, MOI.VariablePrimalStart(), vb1, ifelse(is_tight, 0.0, 1.0))
            MOI.set(m, MOI.VariablePrimalStart(), vb2, ifelse(is_tight, 1.0, 0.0))
        end
    else
        s1 = MOI.IndicatorSet{MOI.ACTIVATE_ON_ONE}(MOI.EqualTo(zero(T)))
        s2 = MOI.IndicatorSet{MOI.ACTIVATE_ON_ZERO}(MOI.EqualTo(zero(T)))
        if pass_start && has_start
            MOI.set(m, MOI.VariablePrimalStart(), vb1, ifelse(is_tight, 1.0, 0.0))
        end
    end

    # MOIU.normalize_and_add_constraint
    c1 = MOI.add_constraint(m, to_vector_affine(f1), s1)
    c2 = MOI.add_constraint(m, to_vector_affine(f2), s2)

    if copy_names
        MOI.set(m, MOI.ConstraintName(), c1, "compl_ind1_($(nm))")
        MOI.set(m, MOI.ConstraintName(), c2, "compl_ind2_($(nm))")
    end
    return c1
end

function get_bounds(var, map, fallback_bound = Inf)
    if haskey(map, var)
        info = map[var]
        # TODO deal with precision and performance
        return IntervalArithmetic.interval(info.lower, info.upper)
    elseif 0.0 <= fallback_bound <= Inf
        return IntervalArithmetic.interval(-fallback_bound, fallback_bound)
    else
        error("variable $var has no finite bounds defined")
    end
end

function set_bound(inter::IntervalArithmetic.Interval, ::LT{T}) where T
    return inter.hi
end
function set_bound(inter::IntervalArithmetic.Interval, ::GT{T}) where T
    return inter.lo
end

function add_complement(mode::FortunyAmatMcCarlMode{T}, m, comp::Complement,
    idxmap_primal, idxmap_dual, copy_names::Bool, pass_start::Bool) where T

    f = comp.func_w_cte
    s = comp.set_w_zero
    v = comp.variable

    is_tight = false
    has_start = false

    if mode.with_slack
        slack, slack_in_set = MOI.add_constrained_variable(m, s)
    end
    f_dest = MOIU.map_indices.(Ref(idxmap_primal), f)

    f_bounds = MOIU.eval_variables(vi -> get_bounds(vi, mode.map, mode.primal_big_M), f_dest)

    if pass_start
        val = MOIU.eval_variables(
            x-> nothing_to_nan(MOI.get(m, MOI.VariablePrimalStart(), x)), f_dest)
        if !isnan(val)
            is_tight = abs(val) < 1e-8
            has_start = true
        end
    end

    if mode.with_slack
        new_f = MOIU.operate(-, T, f_dest, MOI.SingleVariable(slack))
        equality = MOIU.normalize_and_add_constraint(m, new_f, MOI.EqualTo(zero(T)))
        if pass_start && has_start
            MOI.set(m, MOI.VariablePrimalStart(), slack, val)
        end
    end

    dual = idxmap_dual[v]
    v_bounds = get_bounds(dual, mode.map, mode.dual_big_M)

    bin = MOI.add_variable(m)
    if pass_start && has_start && is_tight
        MOI.set(m, MOI.VariablePrimalStart(), bin, 1.0)
        MOI.set(m, MOI.VariablePrimalStart(), dual, 0.0)
    else
        MOI.set(m, MOI.VariablePrimalStart(), bin, 0.0)
    end

    s1 = flip_set(s)
    s2 = flip_set(s)

    Ms = set_bound(f_bounds, s1)
    Mv = set_bound(v_bounds, s2)

    if isnan(Ms) || abs(Ms) >= Inf || isnan(Mv) || abs(Mv) >= Inf
        error("It was not possible to automatically compute bounds"*
            " for a complementarity pair, please add the arguments"*
            " primal_big_M and dual_big_M to FortunyAmatMcCarlMode")
    end
    
    if mode.with_slack
        f1 = MOI.ScalarAffineFunction{T}(
            MOI.ScalarAffineTerm{T}.(
                [one(T), -Ms], [slack, bin]
            ),
            0.0
        )
    else
        push!(f_dest.terms, MOI.ScalarAffineTerm{T}(-Ms, bin))
        f1 = f_dest
    end

    f2 = MOI.ScalarAffineFunction{T}(
        MOI.ScalarAffineTerm{T}.(
            [one(T), Mv], [dual, bin]
        ),
        -Mv
    )

    c1 = MOIU.normalize_and_add_constraint(m, f1, s2)
    c2 = MOIU.normalize_and_add_constraint(m, f2, s2)
    c3 = MOI.add_constraint(m, MOI.SingleVariable(bin), MOI.ZeroOne())

    if copy_names
        nm = MOI.get(m, MOI.VariableName(), dual)
        if mode.with_slack
            MOI.set(m, MOI.VariableName(), slack, "slk_($(nm))")
            MOI.set(m, MOI.ConstraintName(), slack_in_set, "bound_slk_($(nm))")
            MOI.set(m, MOI.ConstraintName(), equality, "eq_slk_($(nm))")
        end
        MOI.set(m, MOI.VariableName(), bin, "bin_($(nm))")
        MOI.set(m, MOI.ConstraintName(), c1, "compl_fa_sl_($(nm))")
        MOI.set(m, MOI.ConstraintName(), c2, "compl_fa_dl_($(nm))")
        MOI.set(m, MOI.ConstraintName(), c2, "compl_fa_bn_($(nm))")
    end

    # if mode.with_slack
    #     return slack, slack_in_set, equality, c1
    # else
    # end
    return c1
end

function to_vector_affine(f::MOI.VectorAffineFunction{T}) where T
    return f
end
function to_vector_affine(f::MOI.VectorOfVariables)
    return MOI.VectorAffineFunction{Float64}(f)
end

function pass_names(dest, src, map)
    for vi in MOI.get(src, MOI.ListOfVariableIndices())
        name = MOI.get(src, MOI.VariableName(), vi)
        if name != ""
            MOI.set(dest, MOI.VariableName(), map[vi], name)
        end
    end
    for (F,S) in MOI.get(src, MOI.ListOfConstraints())
        for con in MOI.get(src, MOI.ListOfConstraintIndices{F,S}())
            name = MOI.get(src, MOI.ConstraintName(), con)
            if name != ""
                MOI.set(dest, MOI.ConstraintName(), map[con], name)
            end
        end
    end
end

function append_to(dest::MOI.ModelLike, src::MOI.ModelLike, idxmap, copy_names::Bool, 
    filter_constraints::Union{Nothing, Function}=nothing; allow_single_bounds::Bool = true)

    #=
        This function follows closely the function `default_copy_to` defined in
        MathOptInterface.Utilities
        due to some caveats of this function we keep the commented functions
        from the original function to highlight the differences and 
        easen the burden of updating when `default_copy_to` is updated.
    =#

    # MOI.empty!(dest)

    # idxmap = MOIU.IndexMap()

    vis_src = MOI.get(src, MOI.ListOfVariableIndices())
    # index_map_for_variable_indices only initializes the data structure
    # idxmap = index_map_for_variable_indices(vis_src)
    
    # The `NLPBlock` assumes that the order of variables does not change (#849)
    if MOI.NLPBlock() in MOI.get(src, MOI.ListOfModelAttributesSet())
        error("NLP models are not supported.")
        constraint_types = MOI.get(src, MOI.ListOfConstraints())
        single_variable_types = [S for (F, S) in constraint_types
                                 if F == MOI.SingleVariable]
        vector_of_variables_types = [S for (F, S) in constraint_types
                                     if F == MOI.VectorOfVariables]
        vector_of_variables_not_added = [
            MOI.get(src, MOI.ListOfConstraintIndices{MOI.VectorOfVariables, S}())
            for S in vector_of_variables_types
        ]
        single_variable_not_added = [
            MOI.get(src, MOI.ListOfConstraintIndices{MOI.SingleVariable, S}())
            for S in single_variable_types
        ]
    else
        # the key asusmption here is that MOI keeps the following behaviour
        # "The copy is only done when
        # the variables to be copied are not already keys of `idxmap`. It returns a list
        # of the constraints copied and not copied."
        # from copy_single_variable and copy_vector_of_variables.
        # this is very importante because variables are shered between
        # upper, lower and lower dual levels
        vector_of_variables_types, _, vector_of_variables_not_added,
        single_variable_types, _, single_variable_not_added = MOIU.try_constrain_variables_on_creation(
            dest, src, idxmap, MOI.add_constrained_variables, MOI.add_constrained_variable
        )
    end

    # MOIU.copy_free_variables(dest, idxmap, vis_src, MOI.add_variables)
    # copy variables has a size check that dows not generalizes here
    # because we have previously added variables
    for vi in vis_src
        if !haskey(idxmap.varmap, vi)
            var = MOI.add_variable(dest)
            idxmap.varmap[vi] = var
        end
    end

    # Copy variable attributes
    MOIU.pass_attributes(dest, src, copy_names, idxmap, vis_src)

    # Copy model attributes
    # attention HERE to no pass objective functions!
    # pass_attributes(dest, src, copy_names, idxmap)

    # Copy constraints
    MOIU.pass_constraints(dest, src, copy_names, idxmap,
                     single_variable_types, single_variable_not_added,
                     vector_of_variables_types, vector_of_variables_not_added,
                     filter_constraints=filter_constraints)

    return idxmap
end

using LinearAlgebra

# scalar
function MOIU.promote_operation(::typeof(LinearAlgebra.dot), ::Type{T},
    ::Type{<:Union{MOI.SingleVariable, MOI.ScalarAffineFunction{T}}},
    ::Type{T}
    ) where T
    MOI.ScalarAffineFunction{T}
end
function MOIU.promote_operation(::typeof(LinearAlgebra.dot), ::Type{T},
    ::Type{T},
    ::Type{<:Union{MOI.SingleVariable, MOI.ScalarAffineFunction{T}}}
    ) where T
    MOI.ScalarAffineFunction{T}
end
function MOIU.promote_operation(::typeof(LinearAlgebra.dot), ::Type{T},
    ::Type{<:Union{MOI.SingleVariable, MOI.ScalarAffineFunction{T}}},
    ::Type{<:Union{MOI.SingleVariable, MOI.ScalarAffineFunction{T}}}
    ) where T
    MOI.ScalarQuadraticFunction{T}
end
function MOIU.promote_operation(::typeof(LinearAlgebra.dot), ::Type{T},
    ::Type{MOI.ScalarQuadraticFunction{T}},
    ::Type{T}
    ) where T
    MOI.ScalarQuadraticFunction{T}
end
function MOIU.promote_operation(::typeof(LinearAlgebra.dot), ::Type{T},
    ::Type{T},
    ::Type{MOI.ScalarQuadraticFunction{T}}
    ) where T
    MOI.ScalarQuadraticFunction{T}
end
# flip
function MOIU.operate(::typeof(LinearAlgebra.dot), ::Type{T},
    f::Union{
        MOI.SingleVariable,
        MOI.ScalarAffineFunction{T},
        MOI.ScalarQuadraticFunction{T}
        },
    α::T) where T
    return MOIU.operate(LinearAlgebra.dot, T, α, f)
end
# pass to *
function MOIU.operate(::typeof(LinearAlgebra.dot), ::Type{T},
    f::Union{
        T,
        MOI.SingleVariable,
        MOI.ScalarAffineFunction{T}
        },
    g::Union{
        MOI.SingleVariable,
        MOI.ScalarAffineFunction{T}
        }
    ) where T
    return MOIU.operate(*, T, f, g)
end
function MOIU.operate(::typeof(LinearAlgebra.dot), ::Type{T},
    α::T,
    f::MOI.ScalarQuadraticFunction{T}
    ) where T
    return MOIU.operate(*, T, f, α)
end

# vector
function MOIU.promote_operation(::typeof(LinearAlgebra.dot), ::Type{T},
    ::Type{<:Union{MOI.VectorOfVariables, MOI.VectorAffineFunction{T}}},
    ::Type{Vector{T}}
    ) where T
    MOI.VectorAffineFunction{T}
end
function MOIU.promote_operation(::typeof(LinearAlgebra.dot), ::Type{T},
    ::Type{Vector{T}},
    ::Type{<:Union{MOI.VectorOfVariables, MOI.VectorAffineFunction{T}}}
    ) where T
    MOI.VectorAffineFunction{T}
end
function MOIU.promote_operation(::typeof(LinearAlgebra.dot), ::Type{T},
    ::Type{<:Union{MOI.VectorOfVariables, MOI.VectorAffineFunction{T}}},
    ::Type{<:Union{MOI.VectorOfVariables, MOI.VectorAffineFunction{T}}}
    ) where T
    MOI.VectorQuadraticFunction{T}
end
function MOIU.promote_operation(::typeof(LinearAlgebra.dot), ::Type{T},
    ::Type{MOI.VectorQuadraticFunction{T}},
    ::Type{Vector{T}}
    ) where T
    MOI.VectorQuadraticFunction{T}
end
function MOIU.promote_operation(::typeof(LinearAlgebra.dot), ::Type{T},
    ::Type{Vector{T}},
    ::Type{MOI.VectorQuadraticFunction{T}}
    ) where T
    MOI.VectorQuadraticFunction{T}
end
# flip
function MOIU.operate(::typeof(LinearAlgebra.dot), ::Type{T},
    f::Union{
        MOI.VectorOfVariables,
        MOI.VectorAffineFunction{T},
        MOI.VectorQuadraticFunction{T}
        },
    α::Vector{T}) where T
    return MOIU.operate(LinearAlgebra.dot, T, α, f)
end
# pass to _operate(LinearAlgebra.dot, ...)
function MOIU.operate(::typeof(LinearAlgebra.dot), ::Type{T},
    f::Union{
        Vector{T},
        MOI.VectorOfVariables,
        MOI.VectorAffineFunction{T}
        },
    g::Union{
        MOI.VectorOfVariables,
        MOI.VectorAffineFunction{T}
        }
    ) where T
    return _operate(LinearAlgebra.dot, T, f, g)
end
function MOIU.operate(::typeof(LinearAlgebra.dot), ::Type{T},
    α::T,
    f::MOI.VectorQuadraticFunction{T}
    ) where T
    return _operate(LinearAlgebra.dot, T, f, α)
end
function _operate(::typeof(LinearAlgebra.dot), ::Type{T},
    f::Union{
        Vector{T},
        MOI.VectorOfVariables,
        MOI.VectorAffineFunction{T},
        MOI.VectorQuadraticFunction{T}
        },
    g::Union{
        MOI.VectorOfVariables,
        MOI.VectorAffineFunction{T},
        MOI.VectorQuadraticFunction{T}
    }) where T

    dim = MOI.output_dimension(g)
    if MOI.output_dimension(f) != dim
        throw(DimensionMismatch("f and g are of different MOI.output_dimension's!"))
    end

    fs = MOIU.scalarize(f)
    gs = MOIU.scalarize(g)

    out = MOIU.operate(*, T, fs[1], gs[1])
    for i in 2:dim
        MOIU.operate!(+, T, out, MOIU.operate(*, T, fs[i], gs[i]))
    end

    return out
end
MOIU.scalarize(v::Vector{T}) where T<:Number = v
MOI.output_dimension(v::Vector{T}) where T<:Number = length(v)#

function handle_lower_objective_sense(lower::MOI.ModelLike)
    lower_objective_sense = MOI.get(lower, MOI.ObjectiveSense())
    if lower_objective_sense == MOI.FEASIBILITY_SENSE
        throw(ErrorException("Lower level models with objective_sense: " * 
                            lower_objective_sense * 
                            " are not supported."))
    end
    return
end