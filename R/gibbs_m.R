#' Gibbs sampler
#' @useDynLib RSTr, .registration = TRUE
#' @importFrom Rcpp evalCpp
#' @importFrom RcppDist bayeslm
#' @importFrom RcppArmadillo fastLm
#'
#' @noRd
gibbs_m = function(name, dir, .show_plots, .discard_burnin) {
  data = readRDS(paste0(dir, name, "/data.Rds"))
  Y    = data$Y
  n    = data$n
  miss = which(!is.finite(Y))

  spatial_data = readRDS(paste0(dir, name, "/spatial_data.Rds"))
  adjacency     = spatial_data$adjacency
  num_adj       = spatial_data$num_adj
  island_region = spatial_data$island_region
  island_id     = spatial_data$island_id
  num_island    = spatial_data$num_island

  priors = readRDS(paste0(dir, name, "/priors.Rds"))
  G_scale  = priors$G_scale
  G_df     = priors$G_df
  tau_a    = priors$tau_a
  tau_b    = priors$tau_b
  theta_sd = priors$theta_sd
  t_accept = priors$t_accept

  inits = readRDS(paste0(dir, name, "/inits.Rds"))
  theta = inits$theta
  beta  = inits$beta
  Z     = inits$Z
  G     = inits$G
  tau2  = inits$tau2

  params = readRDS(paste0(dir, name, "/params.Rds"))
  total  = params$total
  method = params$method
  impute_lb = params$impute_lb
  impute_ub = params$impute_ub
  start_batch = params$batch

  plots = output = vector("list", length(inits))
  names(plots) = names(output) = par_up = names(inits)
  for (batch in start_batch:60) {
    time = format(Sys.time(), "%a %b %d %X")
    cat("Batch", paste0(batch, ","), "Iteration", paste0(total, ","), time, "\r")
    T_inc = 100
    output$theta = array(dim = c(dim(theta)  , T_inc / 10))
    output$beta  = array(dim = c(dim(beta)   , T_inc / 10))
    output$G     = array(dim = c(dim(G)      , T_inc / 10))
    output$tau2  = array(dim = c(length(tau2), T_inc / 10))
    output$Z     = array(dim = c(dim(Z)      , T_inc / 10))

    # Metropolis for Yikt
    t_accept = ifelse(t_accept < 1 / 6, 1 / 6, ifelse(t_accept > 0.75, 0.75, t_accept))
    theta_sd = ifelse(
      t_accept > 0.5,
      theta_sd * t_accept / 0.5,
      ifelse(t_accept < 0.35, theta_sd * t_accept / 0.35, theta_sd)
    )
    t_accept = array(0, dim = dim(theta))
    for(it in 1:T_inc) {
      #### impute missing Y's ####
      if (length(miss)) {
        if (method == "binom") {
          rate = expit(theta[miss])
          rp = stats::runif(
            length(miss),
            stats::pbinom(impute_lb - 0.1, round(n[miss]), rate),
            stats::pbinom(impute_ub + 0.1, round(n[miss]), rate)
          )
          Y[miss] = stats::qbinom(rp, round(n[miss]), rate)
        }
        if (method == "pois") {
          rate = n[miss] * exp(theta[miss])
          rp = stats::runif(
            length(miss),
            stats::ppois(impute_lb - 0.1, rate),
            stats::ppois(impute_ub + 0.1, rate)
          )
          Y[miss] = stats::qpois(rp, rate)
        }
      }

      # Sample beta
      beta = m_update_beta(beta, theta, Z, tau2, island_region)

      # Sample Z
      Z = m_update_Z(Z, G, theta, beta, tau2, adjacency, num_adj, island_region, island_id)

      # Sample G
      G = m_update_G(G, Z, G_df, G_scale, adjacency, num_island)

      ## Sample tau2
      tau2 = m_update_tau2(tau2, theta, beta, Z, tau_a, tau_b, island_id)

      # Sample theta
      theta = m_update_theta(theta, t_accept, Y, n, Z, beta, tau2, theta_sd, island_id, method)

      #### Save outputs ####
      if (it %% 10 == 0) {
        output$beta [, , it / 10] = beta
        output$G    [, , it / 10] = G
        output$tau2 [,   it / 10] = tau2
        output$theta[, , it / 10] = theta
        output$Z    [, , it / 10] = Z
      }
      cat("Batch", paste0(batch, ","), "Iteration", paste0(total + it, ","), time, ifelse(it == T_inc, "\n", "\r"))
    }

    # modify meta-parameters, save outputs to respective files
    total = total + T_inc
    t_accept = t_accept / T_inc
    inits = list(
      theta = theta,
      beta = beta,
      Z = Z,
      G = G,
      tau2 = tau2
    )
    priors$theta_sd = theta_sd
    priors$t_accept = t_accept
    params$total = total
    params$batch = batch
    saveRDS(params, paste0(dir, name, "/params.Rds"))
    saveRDS(priors, paste0(dir, name, "/priors.Rds"))
    saveRDS(inits,  paste0(dir, name, "/inits.Rds"))
    # saveRDS(output$beta , paste0(dir, name, "/beta/" , "beta_out_" , batch, ".Rds"))
    # saveRDS(output$theta, paste0(dir, name, "/theta/", "theta_out_", batch, ".Rds"))
    # saveRDS(output$Z    , paste0(dir, name, "/Z/"    , "Z_out_"    , batch, ".Rds"))
    # saveRDS(output$G    , paste0(dir, name, "/G/"    , "G_out_"    , batch, ".Rds"))
    # saveRDS(output$tau2 , paste0(dir, name, "/tau2/" , "tau2_out_" , batch, ".Rds"))
    save_output(output, batch, dir, name, .discard_burnin)
    if (.show_plots) {
      # Output some of the estimates for plotting purposes
      plots$beta  = c(plots$beta,  output$beta [1, 1, ])
      plots$theta = c(plots$theta, output$theta[1, 1, ])
      plots$Z     = c(plots$Z,     output$Z    [1, 1, ])
      plots$tau2  = c(plots$tau2,  output$tau2 [1,    ])
      plots$G     = c(plots$G,     output$G    [1, 1, ])

      grid = c(2, 3)
      graphics::par(mfrow = grid)
      burn = min(floor(total / 20), 200)
      its  = burn:(total / 10)
      plot(its * 10, plots$theta[its], type = "l", main = "theta")
      plot(its * 10, plots$beta[its], type = "l", main = "beta")
      plot(its * 10, plots$tau2[its], type = "l", main = "tau2")
      plot(its * 10, plots$G[its], type = "l", main = "G")
      plot(its * 10, plots$Z[its], type = "l", main = "Z")
    }

  }
  cat("Finished running model at:", format(Sys.time(), "%a %b %d %X"))
}
