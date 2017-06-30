#' Quicker procedures for PopVar
#'
#' @description
#' Calculates the expected mean, genetic variance, and superior progeny mean of a bi-parental population
#' based on genomewide marker effects.
#'
#' @param G.in TBD
#' @param y.in TBD
#' @param map.in TBD
#' @param crossing.table TBD
#' @param parents TBD
#' @param tail.p TBD
#' @param model TBD
#' @param map.function TBD
#'
#' @examples
#'
#'
#'
#' @import dplyr
#' @importFrom qtl sim.cross mf.h mf.k mf.m mf.cf map2table
#' @importFrom tidyr gather
#' @importFrom purrr map pmap
#' @importFrom Matrix bdiag
#'
#' @export
#'
pop_predict_quick <- function(G.in, y.in, map.in, crossing.table, parents, tail.p, model = c("RRBLUP"),
                              map.function = c("haldane", "kosambi", "cf", "morgan")) {

  # Check the number of markers in the map and the G.in objects
  if (ncol(G.in) != nrow(map.in))
    stop("The number of markers in G.in does not match the markers in map.in")

  # Does the G.in object have names?
  if (any(sapply(dimnames(G.in), is.null)) )
    stop("The G.in input must have rownames (entries) and colnames(marker names).")

  # Are the markers in the G.in object in the map.object?
  if (any(!colnames(G.in) %in% map.in[,1]))
    stop("The marker names in G.in are not all in map.in.")

  # If the crossing table is not missing, check that the parents are in the G.in input
  if (!missing(crossing.table)) {
    parents <- crossing.table %>%
      unlist() %>%
      unique() %>%
      sort()

  } else {
    if (missing(parents))
      stop("If no crossing.table is provided, a list of parents must be supplied.")

    parents <- sort(parents)

  }

  if (any(!parents %in% row.names(G.in)))
    stop("Parents are not in the G.in input.")

  # Match arguments
  model <- match.arg(model)
  map.function <- match.arg(map.function)

  ## Filter and sort

  # Sort the phenotype df
  y.in_sort <- y.in[order(y.in[,1]), ,drop = FALSE]

  # Filter any entries without genotype data from the phenotype matrix
  y.in_use <- y.in_sort[as.character(y.in[,1]) %in% row.names(G.in), ,drop = FALSE] %>%
    data.frame(row.names = .[,1], stringsAsFactors = FALSE)

  # Sort the genotype matrix on the marker order in the map
  G.in_use <- G.in[, as.character(map.in[,1]), drop = FALSE]

  # Extract a genotype matrix for prediction
  G.in_pred <- G.in_use[as.character(y.in_use[,1]), , drop = FALSE]

  ## Get the names of things
  marker_names <- colnames(G.in_use)
  traits <- colnames(y.in_use)[-1]
  entries <- row.names(G.in_use)

  ### Execute genomic prediction for each trait

  if (model == "RRBLUP") {

    mar_eff_mat <- y.in_use[,-1,drop = FALSE] %>%
      apply(MARGIN = 2, FUN = function(y) {

        solve_out <- mixed.solve(y = y, Z = G.in_pred, method = "REML")

        # Return marker effects
        as.matrix(solve_out$u) }) %>%
      structure(dimnames = list(marker_names, traits))

  } else {
    stop("Other models not supported.")
  }

  # Predict the genotypic value of the parents
  G.in_parent <- G.in_use[parents, , drop = FALSE]

  parent_pgv <- mar_eff_mat %>%
    apply(MARGIN = 2, FUN = function(u) G.in_parent %*% u ) %>%
    data.frame(entry = parents, ., stringsAsFactors = FALSE)


  # Combine marker name, position, and effect, then sort on chromosome and position
  mar_specs <- cbind(map.in, mar_eff_mat) %>%
    .[order(.[,2], .[,3]),] %>%
    data.frame(row.names = .[,1], stringsAsFactors = FALSE)

  # Calculate additive variance of all markers (assuming p = q = 0.5)
  mar_var_base <-  mar_specs %>%
    select(-1:-3) %>%
    as.matrix() %>%
    {. ^ 2}


  ## Functions for covariance
  # Intra-trait covariance

  # First create a matrix of marker distances
  pairwise_dist <- map.in %>%
    split(map.in[,2]) %>%
    map(function(chr_map) {
      cM <- matrix(chr_map[,3], dimnames = list(chr_map[,1], "pos"))
      sapply(X = cM[,1], FUN = function(pos) abs(pos - cM[,1]), simplify = TRUE) })

  # Convert to recombination rates and then use that to calculate the expected
  # disequilibrium
  pairwise_D <- pairwise_dist %>%
    map(function(chr_dist)
      switch(map.function,
             haldane = qtl::mf.h(chr_dist),
             kosambi = qtl::mf.k(chr_dist),
             cf = qtl::mf.cf(chr_dist),
             morgan = qtl::mf.m(chr_dist)) ) %>%
    map(function(c_ij) ((1 - (2 * c_ij)) / (1 + (2 * c_ij))) ) %>%
    # Change diagonals to 0
    map(`diag<-`, 0)

  # Calculate the pairwise product of all marker effects
  # Split by chromosome
  pairwise_eff_prod <- mar_specs %>%
    # Split by chromosome
    split(.[,2]) %>%
    map(select, -1:-3) %>%
    map(function(mar_chr)
      apply(X = mar_chr, MARGIN = 2, FUN = function(mar_chr_trait)
        list(structure(tcrossprod(mar_chr_trait),
                  dimnames = list(row.names(mar_chr), row.names(mar_chr)))) )) %>%
    # Remove listing structure
    map(lapply, "[[", 1)

  # Reconfigure list so traits are upper level
  pairwise_eff_prod1 <- map(traits, function(trait)
    lapply(pairwise_eff_prod, "[[", trait) ) %>%
    structure(names = traits)


  # Calculate covariance between pairs of markers for each trait
  mar_covar_base <- pairwise_eff_prod1 %>%
    map(function(u) pmap(list(u, pairwise_D), `*`) ) %>%
    map(.bdiag) %>%
    map(`dimnames<-`, list(marker_names, marker_names))

  # Now calculate the inter-trait covariance
  # Only proceed if there is more than one trait
  if (length(traits) > 1) {

    # Sample combinations of traits
    trait_combn <- combn(x = traits, m = 2)
    # Configure the trait names
    trait_combn_names <- apply(X = trait_combn, MARGIN = 2, FUN = paste, collapse = "_")
    trait_combn_df <- as.data.frame(t(trait_combn), stringsAsFactors = FALSE)

    pairwise_eff_prod <- mar_specs %>%
      # Split by chromosome
      split(.[,2]) %>%
      map(select, -1:-3) %>%
      map(as.matrix) %>%
      map(function(mar_chr) {
        # Calculate the pairwise product between the traits
        out <- apply(X = trait_combn, MARGIN = 2, FUN = function(ind) {
          mar_chr_ind <- mar_chr[,ind]
          list(structure(tcrossprod(x = mar_chr_ind[,1, drop = FALSE], y = mar_chr_ind[,2, drop = FALSE]),
                         dimnames = list(row.names(mar_chr), row.names(mar_chr)))) })

        # Add combine trait names
        structure(out, names = trait_combn_names) }) %>%
      # Remove listing structure
      map(lapply, "[[", 1)

    # Reconfigure list so traits are upper level
    pairwise_eff_prod1 <- map(trait_combn_names, function(trait)
      lapply(pairwise_eff_prod, "[[", trait) ) %>%
      structure(names = trait_combn_names)

    # Calculate the inter-trait covariance between pairs of markers
    # Combine chromosomes to form sparse matrices
    mar_trait_covar_base <- pairwise_eff_prod1 %>%
      map(function(u) pmap(list(u, pairwise_D), `*`) ) %>%
      map(.bdiag) %>%
      map(`dimnames<-`, list(marker_names, marker_names))

  }

  # Determine the k_sp from the the tail.p
  k_sp <- mean(qnorm(p = seq((1 - tail.p), 0.999999, 0.000001)))


  # Iterate over the parents in the crossing block
  predictions <- crossing.table %>%
    by_row(function(pars) {

      pars <- as.character(pars)

      # Extract parental genotypes
      par_geno <- G.in_parent[pars, , drop = FALSE]

      # Which markers are segregating?
      mar_seg <- names(which(colMeans(par_geno) == 0))

      # Find the parent 1 genotype of those markers and take the crossproduct for multiplication
      par1_mar_seg <- par_geno[1,mar_seg, drop = FALSE] %>%
        crossprod()

      # Subset the variance df for those markers
      mar_var <- mar_var_base[mar_seg,, drop = FALSE] %>%
        colSums()

      # Subset the covariance and multiply by the parent 1 genotypes
      # Sum then divide by 2 to get the covariance
      mar_covar <- mar_covar_base %>%
        lapply("[", mar_seg, mar_seg) %>%
        map(`*`, par1_mar_seg) %>%
        map(sum) %>%
        map(`/`, 2)

      # Combine the marker variance and covariance
      pred_varG <- mar_var + 2 * as.numeric(mar_covar)

      # Calculate the mean PGV based on the markers
      pred_mu <- subset(parent_pgv, entry %in% pars, -entry) %>%
        colMeans()

      # Add predicted variance
      results <- data.frame(trait = traits,
                            pred_mu = pred_mu,
                            pred_varG = pred_varG,
                            row.names = NULL, stringsAsFactors = FALSE)

      # If there is more than one trait, predict the genetic correlation
      if (length(traits) > 1) {

        # Calculate the genetic covariance
        trait_covar <- mar_trait_covar_base %>%
          lapply("[", mar_seg, mar_seg) %>%
          map(`*`, par1_mar_seg) %>%
          map(sum) %>%
          map(`/`, 2)

        # Iterate over trait combinations
        pred_cor <- apply(X = trait_combn, MARGIN = 2, FUN = function(trs) {
          # Create a trait combination
          trs_name <- paste(trs, collapse = "_")
          # Extract the predicted variances
          trs_pred_varG <- subset(x = results, subset = traits %in% trs, pred_varG, drop = TRUE)
          # Extract the covariance and calculate the predicted correlation
          trait_covar[[trs_name]] / sqrt(prod(trs_pred_varG)) })

        # Create a df with the trait combinations and correlations
        pred_cor_df <- trait_combn_df %>%
          mutate(pred_cor = pred_cor) %>%
          bind_rows(., mutate(., V1 = V2, V2 = .$V1)) %>%
          mutate(V2 = paste("cor", V2, sep = "_")) %>%
          spread(V2, pred_cor)

        # Combine with results
        results1 <- results %>%
          full_join(., pred_cor_df, by = c("trait" = "V1"))

      } else {

        results1 <- results

      }

      # Return the results
      return(results1) }, .collate = "rows") %>%
    select(-`.row`)

  # Calculate superior progeny means
  predictions %>%
    mutate(pred_mu_sp_high = pred_mu + (k_sp * pred_varG),
           pred_mu_sp_low = pred_mu - (k_sp * pred_varG)) %>%
    select(Par1, Par2, trait, pred_mu, pred_varG, pred_mu_sp_high, pred_mu_sp_low, names(.))

} # Close the function
