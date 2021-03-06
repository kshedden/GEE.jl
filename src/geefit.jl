abstract type AbstractGEE <: LinPredModel end

"""
    GEEResp

The response vector, grouping information, and vectors derived from
the response.  Vectors here are all n-dimensional.
"""
struct GEEResp{T<:Real} <: ModResp

    "`y`: response vector"
    y::Array{T,1}

    "`grp`: group labels, cases for each group must be stored consecutively."
    grp::Array{Int,2}

    "`wts`: case weights"
    wts::Array{T,1}

    "`η`: the linear predictor"
    η::Array{T,1}

    "`μ`: the mean"
    μ::Array{T,1}

    "`resid`: residuals"
    resid::Array{T,1}

    "`sresid`: standardized (Pearson) residuals"
    sresid::Array{T,1}

    "`sd`: the standard deviation of the observations"
    sd::Array{T,1}

    "`dμdη`: derivative of mean with respect to linear predictor"
    dμdη::Array{T,1}

    "`viresid`: whitened residuals"
    viresid::Array{T,1}

    "`offset`: offset is added to the linear predictor"
    offset::Array{T,1}

end

"""
    GEEprop

Properties that define a GLM fit using GEE - link, distribution, and
working correlation structure.
"""
struct GEEprop{D<:UnivariateDistribution,L<:Link,R<:CorStruct}

    "`dist`: the distribution family, used only to determine the variance"
    dist::D

    "`L`: the link function (maps from mean to linear predictor)"
    link::L

    "`cor`: the working correlation structure"
    cor::R

    "`cov_type`: the type of parameter covariance (default is robust)"
    cov_type::String

end

function GEEprop(dist, link, cor; cov_type="robust")
    GEEprop(dist, link, cor, cov_type)
end

"""
    GEECov

Covariance matrices for the parameter estimates.
"""
mutable struct GEECov

    "`cov`: the parameter covariance matrix"
    cov::Array{Float64,2}

    "`rcov`: the robust covariance matrix"
    rcov::Array{Float64,2}

    "`nacov`: the naive (model-dependent) covariance matrix"
    nacov::Array{Float64,2}

    "`mdcov`: the Mancel-DeRouen bias-reduced robust covariance matrix"
    mdcov::Array{Float64,2}

    "`kccov`: the Kauermann-Carroll bias-reduced robust covariance matrix"
    kccov::Array{Float64,2}

    "`scrcov`: the empirical Gram matrix of the score vectors (not scaled by n)"
    scrcov::Array{Float64,2}
end


function GEECov(p::Int)
    GEECov(zeros(p, p), zeros(p, p), zeros(p, p), zeros(p, p), zeros(p, p), zeros(p, p))
end

mutable struct GeneralizedEstimatingEquationsModel{G<:GEEResp,L<:LinPred} <: AbstractGEE
    rr::G
    pp::L
    qq::GEEprop
    cc::GEECov
    fit::Bool
end

function GEEResp(
    y::Array{T,1},
    g::Array{Int,2},
    wts::Array{T,1},
    off::Array{T,1},
) where {T<:Real}
    return GEEResp{T}(
        y,
        g,
        wts,
        similar(y),
        similar(y),
        similar(y),
        similar(y),
        similar(y),
        similar(y),
        similar(y),
        off,
    )
end

# Preliminary calculations for one iteration of GEE fitting.
function _iterprep(p::LinPred, r::GEEResp, q::GEEprop)
    updateη!(p, r.η, r.offset)
    r.μ .= linkinv.(q.link, r.η)
    r.resid .= r.y .- r.μ
    r.sd .= glmvar.(q.dist, r.μ)
    r.sd .= sqrt.(r.sd)
    r.sresid .= r.resid ./ r.sd
    r.dμdη .= mueta.(q.link, r.η)
end

function _iterate(p::LinPred, r::GEEResp, q::GEEprop, c::GEECov, last::Bool) where {T<:Real}

    p.score .= 0
    c.nacov .= 0
    if last
        c.scrcov .= 0
    end
    for j = 1:size(r.grp, 1)
        i1, i2 = r.grp[j, 1], r.grp[j, 2]
        updateD!(p, r.dμdη[i1:i2], i1, i2)
        w = length(r.wts) > 0 ? r.wts[i1:i2] : zeros(0)
        r.viresid[i1:i2] .= covsolve(q.cor, r.sd[i1:i2], w, r.resid[i1:i2])
        p.score_obs .= p.D' * r.viresid[i1:i2]
        p.score .= p.score + p.score_obs
        c.nacov .= c.nacov + p.D' * covsolve(q.cor, r.sd[i1:i2], w, p.D)

        if last
            # Only compute on final iteration
            c.scrcov .= c.scrcov + p.score_obs * p.score_obs'
        end
    end
end

