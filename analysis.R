# ==============================================================================
# ANALYSIS — "Same Text, Different Filename: Are LLMs Biased?"
# Pre-registration: AsPredicted #320377 (https://aspredicted.org/vp8ez6.pdf)
#   v3; updates #314219 (qj59r2) and #312192 (sq9mp2). Label is sent inline as a header line.
#
# Reads results_main/calls.csv (produced by main_study.R) and writes tables,
# figures and LaTeX fragments to analysis_output/.
#
# Confirmatory (pre-registered):
#   score = first number in the reply; OLS on condition indicators with document
#   fixed effects; HC3 standard errors; H1/H2/H3 as linear contrasts; Holm
#   adjustment across models within each hypothesis; two-sided alpha = 0.05.
# Everything else in this file is descriptive or robustness, and is labelled so.
#
# Depends: base R only.
# ==============================================================================

opt <- list(
  csv       = "results_main/calls.csv",
  out_dir   = "analysis_output",
  delivery  = "text",            # inline label (OpenRouter strips filenames from attachments); "file" = not usable via OpenRouter
  score_col = "score",           # "score_alt" for the last-number robustness check
  labels    = c("Document.md",
                "Document_from_Sergey.md",
                "Document_from_ChatGPT.md",
                "Document_from_Claude.md",
                "Document_from_Gemini.md",
                "Document_from_Chen.md"),
  label_short = c("Document.md" = "Neutral",
                  "Document_from_Sergey.md" = "Human",
                  "Document_from_ChatGPT.md" = "ChatGPT",
                  "Document_from_Claude.md" = "Claude",
                  "Document_from_Gemini.md" = "Gemini",
                  "Document_from_Chen.md" = "Chen"),
  family_label = c(openai = "ChatGPT", anthropic = "Claude", google = "Gemini")
)
dir.create(opt$out_dir, showWarnings = FALSE)

# ------------------------------- Load and clean -------------------------------
load_calls <- function() {
  d <- read.csv(opt$csv, stringsAsFactors = FALSE)
  if (!"delivery" %in% names(d)) d$delivery <- opt$delivery
  d <- d[d$delivery == opt$delivery, ]
  d <- d[!duplicated(d$trial_id, fromLast = TRUE), ]   # keep the successful retry
  d$valid <- d$status == "ok" & !is.na(d[[opt$score_col]])
  d$lab <- factor(unname(opt$label_short[d$label]),
                  levels = unname(opt$label_short[opt$labels]))
  d$doc_id <- factor(d$doc_id)
  d$family <- factor(d$family)
  d
}

# --------------------------- Collection diagnostics ---------------------------
report_collection <- function(d) {
  cat("\n================ COLLECTION ================\n")
  cat("Calls:", nrow(d), " valid:", sum(d$valid),
      sprintf("(%.1f%%)\n", 100 * mean(d$valid)))
  cat("\nStatus by model:\n"); print(table(d$family, d$status))
  if ("reply_shape" %in% names(d)) {
    cat("\nShape of reply:\n"); print(table(d$family, d$reply_shape, useNA = "ifany"))
  }
  if (all(c("score", "score_alt") %in% names(d))) {
    dis <- sum(d$valid & !is.na(d$score_alt) & d$score != d$score_alt)
    cat("\nReplies where first-number and last-number parsing disagree:", dis, "\n")
  }
  cat("\nObservations per document x condition (valid only):\n")
  print(table(d$doc_id[d$valid], d$lab[d$valid]))
  cat("\nProviders and model versions:\n")
  print(unique(d[, c("family", "model_requested", "model_returned", "provider")]))
  cat("\nInput tokens by document (should vary only a few tokens across conditions):\n")
  print(round(tapply(d$prompt_tokens[d$valid],
                     list(d$doc_id[d$valid], d$lab[d$valid]), mean), 1))
  cat("\nMedian seconds per call:", round(median(d$response_secs, na.rm = TRUE), 1),
      " total cost:", round(sum(d$cost_usd, na.rm = TRUE), 2), "\n")
  invisible(NULL)
}

