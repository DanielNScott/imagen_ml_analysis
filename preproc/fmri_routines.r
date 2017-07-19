# ------------------------------------------------------------------------------ #
#                      Subroutine for reading the fmri data                      #
# ------------------------------------------------------------------------------ #
import_fmri <- function(subj_id, timeseries_dir, taskdata_dir, movement_dir) {

  # Set filename prefixes and suffixes
  task_pfx <- 'ss_'
  fmri_sfx <- paste('MaskDumpOutput',sep = '')
  move_pfx <- 'EPI_stop_'

  # Specify ordinal coding for trial outcome
  task_key  <- c("GO_SUCCESS" = "1", "GO_FAILURE" = '2', 'STOP_SUCCESS' = '3', 'STOP_FAILURE' = '4',
                 'GO_TOO_LATE' = '5','GO_WRONG_KEY_RESPONSE' = '6', 'STOP_TOO_EARLY_RESPONSE' = '7')

  # Convert subject id to padded string & read
  subj_id_str <- formatC(subj_id, width = 12, format = 'd', flag = '0')

  # Filename beurocracy...
  fmri_fname <- paste(subj_id_str, '_', fmri_sfx, sep = '')
  task_fname <- paste(task_pfx, subj_id_str, '.csv', sep = '')
  move_fname <- paste(move_pfx, subj_id_str, '.txt', sep = '')

  fmri_full_name <- paste(timeseries_dir, fmri_fname, sep = '')
  task_full_name <- paste(taskdata_dir  , task_fname, sep = '')
  move_full_name <- paste(movement_dir  , move_fname, sep = '')

  # Read the fmri activation series
  if (file.exists(fmri_full_name)) {
    activations <- read.csv(file = fmri_full_name, header = FALSE, sep = '')
    activations <- t(activations[,4:447]) # 1st 3 cols spurious, 444 TRs
    rownames(activations) <- NULL
    activations <- as.matrix(activations)

    print(paste('Successful read of ', fmri_fname))
  } else {
    print(paste('Failure to read ', fmri_fname))
    return
  }

  # Read the SST series
  if (file.exists(task_full_name)) {
    # Only want to read 2 columns, time and outcome
    cols <- c('NULL','NULL','numeric','NULL','NULL','NULL','NULL','NULL',
              'NULL','NULL','NULL'   , NA   ,'NULL','NULL','NULL','numeric')
    task_data <- read.csv(file = task_full_name, header = TRUE, sep = '\t', colClasses = cols, skip = 1)
    print(paste('Successful read of ', task_fname))
  } else {
    print(paste('Failure to read ', task_fname))
    return
  }

  # Reading the fmri series
  if (file.exists(move_full_name)) {
    movement <- read.csv(file = move_full_name, header = FALSE, sep = '')
    print(paste('Successful read of ', move_fname))
  } else {
    print(paste('Failure to read ', move_fname))
    return
  }

  # Req. library for revalue()
  library(plyr)

  # Extract the trial times and outcomes
  task_times <- task_data['Trial.Start.Time..Onset.'][,1]
  task_data['Response.Outcome'][,1] <- revalue(task_data['Response.Outcome'][,1], task_key, warn_missing = FALSE)
  task_outcome <- as.numeric(as.character(task_data['Response.Outcome'][,1]))

  # If we're looking at just the rIFG (a QC check)...
  if (FALSE) {
    rIFG_voxels <- read.csv(file = '../data/rIFGClusterRows.csv', header = FALSE)
    activations <- activations[, as.logical(rIFG_voxels)]
    activations <- cbind(activations, rowMeans(activations, na.rm = TRUE))
  }

  roi_voxels  <- read.csv(file = '/home/dan/projects/imagen/data/roi_voxels.csv', header = TRUE)
  rois <- colnames(roi_voxels)

  tmp <- matrix(NA, dim(activations)[1], length(rois))
  colnames(tmp) <- rois
  for (roi in rois) {
    #activations[roi] <- rowMeans(activations[, as.logical(roi_voxels)], na.rm = TRUE)
    tmp[,roi]    <- rowMeans(activations[, as.logical(roi_voxels[[roi]]) ], na.rm = TRUE)
  }
  activations <- tmp

  # Save the fmri_series data (for raw <-> processed comparison)
  #saveRDS(activations, 'activations.rds')

  # Z-Score the data for each participant
  mean <- colMeans(activations, na.rm = TRUE)
  std  <- apply(activations, 2, sd, na.rm = TRUE)

  activations <- sweep(activations, 2, mean, FUN = "-")
  activations <- sweep(activations, 2, std , FUN = "/")

  # Initial spike removal.
  # - Zero is preferred to NA so that the number of non NA entries is retained.
  # - These will be set to 0 again after being perturbed by corrections.
  spike_inds <- which(abs(activations) >= 3)
  activations[spike_inds] <- 0

  # Drift correction
  # In principle filter this is redundant w/ filter...
  #trs         <- as.vector(seq(1,444)) # used right here...
  #polyfit     <- lm( as.matrix(activations) ~ poly(trs, 2))
  #activations <- activations - polyfit$fitted.values

  # High-Pass Filter
  bf <- signal::butter(2, 1/128, type = "high")
  filter <- function(x) {signal::filtfilt(bf, x)}
  activations <- apply(activations, 2, filter)

  # Re Z-Score and secondary spike removal
  mean <- colMeans(activations, na.rm = TRUE)
  std  <- apply(activations, 2, sd, na.rm = TRUE)

  activations <- sweep(activations, 2, mean, FUN = "-")
  activations <- sweep(activations, 2, std , FUN = "/")

  spike_inds <- which(abs(activations) >= 3)
  activations[spike_inds] <- 0 # See note on spike removal above.

  # Return data
  data <- list(acts = activations, spikes = spike_inds, task_outcome = task_outcome,
               task_times = task_times, task_key = task_key, movement = movement)
  return(data)

} # EOF
# ------------------------------------------------------------------------------ #



