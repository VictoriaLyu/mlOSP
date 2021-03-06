#############################
#' RMC using probabilistic design: backpropagation along fixed set of paths (a la Longstaff-Schwartz)
#' All designs are kept in memory
#' @title Longstaff-Schwartz algorithm with a variety of regression methods
#' @param N is the number of paths
#' @param subset To have out-of-sample paths, specify \code{subset} (eg 1:1000) to use for testing.
#' By default everything is in-sample
#' @param method a string specifying regression method to use
#' \itemize{
#'  \item spline: \code{smooth.spline} from \pkg{base} which only works \emph{in 1D}
#'  \item randomforest: (from \pkg{randomForest} package) requires \code{rf.maxnode}
#'  and \code{rf.ntree} (number of trees) model parameters
#'  \item loess: only works in \emph{1D or 2D}, requires \code{lo.span} model parameter
#'  \item earth: multivariate regression splines (MARS) using \pkg{earth} package.
#'  requires \code{earth.deg} (interaction degree), \code{earth.nk} (max number of terms to keep),
#'  \code{earth.thresh} params
#'  \item rvm: relevance vector machine from \pkg{kernlab} package. Optional \code{rvm.kernel}
#'  model parameter to decide which kernel family to utilize
#'  \item lm: linear global regression using \code{model$bases} basis functions (+ constant)
#'  }
#' @export
#' @return a list containing
#' \itemize{
#' \item \code{fit} a list containing all the models generated at each time-step. \code{fit[[1]]} is the emulator
#' at \eqn{t=\Delta t}, the last one is \code{fit[[M-1]]} which is emulator for \eqn{T-\Delta t}.
#' \item \code{val}: the in-sample pathwise rewards
#' \item \code{test}: the out-of-sample pathwise rewards
#' \item \code{p}: the final price (2-vector for in/out-of-sample)
#' \item \code{timeElapsed} (based on \code{Sys.time})
#' }
#' @details
#'  Works with a probabilistic design that requires storing all paths in memory. Specifying \code{subset}
#'  allows to compute in parallel with the original computation an out-of-sample estimate of the value function