# -------------------------------- Descriptives --------------------------------
describe <- function(d) {
  s <- d[d$valid, ]; y <- s[[opt$score_col]]
  cat("\n================ DESCRIPTIVES ================\n")
  cat("Score range:", min(y), "-", max(y), " mean:", round(mean(y), 3), "\n")
  cat("\nMean by model and condition:\n")
  print(round(tapply(y, list(s$family, s$lab), mean), 3))
  cat("\nSD by model and condition:\n")
  print(round(tapply(y, list(s$family, s$lab), sd), 3))
  cat("\nMean by document and condition (all models pooled):\n")
  print(round(tapply(y, list(s$doc_id, s$lab), mean), 3))

  tab <- do.call(rbind, lapply(levels(s$family), function(f) {
    x <- s[s$family == f, ]
    data.frame(model = f,
               condition = levels(s$lab),
               n = as.vector(table(x$lab)),
               mean = round(as.vector(tapply(x[[opt$score_col]], x$lab, mean)), 3),
               sd = round(as.vector(tapply(x[[opt$score_col]], x$lab, sd)), 3))
  }))
  write.csv(tab, file.path(opt$out_dir, "descriptives.csv"), row.names = FALSE)
  invisible(tab)
}

# ------------------------- HC3 OLS and linear contrasts -----------------------
hc3_fit <- function(y, X) {
  XtXi <- solve(crossprod(X))
  b <- drop(XtXi %*% crossprod(X, y))
  e <- as.vector(y - X %*% b)
  h <- rowSums((X %*% XtXi) * X)
  V <- XtXi %*% crossprod(X, X * (e^2 / (1 - h)^2)) %*% XtXi
  list(b = b, V = V, n = length(y), k = ncol(X),
       resid_sd = sqrt(sum(e^2) / (length(y) - ncol(X))),
       r2 = 1 - sum(e^2) / sum((y - mean(y))^2))
}

contrast_test <- function(fit, w) {
  est <- sum(w * fit$b)
  se <- sqrt(drop(t(w) %*% fit$V %*% w))
  z <- est / se
  data.frame(estimate = est, se = se, z = z, p = 2 * pnorm(-abs(z)),
             ci_lo = est - qnorm(0.975) * se, ci_hi = est + qnorm(0.975) * se)
}

# Weights are defined over the fitted coefficient names. The neutral condition is
# the omitted category, so its coefficient is 0 and any weight on it drops out;
# that is why H1's -1/2 on "Neutral" and H3's -1 on it do not appear below.
fit_model <- function(s) {
  X <- model.matrix(~ lab + doc_id, data = s)
  fit <- hc3_fit(s[[opt$score_col]], X)
  fit$names <- colnames(X)
  fit
}

hypotheses <- function(fit, own) {
  ai <- c("ChatGPT", "Claude", "Gemini")
  riv <- setdiff(ai, own)
  w <- function(f) vapply(fit$names, f, 0)
  has <- function(n, k) grepl(paste0("^lab", k, "$"), n)
  rbind(
    H1 = contrast_test(fit, w(\(n) if (any(vapply(ai, \(k) has(n, k), TRUE))) 1/3
                              else if (has(n, "Human")) -1/2 else 0)),
    H2 = contrast_test(fit, w(\(n) if (has(n, own)) 1
                              else if (any(vapply(riv, \(k) has(n, k), TRUE))) -1/2 else 0)),
    H3 = contrast_test(fit, w(\(n) if (any(vapply(riv, \(k) has(n, k), TRUE))) 1/2 else 0)),
    # H4 as worded in #314219: Chen minus mean(Sergey, neutral); neutral drops out
    H4 = contrast_test(fit, w(\(n) if (has(n, "Chen")) 1 else if (has(n, "Human")) -1/2 else 0)),
    # H4b: Chen minus Sergey only (stricter name contrast, not separately registered)
    H4b = contrast_test(fit, w(\(n) if (has(n, "Chen")) 1 else if (has(n, "Human")) -1 else 0))
  )
}