# ------------------------------------------------------------------------------ #
#            Fits a robust general linear model to raw fMRI activations          #
# ------------------------------------------------------------------------------ #
fit_fmri_glm <- function(fmri_data, seperate) {

  # Contrast groupings
  conditions <- as.integer(unique(fmri_data$task_key))
  cond_names <- names(fmri_data$task_key)
  n_conds    <- length(conditions)

  # fMRI analysis functions
  library(fmri)

  # Proportion of subjects w/ significant STN betas for STOP_SUCCESS
  frac_go_sig   <- 0
  frac_stop_sig <- 0

  # Number of scans in this series -- varies by individual.
  n_scans <- length(fmri_data$acts[!is.na(fmri_data$acts[,1]),1])

  # Array for events convolved w/ HRF
  conv_regs <- array(dim = c(n_scans, n_conds))

  # In case of ancestral graph analysis, need book keeping vars for
  # additional by-trial regressors
  if (seperate) {
    total_trials  <- length(fmri_data$task_outcome[!is.na(fmri_data$task_outcome)])
    conv_regs_ag  <- array(NA, dim = c(n_scans, total_trials))
    n_trials_prev <- 0
    offset        <- 0
    index_list    <- list()
    cond_names_ag <- c()
  }

  # Some conditions do not occur - they will be removed
  bad_cond  <- c()

  # List of onset times by condition
  onset_list <- list(c(), c(), c(), c(), c(), c(), c())

  # Fill the conv_regressors array for each condition
  for (cond in conditions) {

    # Masks for getting trial times
    cond_msk <- fmri_data$task_outcome %in% cond

    # If this condition doesn't occur, skip it.
    n_trials <- sum(cond_msk)
    if (n_trials == 0) {
        bad_cond <- cbind(bad_cond,cond)
        next
    }

    # For some reason fmri.stimulus can't handle the zero.
    # Only one of thousands of pts, so just 'fix' it.
    if (fmri_data$task_times[cond_msk][1] == 0) {
        fmri_data$task_times[cond_msk][1] <- 500
    }

    # Trial onset times and their durations - 0s for event design
    # Onsets are converted from [ms] to units of [TR]
    onsets    <- fmri_data$task_times[cond_msk]
    onsets    <- as.vector(na.omit(onsets/1000/2.2))
    durations <- double(length(onsets))

    # Standard fmri analysis - convolve hrf w/ event times:
    conv_regs[,cond] <- fmri.stimulus(scans = n_scans, onsets = onsets, duration = durations)

    # Get convolved regressor for condition if 'seperate' is flagged
    if (seperate) {
      # Function to apply fmri.stimulus to each condition onset
      conv_hrf <- function(x) { fmri.stimulus(scans = n_scans, onsets = x, duration = 0) }

      # In ancestral graph case, each trial is given a seperate regressor
      offset  <- offset + n_trials_prev
      ind_beg <- offset + 1
      ind_end <- offset + n_trials

      conv_regs_ag[,ind_beg:ind_end] <- simplify2array(lapply(onsets, conv_hrf))
      cond_names_ag[ind_beg:ind_end] <- paste(cond_names[cond], 1:n_trials, sep = ':')

      n_trials_prev <- n_trials
      index_list[[cond]]    <- c(ind_beg, ind_end)
    }
  }

  # Assign appropriate names
  colnames(conv_regs)    <- cond_names
  colnames(conv_regs_ag) <- cond_names_ag

  # Create design matrix by adding 2nd deg drift and remove any bad conditions from conv_regs
  conds      <- setdiff(1:7, bad_cond)
  design_mat <- fmri.design(conv_regs[, conds], order = 2)
  cond_names <- cond_names[conds]

  # Remove the unnecessary intercept column (which will otherwise be identical to col. 1)
  nconds     <- dim(design_mat)[2] - 3
  design_mat <- design_mat[, c(1:nconds, (nconds + 2):(nconds + 3)) ]
  colnames(design_mat) <- c(cond_names, 'Linear Drift', 'Sq. Drift')
  cond_names <- colnames(design_mat)

  # Add the motion parameters to the set of regressors
  design_mat <- cbind(design_mat, as.matrix(fmri_data$movement))
  colnames(design_mat) <- c(cond_names, 'Motion_x', 'Motion_y', 'Motion_z', 'Motion_pitch', 'Motion_yaw', 'Motion_roll')
  cond_names <- colnames(design_mat)

  # Indicate pool for core-level SIMD parallelism:
  # Note: Using makeClust() here will break this on some clusters which do not let R
  #       use socket based core communication. mclapply defaults to fork-based dispatching.
  library(parallel)
  cores <- detectCores()
  flog.info('Using %d cores', cores[1])

  # Specifics for fitting the linear model with robust regression
  library(robust)
  n_voxels     <- dim(fmri_data$acts)[2]
  n_regressors <- dim(design_mat)[2]
  coefficients <- matrix(NA, n_regressors, n_voxels )

  if (seperate) {
    coefficients <- matrix(NA, total_trials, n_voxels )
    colnames(coefficients) <- colnames(fmri_data$acts)
    time <- system.time(
    for (roi in 1:n_voxels) {
      coefficients[,roi] <- fit_ag_lm(conv_regs_ag, design_mat, fmri_data$acts[,roi], index_list, conds)
    }
    )
    rownames(coefficients) <- colnames(conv_regs_ag)
  } else {
    # Function to apply lmRob to each column of the activation data
    fit_cols <- function(x) {
      lmRob(x ~ design_mat)$coefficients[2:(n_regressors + 1)]
    }

    # Perform regression
    time <- system.time(
      coefficients <- mclapply(data.frame(fmri_data$acts), fit_cols, mc.cores = cores[1], mc.silent = TRUE)
    )
  }

  # Report time required for regression
  flog.info('Computation time for voxel betas:')
  print(time)
  #saveRDS(coefficients, 'betas2.rds')

  # Return coefficients to desired format
  coefficients <- data.frame(coefficients)
  if (!seperate) {
    rownames(coefficients) <- cond_names
  }

  # Some diagnostic plots...
  #ggplot(melt(rob_model$fitted.values), aes(1:444,value)) + geom_point(col = 'red')
  #+ geom_point(aes(1:444,melt(fmri_data$acts[,503])), col = 'blue')

  # Save the linear model, list of conds removed,
  lm_list <- list(coef = coefficients, bad_cond = bad_cond, design = design_mat, onsets = onset_list)
  return(lm_list)
}
# ------------------------------------------------------------------------------ #