# Calculate the Mancl-DeRouen and Kauermann-Carroll bias-corrected
# parameter covariance matrices.  This must run after the parameter
# fitting because it requires the naive covariance matrix and scale
# parameter estimates.
function _update_bc!(p::LinPred, r::GEEResp, q::GEEprop, c::GEECov, di::Float64)

    m = size(p.X, 2)
    bcm_md = zeros(m, m)
    bcm_kc = zeros(m, m)

    for j = 1:size(r.grp, 1)

        # Computation of common quantities
        i1, i2 = r.grp[j, 1], r.grp[j, 2]
        w = length(r.wts) > 0 ? r.wts[i1:i2] : zeros(0)
        updateD!(p, r.dμdη[i1:i2], i1, i2)
        vid = covsolve(q.cor, r.sd[i1:i2], w, p.D)
        vid .= vid ./ di
        h = p.D * c.nacov * vid'
        m = i2 - i1 + 1

        # Mancl-DeRouen
        ar = (I(m) - h) \ r.resid[i1:i2]
        sr = covsolve(q.cor, r.sd[i1:i2], w, ar)
        sr = p.D' * sr
        bcm_md .= bcm_md + sr * sr'

        # Kauermann-Carroll
        eval, evec = eigen(I(m) - h)
        eval .= (eval + abs.(eval)) ./ 2
        eval2 = 1 ./ sqrt.(eval)
        eval2[eval .== 0] .= 0
        ar = evec * diagm(eval2) * evec' * r.resid[i1:i2]
        sr = covsolve(q.cor, r.sd[i1:i2], w, real(ar))
        sr = p.D' * sr
        bcm_kc .= bcm_kc + sr * sr'

   end

   bcm_md .= bcm_md ./ di^2
   bcm_kc .= bcm_kc ./ di^2
   c.mdcov .= c.nacov * bcm_md * c.nacov
   c.kccov .= c.nacov * bcm_kc * c.nacov

end


function _fit!(
    m::AbstractGEE,
    verbose::Bool,
    maxiter::Integer,
    atol::Real,
    rtol::Real,
    start,
)

    m.fit && return m

    pp, rr, qq, cc = m.pp, m.rr, m.qq, m.cc
    y, g, η, μ, sd, dμdη = rr.y, rr.grp, rr.η, rr.μ, rr.sd, rr.dμdη
    viresid, resid, sresid = rr.viresid, rr.resid, rr.sresid
    link, dist, cor = qq.link, qq.dist, qq.cor
    score = pp.score
    scrcov, nacov = cc.scrcov, cc.nacov

    if isnothing(start)
        gm = StatsBase.fit(GeneralizedLinearModel, pp.X, y, dist, link)
        start = coef(gm)
    end

    pp.beta0 = start

    n, p = size(pp.X)
    last = false
    cvg = false

    for iter = 1:maxiter
        _iterprep(pp, rr, qq)
        updatecor(cor, sresid, g)
        _iterate(pp, rr, qq, cc, last)
        updateβ!(pp, score, nacov)

        if last
            break
        end
        nrm = norm(pp.delbeta)
        verbose && println("Iteration $iter, step $nrm")
        cvg = nrm < atol
        last = (iter == maxiter - 1) || cvg

    end

    m.cc.rcov = nacov \ scrcov / nacov
    m.cc.nacov = inv(nacov) .* dispersion(m)

    cvg || throw(ConvergenceException(maxiter))
    m.fit = true

    # Update the bias-corrected parameter covariances
    di = dispersion(m)
    _update_bc!(pp, rr, qq, cc, di)

    # Set the default covariance
    cc.cov = vcov(m, cov_type=qq.cov_type)

    m

end

Distributions.Distribution(q::GEEprop) = q.dist
Distributions.Distribution(m::GeneralizedEstimatingEquationsModel) = Distribution(m.qq)

Corstruct(m::GeneralizedEstimatingEquationsModel{G,L}) where {G,L} = m.qq.cor

function dispersion(m::AbstractGEE)
    r = m.rr.sresid
    if dispersion_parameter(m.qq.dist)
        if length(m.rr.wts) > 0
            w = m.rr.wts
            d = sum(w) - size(m.pp.X, 2)
            s = sum(i -> w[i]*r[i]^2, eachindex(r)) / d
        else
            s = sum(i -> r[i]^2, eachindex(r)) / dof_residual(m)
        end
    else
        one(eltype(r))
    end
end


# Return an m x 2 array, each row of which contains the indices
# spanning one group; also return the size of the largest group.
function groupix(g::AbstractVector)

    ii = []

    b = 1
    mx = 0
    for i = 2:length(g)
        if g[i] != g[i-1]
            append!(ii, [b, i - 1])
            mx = i - b > mx ? i - b : mx
            b = i
        end
    end
    append!(ii, [b, length(g)])
    mx = length(g) - b + 1 > mx ? length(g) - b + 1 : mx

    ii = reshape(ii, 2, length(ii) ÷ 2)
    (Array{Int,2}(transpose(ii)), mx)

end