# ------------------------- Confirmatory analysis ------------------------------
confirmatory <- function(d) {
  s <- d[d$valid, ]
  cat("\n================ CONFIRMATORY (pre-registered) ================\n")
  coefs <- list(); tests <- list()
  for (f in levels(s$family)) {
    x <- droplevels(s[s$family == f, ])
    fit <- fit_model(x)
    own <- unname(opt$family_label[f])
    cond <- grep("^lab", fit$names)
    ct <- data.frame(condition = sub("^lab", "", fit$names[cond]),
                     estimate = fit$b[cond],
                     se = sqrt(diag(fit$V))[cond], row.names = NULL)
    ct$p <- 2 * pnorm(-abs(ct$estimate / ct$se))
    coefs[[f]] <- ct
    tests[[f]] <- hypotheses(fit, own)

    cat("\n---", f, "|", unique(x$model_requested), "| n =", fit$n,
        "| residual SD =", round(fit$resid_sd, 3), "| own label:", own, "---\n")
    print(round(ct[, -1], 4), row.names = FALSE)
    cat("\n")
    print(round(tests[[f]], 4))
  }

  cat("\n--- Holm-adjusted across models, within hypothesis ---\n")
  holm <- do.call(rbind, lapply(c("H1", "H2", "H3", "H4", "H4b"), function(h) {
    est <- vapply(tests, \(m) m[h, "estimate"], 0)
    p <- vapply(tests, \(m) m[h, "p"], 0)
    data.frame(hypothesis = h, model = names(p), estimate = round(est, 3),
               se = round(vapply(tests, \(m) m[h, "se"], 0), 3),
               ci_lo = round(vapply(tests, \(m) m[h, "ci_lo"], 0), 3),
               ci_hi = round(vapply(tests, \(m) m[h, "ci_hi"], 0), 3),
               p_raw = signif(p, 3), p_holm = signif(p.adjust(p, "holm"), 3),
               row.names = NULL)
  }))
  print(holm, row.names = FALSE)
  write.csv(holm, file.path(opt$out_dir, "hypothesis_tests.csv"), row.names = FALSE)
  write.csv(do.call(rbind, Map(\(f, t) cbind(model = f, t), names(coefs), coefs)),
            file.path(opt$out_dir, "condition_coefficients.csv"), row.names = FALSE)
  invisible(list(coefs = coefs, tests = tests, holm = holm))
}

# ------------------------------- Robustness -----------------------------------
robustness <- function(d) {
  s <- d[d$valid, ]; y <- s[[opt$score_col]]
  cat("\n================ ROBUSTNESS (not pre-registered) ================\n")

  cat("\nKruskal-Wallis across the six conditions, by model\n")
  cat("(on scores centred within document, so document differences drop out):\n")
  s$dev <- y - ave(y, s$doc_id, s$family, FUN = mean)
  for (f in levels(s$family)) {
    x <- s[s$family == f, ]
    print(kruskal.test(dev ~ lab, data = x))
  }

  cat("\nPairwise Wilcoxon vs the neutral condition (Holm-adjusted within model):\n")
  for (f in levels(s$family)) {
    x <- s[s$family == f, ]
    ps <- sapply(setdiff(levels(x$lab), "Neutral"), function(l)
      suppressWarnings(wilcox.test(x$dev[x$lab == l], x$dev[x$lab == "Neutral"])$p.value))
    print(data.frame(model = f, condition = names(ps),
                     p_holm = signif(p.adjust(ps, "holm"), 3), row.names = NULL))
  }

  cat("\nPer-document H1 (AI labels minus human label), by model:\n")
  tab <- do.call(rbind, lapply(levels(s$family), function(f) {
    do.call(rbind, lapply(levels(s$doc_id), function(dd) {
      x <- s[s$family == f & s$doc_id == dd, ]
      ai <- x[[opt$score_col]][x$lab %in% c("ChatGPT", "Claude", "Gemini")]
      hu <- x[[opt$score_col]][x$lab == "Human"]
      data.frame(model = f, doc = dd, ai_mean = round(mean(ai), 3),
                 human_mean = round(mean(hu), 3), diff = round(mean(ai) - mean(hu), 3))
    }))
  }))
  print(tab, row.names = FALSE)
  write.csv(tab, file.path(opt$out_dir, "per_document_h1.csv"), row.names = FALSE)

  if (length(unique(y)) <= 30) {
    cat("\nScore frequencies by condition (pooled models):\n")
    print(table(s$lab, y))
  } else {
    cat("\nScore frequencies omitted:", length(unique(y)), "distinct values.\n")
  }
  invisible(tab)
}