# ------------------------------------------------------------------------------ #
#         This performs the linear model fitting for the ancestral graphs        #
# ------------------------------------------------------------------------------ #
fit_ag_lm <- function(conv_regs_ag, design_mat, activations, index_list, conds) {
  trial_betas <- rep(NA, dim(conv_regs_ag)[2])
  names(trial_betas) <- colnames(conv_regs_ag)

  global_trial_num <- 0
  for (cond in conds[conds <= 4]) {
    beg <- index_list[[cond]][1]
    end <- index_list[[cond]][2]

    other_conds <- setdiff(conds, cond)

    trials <- beg:end
    for (trial in trials) {
      global_trial_num <- global_trial_num + 1

      remaining_inds <- setdiff(trials, trial)
      remaining_regs <- apply(conv_regs_ag[,remaining_inds],1,sum)

      design <- cbind(conv_regs_ag[,trial], remaining_regs, design_mat[,other_conds])
      fit    <- lm(activations ~ design)

      trial_betas[global_trial_num] <- fit$coefficients[2]
    }
  }
  return(trial_betas)
}
# ------------------------------------------------------------------------------ #


# ------------------------------------------------------------------------------ #
#               A finite impulse response model, currently unused.               #
# ------------------------------------------------------------------------------ #
fir <- function(onsets, durations, activations, n_scans, n_conds, n_voxels) {
  # Scale parameter - sets resolution
  scale <- 10

  # Rescale onsets
  onsets    <- onsets    * scale
  durations <- durations * scale

  n_scans <- n_scans * scale
  res     <- TR / scale

  #if (type == "user")
  #   shrf <- sum(hrf(0:(ceiling(scans) - 1)/scale))
  #   no  <- length(onsets)
  #if (length(durations) == 1) {
  #  durations <- rep(durations, no)
  #}
  #else if (length(durations) != no) {
  #  stop("Length of duration vector does not match the number of onsets!")
  #}
  stims <- rep(0, ceiling(scans))

  ## ESTIMATE HRF USING FIR BASIS SET

  # CREATE FIR DESIGN MATRIX
  # WE ASSUME HRF IS 16 TRS LONG
  hrf_len <- 16

  # BASIS SET FOR EACH CONDITOIN IS A TRAIN OF INPULSES
  fir_bases <- zeros(n_scans, hrf_len*n_conds)

  for (cond in 1:n_conds) {
      col_subset <- ((cond - 1)* hrf_len + 1):(cond*hrf_len)

      for (onset in 1:numel(onsets[,cond]) ) {
          #impulse_times <- onsets(onset):onsets(onset) + hrf_len - 1;
          impulse_times <- seq(onsets(onset), onsets(onset) + hrf_len*scale - 1, scale)

          for (impulse in 1:numel(impulse_times)) {
              fir_bases(impulse_times(impulse), col_subset(impulse)) <- 1;
          }
      }
  }

  # ESTIMATE HRF FOR EACH CONDITION AND VOXEL
  fir_hrf_est <- pseudoinverse(fir_bases %*% fir_bases) * fir_bases %*% activations

  # RESHAPE HRFS
  hHatFIR <- reshape(fir_hrf_est, hrf_len, n_conds, n_voxels)
}
# ------------------------------------------------------------------------------ #