function vcov(m::AbstractGEE; cov_type::String = "")
    if cov_type == ""
        # Default covariance
        return m.cc.cov
    elseif cov_type == "robust"
        return m.cc.rcov
    elseif cov_type == "naive"
        return m.cc.nacov
    elseif cov_type == "md"
        return m.cc.mdcov
    elseif cov_type == "kc"
        return m.cc.kccov
    else
        return nothing
    end
end

function stderror(m::AbstractGEE; cov_type = "robust")
    return sqrt.(diag(vcov(m; cov_type = cov_type)))
end

function coeftable(mm::AbstractGEE; level::Real = 0.95, cov_type::String = "")
    cov_type = (cov_type == "") ? mm.qq.cov_type : cov_type
    cc = coef(mm)
    se = stderror(mm; cov_type = cov_type)
    zz = cc ./ se
    p = 2 * ccdf.(Ref(Normal()), abs.(zz))
    ci = se * quantile(Normal(), (1 - level) / 2)
    levstr = isinteger(level * 100) ? string(Integer(level * 100)) : string(level * 100)
    CoefTable(
        hcat(cc, se, zz, p, cc + ci, cc - ci),
        ["Coef.", "Std. Error", "z", "Pr(>|z|)", "Lower $levstr%", "Upper $levstr%"],
        ["x$i" for i = 1:size(mm.pp.X, 2)],
        4,
        3,
    )
end

dof(x::GeneralizedEstimatingEquationsModel) =
    dispersion_parameter(x.qq.dist) ? length(coef(x)) + 1 : length(coef(x))


"""
    fit(GeneralizedEstimatingEquationsModel, X, y, g, d, c, [l = canonicallink(d)]; <keyword arguments>)

Fit a generalized linear model to data using generalized estimating
equations.  `X` and `y` can either be a matrix and a vector,
respectively, or a formula and a data frame. `g` is a vector
containing group labels, and elements in a group must be consecutive
in the data.  `d` must be a `UnivariateDistribution`, `c` must be a
`CorStruct` and `l` must be a [`Link`](@ref), if supplied.

# Keyword Arguments
- `cov_type::String`: Type of covariance estimate for parameters. Defaults
to "robust", other options are "naive", "md" (Mancl-DeRouen debiased) and
"kc" (Kauermann-Carroll debiased).xs
- `dofit::Bool=true`: Determines whether model will be fit
- `wts::Vector=similar(y,0)`: Not implemented.
Can be length 0 to indicate no weighting (default).
- `offset::Vector=similar(y,0)`: offset added to `Xβ` to form `eta`.  Can be of
length 0
- `verbose::Bool=false`: Display convergence information for each iteration
- `maxiter::Integer=100`: Maximum number of iterations allowed to achieve convergence
- `atol::Real=1e-6`: Convergence is achieved when the relative change in
`β` is less than `max(rtol*dev, atol)`.
- `rtol::Real=1e-6`: Convergence is achieved when the relative change in
`β` is less than `max(rtol*dev, atol)`.
- `start::AbstractVector=nothing`: Starting values for beta. Should have the
same length as the number of columns in the model matrix.
"""
function fit(
    ::Type{M},
    X::Matrix{T},
    y::AbstractVector{<:Real},
    g::AbstractVector,
    d::UnivariateDistribution,
    c::CorStruct = IndependenceCor(),
    l::Link = canonicallink(d);
    cov_type::String = "robust",
    dofit::Bool = true,
    wts::AbstractVector{<:Real} = similar(y, 0),
    offset::AbstractVector{<:Real} = similar(y, 0),
    fitargs...,
) where {M<:AbstractGEE,T<:FP}

    if !(size(X, 1) == size(y, 1) == size(g, 1))
        throw(DimensionMismatch("Number of rows in X, y and g must match"))
    end

    (gi, mg) = groupix(g)
    rr = GEEResp(y, gi, wts, offset)
    p = size(X, 2)
    res = M(rr, DensePred(X, mg), GEEprop(d, l, c, cov_type), GEECov(p), false)

    return dofit ? fit!(res, fitargs...) : res

end

"""
    gee(F, D, args...; kwargs...)
Fit a generalized linear model to data using generalized estimating
equations. Alias for `fit(GeneralizedEstimatingEquationsModel, ...)`.
See [`fit`](@ref) for documentation.
"""
gee(F, D, args...; kwargs...) =
    fit(GeneralizedEstimatingEquationsModel, F, D, args...; kwargs...)


function StatsBase.fit!(
    m::AbstractGEE;
    verbose::Bool = false,
    maxiter::Integer = 50,
    atol::Real = 1e-6,
    rtol::Real = 1e-6,
    start = nothing,
    kwargs...,
)

    _fit!(m, verbose, maxiter, atol, rtol, start)
end

"""
    corparams(m::AbstractGEE)

Return the parameters that define the working correlation structure.
"""
function corparams(m::AbstractGEE)
    return corparams(m.qq.cor)
end