# --------------------------------- Figures ------------------------------------
figures <- function(d) {
  s <- d[d$valid, ]; y <- s[[opt$score_col]]
  s$dev <- y - ave(y, s$doc_id, s$family, FUN = mean)

  png(file.path(opt$out_dir, "fig1_condition_means.png"), 1000, 620, res = 120)
  par(mar = c(4, 8, 3, 2))
  fams <- levels(s$family); cols <- seq_along(fams)
  means <- sapply(fams, \(f) tapply(s$dev[s$family == f], s$lab[s$family == f], mean))
  ses <- sapply(fams, \(f) tapply(s$dev[s$family == f], s$lab[s$family == f],
                                  \(v) sd(v) / sqrt(length(v))))
  ylim <- range(c(means - 2 * ses, means + 2 * ses), na.rm = TRUE)
  plot(NA, xlim = c(0.5, nrow(means) + 0.5), ylim = ylim, xaxt = "n", las = 1,
       xlab = "", ylab = "Score minus document mean",
       main = "Effect of the filename label on writing-quality scores")
  abline(h = 0, col = "grey70", lty = 2)
  axis(1, at = seq_len(nrow(means)), labels = rownames(means))
  off <- seq(-0.15, 0.15, length.out = length(fams))
  for (i in seq_along(fams)) {
    x <- seq_len(nrow(means)) + off[i]
    arrows(x, means[, i] - 1.96 * ses[, i], x, means[, i] + 1.96 * ses[, i],
           angle = 90, code = 3, length = 0.04, col = cols[i])
    points(x, means[, i], pch = 19, col = cols[i])
  }
  legend("topright", legend = fams, col = cols, pch = 19, bty = "n")
  dev.off()

  png(file.path(opt$out_dir, "fig2_distributions.png"), 1000, 620, res = 120)
  par(mar = c(4, 5, 3, 2))
  boxplot(dev ~ lab, data = s, las = 1, ylab = "Score minus document mean",
          xlab = "", main = "Distribution of centred scores by condition",
          col = "grey90")
  abline(h = 0, col = "grey60", lty = 2)
  dev.off()

  cat("\nFigures written to", opt$out_dir, "\n")
  invisible(NULL)
}

# ------------------------------ LaTeX output ----------------------------------
latex_tables <- function(res, d) {
  s <- d[d$valid, ]
  f1 <- file.path(opt$out_dir, "table_conditions.tex")
  con <- file(f1, "w")
  writeLines(c(
    "\\begin{tabular}{lrrrrr}",
    "\\toprule",
    paste("Model &", paste(levels(s$lab), collapse = " & "), "\\\\"),
    "\\midrule"), con)
  for (f in levels(s$family)) {
    m <- round(tapply(s[[opt$score_col]][s$family == f], s$lab[s$family == f], mean), 3)
    writeLines(paste(f, "&", paste(sprintf("%.3f", m), collapse = " & "), "\\\\"), con)
  }
  writeLines(c("\\bottomrule", "\\end{tabular}"), con); close(con)

  f2 <- file.path(opt$out_dir, "table_hypotheses.tex")
  h <- res$holm
  con <- file(f2, "w")
  writeLines(c(
    "\\begin{tabular}{llrrlr}",
    "\\toprule",
    "Hypothesis & Model & Estimate & SE & 95\\% CI & $p$ (Holm) \\\\",
    "\\midrule"), con)
  for (i in seq_len(nrow(h))) {
    writeLines(sprintf("%s & %s & %.3f & %.3f & [%.3f, %.3f] & %.3f \\\\",
                       h$hypothesis[i], h$model[i], h$estimate[i], h$se[i],
                       h$ci_lo[i], h$ci_hi[i], h$p_holm[i]), con)
  }
  writeLines(c("\\bottomrule", "\\end{tabular}"), con); close(con)
  cat("LaTeX tables:", f1, "and", f2, "\n")
  invisible(NULL)
}

# ------------------------------- Run everything -------------------------------
main <- function() {
  d <- load_calls()
  sink(file.path(opt$out_dir, "analysis_log.txt"), split = TRUE)
  on.exit(sink(), add = TRUE)
  cat("Analysis run:", format(Sys.time()), "\n")
  cat("Input:", opt$csv, "| delivery:", opt$delivery, "| score column:", opt$score_col, "\n")
  report_collection(d)
  describe(d)
  res <- confirmatory(d)
  robustness(d)
  figures(d)
  latex_tables(res, d)
  cat("\nDone. Output in", opt$out_dir, "\n")
  invisible(res)
}

# res <- main()
#
# Robustness re-runs (each writes over analysis_output; change opt$out_dir first):
#   opt$score_col <- "score_alt"; opt$out_dir <- "analysis_output_altparse"; main()
#   opt$delivery  <- "text";      opt$out_dir <- "analysis_output_inline";   main()
