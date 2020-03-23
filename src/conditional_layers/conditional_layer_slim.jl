# Invertible conditional HINT layer from Kruse et al. (2020)
# Author: Philipp Witte, pwitte3@gatech.edu
# Date: January 2020

export ConditionalLayerSLIM

"""
    CI = ConditionalLayerSLIM(nx1, nx2, nx_in, nx_hidden, ny1, ny2, ny_in, ny_hidden, batchsize, Op; k1=1, k2=3, p1=1, p2=0)

 Create a conditional SLIM layer based on the HINT architecture.

 *Input*: 

 - `nx1`, `nx2`: spatial dimensions of `X`

 - `nx_in`, `nx_hidden`: number of input and hidden channels of `X`

 - `ny1`, `ny2`: spatial dimensions of `Y`
 
 - `ny_in`, `ny_hidden`: number of input and hidden channels of `Y`

 - `Op`: Linear forward modeling operator

 - `k1`, `k2`: kernel size of convolutions in residual block. `k1` is the kernel of the first and third 
    operator, `k2` is the kernel size of the second operator.

 - `p1`, `p2`: padding for the first and third convolution (`p1`) and the second convolution (`p2`)

 *Output*:
 
 - `CI`: Conditional SLIM coupling layer.

 *Usage:*

 - Forward mode: `Zx, Zy, logdet = CI.forward_X(X, Y, Op)`

 - Inverse mode: `X, Y = CI.inverse(Zx, Zy, Op)`

 - Backward mode: `ΔX, ΔY, X, Y = CI.backward(ΔZx, ΔZy, Zx, Zy, Op)`

 - Forward mode Y: `Zy = CI.forward_Y(Y)`

 - Inverse mode Y: `Y = CI.inverse(Zy)`

 *Trainable parameters:*

 - None in `CI` itself

 - Trainable parameters in coupling layers `CI.CL_X`, `CI.CL_Y`, `CI.CL_XY` and in
   permutation layers `CI.C_X` and `CI.C_Y`.

 See also: [`CouplingLayerHINT`](@ref), [`CouplingLayerSLIM`](@ref), [`get_params`](@ref), [`clear_grad!`](@ref)
"""
struct ConditionalLayerSLIM <: NeuralNetLayer
    CL_X::CouplingLayerHINT
    CL_Y::CouplingLayerHINT
    CL_XY::CouplingLayerSLIM
    C_X::Conv1x1
    C_Y::Conv1x1
    Op::Union{AbstractMatrix, Any}
    forward::Function
    inverse::Function
    backward::Function
    forward_Y::Function
    inverse_Y::Function
end

# Constructor from input dimensions
function ConditionalLayerSLIM(nx1::Int64, nx2::Int64, nx_in::Int64, nx_hidden::Int64, ny1::Int64, ny2::Int64, ny_in::Int64, ny_hidden::Int64,
    batchsize::Int64, Op::Union{AbstractMatrix, Any}; k1=4, k2=3, p1=0, p2=1)

    # Create basic coupling layers
    CL_X = CouplingLayerHINT(nx1, nx2, nx_in, nx_hidden, batchsize; k1=k1, k2=k2, p1=p1, p2=p2, logdet=true)
    CL_Y = CouplingLayerHINT(Int(ny1/2), Int(ny2/2), Int(ny_in*4), ny_hidden, batchsize; k1=k1, k2=k2, p1=p1, p2=p2, logdet=true)
    CL_XY = CouplingLayerSLIM(nx1, nx2, nx_in, nx_hidden, batchsize, identity; k1=k1, k2=k2, logdet=true, permute=false)
    
    # Permutation using 1x1 convolution
    C_X = Conv1x1(nx_in)
    C_Y = Conv1x1(Int(ny_in*4))

    return ConditionalLayerSLIM(CL_X, CL_Y, CL_XY, C_X, C_Y, Op,
        (X, Y) -> forward_cond_irim(X, Y, CL_X, CL_Y, CL_XY, C_X, C_Y, Op),
        (Zx, Zy) -> inverse_cond_irim(Zx, Zy, CL_X, CL_Y, CL_XY, C_X, C_Y, Op),
        (ΔZx, ΔZy, Zx, Zy) -> backward_cond_irim(ΔZx, ΔZy, Zx, Zy, CL_X, CL_Y, CL_XY, C_X, C_Y, Op),
        Y -> forward_cond_irim_Y(Y, CL_Y, C_Y),
        Zy -> inverse_cond_irim_Y(Zy, CL_Y, C_Y)
        )