###############################
osp.prob.design <- function(N,model,subset=1:N,method="spline")
{
  M <- model$T/model$dt
  grids <- list()
  all.models <- list()

  # divide into in-sample and out-of-sample
  if (length(subset) < N)
    train <- (1:N)[-subset]
  else
    train <- 1:N

  # Build the designs based on a simulation of X_{1:T}
  if (length(model$x0) == model$dim)
     grids[[1]] <- model$sim.func( matrix(rep(model$x0, N), nrow=N,byrow=T), model, model$dt)
  else if (length(model$x0) == N*model$dim)
     grids[[1]] <- model$sim.func( matrix(rep(model$x0, N), nrow=N,byrow=T), model, model$dt)
  else
    warning("Length of the initial condition which must match N")
  for (i in 2:M)
    grids[[i]] <- model$sim.func( grids[[i-1]], model, model$dt)

  # initialize at T
  contValue <- exp(-model$r*model$dt)*option.payoff( grids[[M]], model$K)
  tau <- rep(model$T, N)
  t.start <- Sys.time()

  # Backward stepping in time
  # Estimate T(t,x)
  for (i in (M-1):1)
  {
    # forward predict
    immPayoff <- option.payoff(grids[[i]],model$K)
    c.train <- train[which(immPayoff[train] > 0)]
    yVal <- contValue[c.train]-immPayoff[c.train]

    if (method == "spline" & ncol(grids[[i]]) == 1) { # only works in 1D
      all.models[[i]] <- smooth.spline( x=grids[[i]][c.train],y=yVal,
                                        nknots = model$nk)
      timingValue <- predict(all.models[[i]],grids[[i]])$y
    }

    if (method == "randomforest") {
      all.models[[i]] <-  randomForest(x=grids[[i]][c.train,,drop=F],y=yVal,
                                       ntree=model$rf.ntree,replace=F,maxnode=model$rf.maxnode)
      timingValue <- predict(all.models[[i]],grids[[i]],predict.all=T)$individual
      stopProb <- apply( (timingValue < 0), 1, sum)/model$rf.ntree
      timingValue <- apply(timingValue,1,median)
    }

    if (method == "loess" & ncol(grids[[i]]) <= 2) { # LOESS only works in 1D or 2D
        if (ncol(grids[[i]]) == 1) {
          all.models[[i]] <- loess(y ~ x, data.frame(x=grids[[i]][c.train], y=yVal),
                                 span=model$lo.span, control = loess.control(surface = "direct"))
          stopProb <- predict(all.models[[i]], data.frame(x=grids[[i]]),se=TRUE)
        }
        if (ncol(grids[[i]]) ==2) {
          all.models[[i]] <- loess(y ~ x1+x2, data.frame(x1=grids[[i]][c.train,1], x2=grids[[i]][c.train,2], y=yVal),
                                   span=model$lo.span, control = loess.control(surface = "direct"))
          stopProb <- predict(all.models[[i]], new=data.frame(x1=grids[[i]][,1],x2=grids[[i]][,2]))
        }
        timingValue <- stopProb$fit
        stopProb <- 1-pnorm( (stopProb$fit)/stopProb$se)
    }
    if (method == "earth") {  # Multivariate Adaptive Regression Splines
       all.models[[i]] <- earth(x=grids[[i]][c.train,,drop=F],y=yVal,
                                degree=model$earth.deg,nk=model$earth.nk,thresh=model$earth.thresh)
       timingValue <- predict(all.models[[i]],grids[[i]])
    }

    if (method =="lm") {  # Linear regression with specified basis functions
      matb <- model$bases(grids[[i]][c.train,,drop=F])
      all.models[[i]] <- lm(yVal ~ matb)
      lenn <- length(all.models[[i]]$coefficients)
      timingValue <-  all.models[[i]]$coefficients[1] +
        model$bases(grids[[i]]) %*% all.models[[i]]$coefficients[2:lenn]
    }
    if (method =="rvm") {   # Relevance Vector Machine Regression
      if (is.null(model$rvm.kernel))
          rvmk <- "rbfdot"
      else
          rvmk <- model$rvm.kernel
      rvModel <- rvm(x=grids[[i]][c.train], y=yVal,kernel=rvmk)
      timingValue <- predict(rvModel, new=grids[[i]])
    }

    # paths on which stop right now
    stopNdx <- which( timingValue <= 0 & immPayoff > 0)
    contValue[stopNdx] <- immPayoff[stopNdx]
    tau[stopNdx] <- i*model$dt

    # else continue and discount
    contValue <- exp(-model$r*model$dt)*contValue
  }

  # in/sample and out-of-sample average at x0
  price <- c(mean(contValue[train]),mean(contValue[subset]))
  print(sprintf("in-sample v_0 %3f; and out-of-sample: %3f", price[1], price[2]))

  # returns a list containing
  # fit are all the models generated at each time-step, stored as a list
  # p is the final price (2-vector for in/out-of-sample)
  # val are the in-sample pathwise rewards
  # test are the out-of-sample pathwise rewards
  # timeElapsed: total running time
  return( list(fit=all.models,p=price, val=contValue[train], test=contValue[subset],
               timeElapsed=Sys.time()-t.start))
}


