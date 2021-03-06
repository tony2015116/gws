% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/create_model_matrices.R
\name{fixef_model_matrix}
\alias{fixef_model_matrix}
\title{Create a fixed effect incidence matrix}
\usage{
fixef_model_matrix(fixed, data, sparse = TRUE)
}
\arguments{
\item{fixed}{A \code{formula} specifying the the response variable and the
fixed effect terms of the linear mixed-model. Must take the form \code{response
~ predictor(s)}.}

\item{data}{A \code{data.frame} that includes the response and fixed effect
predictors. If not supplied, the function will look in the current running
environment.}
}
\value{
A model matrix.
}
\description{
Creates an incidence matrix for the fixed effects of a mixed-model. This is a
very thin wrapper around \code{\link[model.matrix]{stats}}.
}
