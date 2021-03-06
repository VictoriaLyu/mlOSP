% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/ospSeqDesign.R
\name{osp.seq.design}
\alias{osp.seq.design}
\title{Sequential design for optimal stopping}
\usage{
osp.seq.design(model, method = "km")
}
\arguments{
\item{method:}{one of \code{km}, \code{trainkm}, \code{homtp} or \code{hetgp} to select the GP emulator to apply}
}
\value{
a list containing:
\itemize{
\item \code{fit} a list of fitted response surfaces.
\item \code{timeElapsed},
\item \code{nsims} total number of 1-step sim.func calls
\item \code{budget} -- number of sequential iterations per time-step
\item \code{empLoss} --matrix of empirical losses (rows for time-steps, columns for iterations)
\item \code{theta.fit} -- 3d array of estimated lengthscales (sorted by time-steps,iterations,dimensions-of-x)
}
}
\description{
Sequential design for optimal stopping
}
\details{
Implements the EI strategy defined in model/ei.func. Calls \code{lhs} from library \pkg{tgp}.
Empirical losses are computed using \code{cf.el} function. The acquisition function is specified via
\code{ei.func} which can be \code{csur} (Default), \code{sur}, \code{smcu}, \code{amcu},
\code{tmse} and \code{icu}.
}