end

function forward_cond_irim(X, Y, CL_X, CL_Y, CL_XY, C_X, C_Y, Op)

    # Y-lane: coupling
    Ys = wavelet_squeeze(Y)
    Yp = C_Y.forward(Ys)
    Zy, logdet2 = CL_Y.forward(Yp)
    Zy = wavelet_unsqueeze(Zy)

    # X-lane
    Xp = C_X.forward(X)
    X, logdet1 = CL_X.forward(Xp)
    Zx, logdet3 = CL_XY.forward(X, Op, reshape(Y, :, size(Y, 4)))

    logdet = logdet1 + logdet2 + logdet3
    return Zx, Zy, logdet
end

function inverse_cond_irim(Zx, Zy, CL_X, CL_Y, CL_XY, C_X, C_Y, Op)

    # Y-lane
    Zy = wavelet_squeeze(Zy)
    Yp = CL_Y.inverse(Zy)
    Ys = C_Y.inverse(Yp)
    Y = wavelet_unsqueeze(Ys)

    # X-lane
    X = CL_XY.inverse(Zx, Op, reshape(Y, :, size(Y, 4)))
    Xp = CL_X.inverse(X)
    X = C_X.inverse(Xp)

    return X, Y
end

function backward_cond_irim(ΔZx, ΔZy, Zx, Zy, CL_X, CL_Y, CL_XY, C_X, C_Y, Op)

    # Y-lane
    ΔZy = wavelet_squeeze(ΔZy)
    Zy = wavelet_squeeze(Zy)
    ΔYp, Yp = CL_Y.backward(ΔZy, Zy)
    ΔYs, Ys = C_Y.inverse((ΔYp, Yp))
    Y = wavelet_unsqueeze(Ys)
    ΔY = wavelet_unsqueeze(ΔYs)

    # X-lane
    ΔX, X = CL_XY.backward(ΔZx, Zx, Op, reshape(Y, :, size(Y, 4)))
    ΔXp, Xp = CL_X.backward(ΔX, X)
    ΔX, X = C_X.inverse((ΔXp, Xp))

    return ΔX, ΔY, X, Y
end

function forward_cond_irim_Y(Y, CL_Y, C_Y)
    Ys = wavelet_squeeze(Y)
    Yp = C_Y.forward(Ys)
    Zy, logdet2 = CL_Y.forward(Yp)
    Zy = wavelet_unsqueeze(Zy)
    return Zy
end

function inverse_cond_irim_Y(Zy, CL_Y, C_Y)
    Zy = wavelet_squeeze(Zy)
    Yp = CL_Y.inverse(Zy)
    Ys = C_Y.inverse(Yp)
    Y = wavelet_unsqueeze(Ys)
    return Y
end

# Clear gradients
function clear_grad!(CI::ConditionalLayerSLIM)
    clear_grad!(CI.CL_X)
    clear_grad!(CI.CL_Y)
    clear_grad!(CI.CL_XY)
    clear_grad!(CI.C_X)
    clear_grad!(CI.C_Y)
end

# Get parameters
function get_params(CI::ConditionalLayerSLIM)
    p = get_params(CI.CL_X)
    p = cat(p, get_params(CI.CL_Y); dims=1)
    p = cat(p, get_params(CI.CL_XY); dims=1)
    p = cat(p, get_params(CI.C_X); dims=1)
    p = cat(p, get_params(CI.C_Y); dims=1)
end