####################################
#' Batched non-adaptive design with a variety of regression methods
#'
#' @title Generic dynamic emulation with a non-sequential design
#' @param input.domain: the domain of the emulator. Several options are available. Default in \code{NULL}
#' All the empirical domains rely on pilot paths generated using \code{pilot.nsims}>0 model parameter.
#' \itemize{
#' \item  NULL will use an empirical design (default);
#' \item if a vector of length 2*model$dim then specifies the bounding rectangle
#' \item a single positive number, then build a bounding rectangle based on the \eqn{\alpha}-quantile of the pilot paths
#' \item a single negative number, then build a bounding rectangle based on the full range of the pilot paths
#' \item a vector specifies the precise design, used as-is (\emph{overrides design size})
#' }
#' @param method: regression method to use (defaults to \code{km})
#' \itemize{
#' \item km: Gaussian process with fixed hyperparams  uses \pkg{DiceKriging} via \code{km} (default)
#' \item trainkm: GP w/trained hyperparams: use \pkg{DiceKriging} via \code{km}
#' \item lagp Local GP: use \pkg{laGP}
#' \item homgp Homoskedastic GP: use \pkg{hetGP} with  \code{mleHomGP}
#' \item hetgp Heteroskedastic GP: use \pkg{hetGP} with \code{mleHetGP}
#' \item spline: Smoothing Splines, use \code{smooth.spline}
#' \item loess: Local Regression: use \code{loess} with \code{lo.span} parameter
#' \item rvm: Relevance Vector Machine: use \pkg{kernlab} with \code{rvm}
#' \item lm: linear model from \pkg{stats}
#' }
#' @param inTheMoney.thresh: which paths are kept, out-of-the-money is dropped.
#' Defines threshold in terms of \code{option.payoff}
#' @return a list containing:
#' \itemize{
#' \item \code{fit} a list containing all the models generated at each time-step. \code{fit[[1]]} is the emulator
#' at \eqn{t=\Delta t}, the last one is \code{fit[[M-1]]} which is emulator for \eqn{T-\Delta t}.
#' \item \code{val}: the in-sample pathwise rewards
#' \item \code{test}: the out-of-sample pathwise rewards
#' \item \code{p}: the final price (2-vector for in/out-of-sample)
#' \item \code{timeElapsed} (based on \code{Sys.time})
#' }
#' @details The design can be replicated through \code{km.batch} model parameter. Replication allows to use
#' nonparametric techniques which would be too expensive otherwise, in particular LOESS, GP and RVM.
#' All designs are restricted to in-the-money region, see \code{inTheMoney.thresh} parameter (modify at your own risk)
#' Thus, actual design size will be smaller than specified. By default, no forward evaluation is provided, ie the
#' method only builds the emulators. Thus, to obtain an actual estimate of the value
#' combine with \code{\link{forward.sim.policy}}
#' @export
osp.fixed.design <- function(model,input.domain=NULL, method ="km",inTheMoney.thresh = 0)
{
  M <- model$T/model$dt
  t.start <- Sys.time()

  fits <- list()   # list of fits at each step
  grids <- list()

  cur.sim <- 0

  # set-up pilot design using a forward simulation of X
  if (model$pilot.nsims > 0) {
     grids[[1]] <- model$sim.func( matrix(rep(model$x0[1:model$dim], model$pilot.nsims),
                                       nrow=model$pilot.nsims, byrow=T), model, model$dt)
    for (i in 2:(M-1))
       grids[[i]] <- model$sim.func( grids[[i-1]], model, model$dt)
  grids[[1]] <- grids[[3]]
  cur.sim <- model$pilot.nsims
  }

  ############ step back in time
  design.size <- rep(0,M)

  for (i in (M-1):1) {
    # figure out design size -- this is the number of unique sites, before restricting to in-the-money
    if (length(model$N) == 1)
      design.size[i] <- model$N
    else
      design.size[i] <- model$N[i]

    #figure out batch size
    if (is.null(model$km.batch))
     n.reps <- 1
    else if (length(model$km.batch) == 1)
      n.reps <- model$km.batch
    else
      n.reps <- model$km.batch[i]

    if (is.null(input.domain))  {   # empirical design using simulated pilot paths
      init.grid <- grids[[i]]

      init.grid <- init.grid[sample(1:min(design.size[i],dim(init.grid)[1]), design.size[i], rep=F),,drop=F]
    }
    else if (length(input.domain)==2*model$dim | length(input.domain)==1) {
      # space-filling design over a rectangle
      if (length(input.domain) == 1){
        # specifies the box as empirical quantiles, should be 0.01. If zero then use the full range
        my.domain <- matrix( rep(0, 2*model$dim), ncol=2)
        if (input.domain > 0) {
           for (jj in 1:model$dim)
             my.domain[jj,] <- quantile( grids[[i]][,jj], c(input.domain, 1-input.domain))
        }
        else {
          for (jj in 1:model$dim)
             my.domain[jj,] <- range( grids[[i]][,jj] )
        }
      }
      else my.domain <- input.domain  #  user-specified box

      # now choose how to space-fill
      if (is.null(model$qmc.method)) {
        init.grid <- lhs( design.size[i], my.domain)
      }
      else {
        init.grid <- model$qmc.method( design.size[i], dim=model$dim)
        # rescale to the correct rectangle
        for (jj in 1:model$dim)
          init.grid[,jj] <- my.domain[jj,1] + (my.domain[jj,2]-my.domain[jj,1])*init.grid[,jj]

      }
    }
    else  {   # fixed pre-specified design
      init.grid <- matrix(input.domain,nrow=length(input.domain)/model$dim)
      design.size[i] <- nrow(init.grid)
    }

    init.grid <- init.grid[ option.payoff(init.grid, model$K) > inTheMoney.thresh,,drop=F]

    design.size[i] <- dim(init.grid)[1]
    all.X <- matrix( rep(0, (model$dim+2)*design.size[i]), ncol=model$dim+2)

    # construct replicated design
    big.grid <- matrix(rep(t(init.grid), n.reps), ncol = ncol(init.grid), byrow = TRUE)

    fsim <- forward.sim.policy( big.grid, M-i,fits[i:M],model,offset=0)
    immPayoff <- option.payoff( init.grid, model$K)
    cur.sim <- cur.sim + fsim$nsims

    # pre-averaged mean/variance
    for (jj in 1:design.size[i]) {
      all.X[jj,model$dim+1] <- mean( fsim$payoff[ jj + seq(from=0,len=n.reps,by=design.size[i])]) - immPayoff[ jj]
      all.X[jj,model$dim+2] <- var( fsim$payoff[ jj + seq(from=0,len=n.reps,by=design.size[i])])
    }

    all.X[,1:model$dim] <- init.grid  # use the first dim+1 columns for the batched GP regression.

    # create the km object
    if (n.reps > 10 & method == "km")
      fits[[i]] <- DiceKriging::km(y~0, design=data.frame(x=init.grid), response=data.frame(y=all.X[,model$dim+1]),
                                   noise.var=all.X[,model$dim+2]/n.reps, control=list(trace=F),
                                   coef.trend=0,coef.cov=model$km.cov, coef.var=model$km.var, covtype=model$covfamily)
    else if (method == "km")  # manually estimate the nugget for small batches
      fits[[i]] <- DiceKriging::km(y~0, design=data.frame(x=init.grid), response=data.frame(y=all.X[,model$dim+1]),
                                   control=list(trace=F), lower=rep(0.1,model$dim), coef.trend=0, coef.cov=model$km.cov, coef.var=model$km.var,
                                   nugget.estim=TRUE, nugget=sqrt(mean(all.X[,model$dim+2])), covtype=model$covfamily)
    else if (method =="trainkm")
      fits[[i]] <- DiceKriging::km(y~0, design=data.frame(x=init.grid), response=data.frame(y=all.X[,model$dim+1]),
                                   control=list(trace=F), lower=rep(0.1,model$dim), upper=model$km.upper,
                                   noise.var=all.X[,model$dim+2]/n.reps, covtype=model$covfamily)

    else if (n.reps < 10 & method == "lagp")  # laGP library implementation
      fits[[i]]  <- laGP::newGP(X=init.grid, Z=all.X[,model$dim+1],
                                d=list(mle=FALSE, start=model$km.cov), g=list(start=1, mle=TRUE))
    else if(method =="hetgp") {
      big.payoff <- option.payoff(big.grid,model$K)
      hetData <- find_reps(big.grid, fsim$payoff-big.payoff)
      fits[[i]] <- hetGP::mleHetGP(X = list(X0=hetData$X0, Z0=hetData$Z0,mult=hetData$mult), Z= hetData$Z,
                                   lower = rep(0.1,model$dim), upper = model$km.upper, covtype=model$covfamily)
      #ehtPred <- predict(x=check.x, object=hetModel)
    }
    else if (method =="homgp") {
      big.payoff <- option.payoff(big.grid,model$K)
      hetData <- hetGP::find_reps(big.grid, fsim$payoff-big.payoff)
      fits[[i]] <- hetGP::mleHomGP(X = list(X0=hetData$X0, Z0=hetData$Z0,mult=hetData$mult), Z= hetData$Z,
                                   lower = rep(0.1,model$dim), upper = model$km.upper, covtype=model$covfamily)
    }
    else if (model$dim == 1 & method=="spline")  # only possible in 1D
      fits[[i]] <- smooth.spline(x=init.grid,y=all.X[,2],knots=model$nk)
    else if (method == "rvm") {
        if (is.null(model$rvm.kernel))
          rvmk <- "rbfdot"
        else
          rvmk <- model$rvm.kernel
        fits[[i]] <- rvm(x=init.grid, y=all.X[,model$dim+1],kernel=rvmk)
    }

  }  # end of loop over time-steps

  return (list(fit=fits,timeElapsed=Sys.time()-t.start,nsims=cur.sim))
}


