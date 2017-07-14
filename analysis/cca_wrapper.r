#load('fda')
#load('Matrix')
#load('fields')
#load('spam')
#load('grid')

cca_wrapper <- function(dset1, dset2){

    # Setup:
    dset1_names <- colnames(dset1)
    dset2_names <- colnames(dset2)

    library(CCA)
    cca_res <- cancor(dset1, dset2)
    nxcoef  <- length(cca_res$xcoef[,1])
    nycoef  <- length(cca_res$ycoef[,1])

    # Set plot options
    options(repr.plot.width=9, repr.plot.height=5)

    # One figure in row 1 and two figures in row 2
    layout(matrix(c(1, 2, 2, 2, 1, 3, 3, 3), 2, 4, byrow = TRUE))

    # Significance testing:
    library(CCP)
    n_obs         <- dim(dset1)[1]
    n_task_vars   <- dim(dset1)[2]
    n_survey_vars <- dim(dset2)[2]

    ps <- p.asym(rho = cca_res$cor, n_obs, n_task_vars, n_survey_vars, tstat = "Wilks")
    nlines <- max(sum(ps$p.value < 0.05), 1)
    if (nlines < 1) stop('nlines < 1 (no significant correlations)')
    colors <- rainbow(nlines)


    # U-V Correlation Plot:
    print(cca_res$cor)
    #plot(cca_res$cor,type="b", main='Task-Survey Cannonical Correlation Results',
    #     xlab='Canonical Covariate Index', ylab='U-V Correlation')
    barplot(cca_res$cor, col = colors[1:nlines])
    abline(h = 0)

    # U Coefficients Plot:
    #plotchar <- seq(18,18+nlines,1)

    #xrange <- range(1:length(dset1_names))
    #yrange <- range(cca_res$xcoef[,1:nlines])

    #op <- par(mar=c(12.1, 4.1, 4.1, 2.1))

    #plot(xrange, yrange, type="n", xlab="", ylab="Canonical Coefficient", xaxt="n")

    scale_fun <- function(x) {x*1/apply(apply(cca_res$xcoef, 2, abs ), 2, max)}
    scaled_xc <- apply(cca_res$xcoef, 1, scale_fun)
    scaled_xc <- cca_res$xcoef

    print(scaled_xc)
    barplot(scaled_xc, beside = TRUE, col = colors[1:nlines])
    abline(h = 0)
    linetype <- c(1:nlines)

    #for (i in 1:nlines) {
    #  lines(1:nxcoef, cca_res$xcoef[,i], type="b", lwd=1.5, lty=linetype[1], col=colors[i], pch=plotchar[i])
    #}

    # add a title and subtitle
    title("CCA Task Coefficients")

    # add a legend
    legend(1, 50, 1:nlines, cex=0.8, col=colors, lty=linetype)
    axis(1, labels=dset1_names, at=1:length(dset1_names), las=2)
    grid()


    ## V Coefficients Plot:
    plotchar <- seq(18,18+nlines,1)

    xrange <- range(1:length(dset2_names))
    yrange <- range(cca_res$ycoef[,1:nlines])

    #op <- par(mar=c(10.1, 4.1, 4.1, 2.1))
    #plot(xrange, yrange, type="n", xlab="", ylab="Canonical Coefficient", xaxt="n")
    #abline(h = 0)

    scale_fun <- function(x) {x*1/apply(apply(cca_res$ycoef, 2, abs ), 2, max)}
    scaled_yc <- apply(cca_res$ycoef, 1, scale_fun)
    scaled_yc <- cca_res$ycoef

    print(scaled_yc)
    barplot(scaled_yc, beside = TRUE, col = colors[1:nlines])
    abline(h = 0)
    #for (i in 1:nlines) {
    #  lines(1:nycoef, cca_res$ycoef[,i], type="b", lwd=1.5, lty=linetype[1], col=colors[i], pch=plotchar[i])
    #}

    # add a title and subtitle
    title("CCA Survey Coefficients")

    # add a legend
    legend(xrange[1], yrange[2], 1:nlines, cex=0.8, col=colors, lty=linetype)
    #axis(1, labels = dset2_names, at = 1:nycoef, las=2)
    grid()

    return(cca_res)
}