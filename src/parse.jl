# vim:set ft=julia ts=4 sw=4 sts=4 autoindent:

# Convenience functions for syntactic parsing.
#
# Author:   Pontus Stenetorp    <pontus stenetorp se>
# Version:  2014-05-07

module Parse

export isequal, parse, train

import Base.isequal

require("conllx.jl")
require("dep.jl")
require("hybrid.jl")

using CoNLLX
using DepGraph
using Hybrid

function parse(sent::Sentence, predict::Function, coder)
    conf = config(sent, coder)
    while !isterminal(conf)
        trans = predict(conf)
        apply!(conf, trans)
    end

    return sentence(conf.graph, coder)
end

# TODO: Is it a good idea to override these?
# TODO: This is really a parsing specifing `isequal` implementation.
function isequal(a::Token, b::Token)
    return (a.id == b.id && a.form == b.form && a.head == b.head
        && a.deprel == b.deprel)
end

function isequal(a::Sentence, b::Sentence)
    # TODO: Prettify using map etc.
    if length(a) != length(b)
        return false
    end

    for (ae, be) in zip(a, b)
        if !isequal(ae, be)
            return false
        end
    end

    return true
end

# A uniform [-0.001, 0.001) distribution, we use this for the weight vector
#   initialisation since we don't know the number of features before-hand.
function uniforminit(w; offset=1)
    togen = length(w) - (offset - 1)
    # TODO: Could this be done more efficiently?
    w[offset:end] = (2 * rand(togen) .- 1) / 1000
end

function evaluate(weights, featids, trans, conf)
    # Apply the transition.
    undo = apply!(conf, trans)

    # Featurise the resulting configuration.
    featrows = Int[]
    feats = featurise(conf)
    for feat in feats
        featid = get!(featids, feat, length(featids) + 1)
        push!(featrows, featid)
    end

    # Revert to the original configuration.
    undo!(conf, undo)

    numfeats = length(featids)

    feats = sparsevec(featrows,
        # TODO: USE spones... somehow...
        ones(Float64, length(featrows)), numfeats)

    # Extend the weight vector if we observed new features.
    if length(weights) != numfeats
        oldsize = length(weights)
        resize!(weights, numfeats)
        uniforminit(weights, offset=oldsize+1)
    end

    # TODO: Which one is faster?
    #score = (weights.' * feats)[1]
    score = (feats.' * weights)[1]

    return (score, feats)
end

function trainpred(weights, featids, transs, conf)
    goldtrans = oracle(conf)
    legaltranss = collect(filter(t -> islegal(conf, t), transs))

    if length(legaltranss) == 1
        besttrans = legaltranss[1]
        # There is only one possibly transition, use it.
        return (goldtrans, nothing, besttrans, nothing)
    end

    # TODO: Can this be made prettier and type stable?
    besttrans = nothing
    bestscore = -Inf
    bestfeats = nothing
    goldscore = nothing
    goldfeats = nothing

    for trans in legaltranss
        score, feats = evaluate(weights, featids, trans, conf)

        if !isequal(trans, goldtrans)
            # Add the margin.
            # TODO: Extract into an argument.
            score += 1
        else
            goldscore = score
            goldfeats = feats
        end

        if score > bestscore
            besttrans = trans
            bestscore = score
            bestfeats = feats
        end
    end

    return (goldtrans, goldfeats, besttrans, bestfeats)
end

const EARLYUPDATES = false

# TODO: Given which arguments?
# TODO: Should use an iterator.
function train(sents::Sentences, epochs)
    #println("Training:")
    codes = coder()
    weights = Float64[0.0]
    uniforminit(weights)
    featids = Dict{FeatStruct, Uint}()
    # TODO: Use sizehint.
    #sizehint(featids, XXX)
    transs = transitions()

    for epoch in 1:epochs
        # Shuffle the sentences for each pass.
        shuffle!(sents)
        # TODO: Minibatches.
        for sent in sents
            # Parse the sentence.
            conf = config(sent, codes)
            while !isterminal(conf)
                goldtrans, goldfeats, besttrans, bestfeats = trainpred(
                    weights, featids, transs, conf)

                if !isequal(besttrans, goldtrans)
                    # Update the weight vector (perceptron update).
                    rows, _, vals = findnz(goldfeats)
                    weights[rows] += vals
                    rows, _, vals = findnz(bestfeats)
                    weights[rows] -= vals
                end

                if EARLYUPDATES
                    # Skip to the next sentence.
                    break
                else
                    # Proceed along the gold path.
                    # TODO: Could use a dynamic oracle for exploration.
                    apply!(conf, goldtrans)
                end
            end
        end
    end
end

end
