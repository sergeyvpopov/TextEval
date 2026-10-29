# ==============================================================================
# ANALYSIS, STUDY 2 - "Same Text, Different Filename", Study 2 (LLM-generated documents)
# Pre-registration: AsPredicted #[number] ([link])
#
# Reads results_study2_main/calls_*.csv (main_study2.R) and writes tables,
# figures and a log to analysis_output_study2/.
#
# Design: 30 briefs x 3 generators = 90 documents; 8 labels; 3 judges; 12 reps.
# Each judge is analysed separately; Holm across the three judges within each
# confirmatory test; alpha = 0.05, two-sided. The brief is the unit of
# resampling and inference wherever documents are pooled.
#
# CONFIRMATORY (preregistered, Q5)
#  Q1 Existence: do labels change scores within documents? Per judge, a
#     permutation test (labels shuffled within each document, 4,999 draws) of the
#     between-label sum of squares summed over documents.
#  Q2 Size: how large are label effects within a document? Per judge, the
#     noise-corrected SD of label effects within documents, and its ratio to the
#     noise-corrected SD between documents. Estimates with jackknife-over-briefs
#     95% CIs (no test).
#  Q3 Persistence: are label effects the same across documents?
#     - share of the within-document label variance that is persistent (common
#       to all documents) rather than document-specific, with jackknife CI;
#       the persistent variance uses only products between different briefs,
#       so it is not inflated by documents of the same brief being alike;
#     - Hotelling T^2 test that all 7 brief-level label effects (vs neutral) are
#       zero;
#     - named persistent biases, each a one-sample t-test across the 30
#       per-brief contrasts (df = 29):
#         H5 self-recognition (neutral label; judge x generator table, additive
#            fit on the six off-diagonal cells, own cell minus prediction)
#         H6 own-family label vs the two rival AI labels, on own-family text
#         H7 AI labels (mean of 3) vs human-name labels (mean of Sergey,
#            Catherine, Chen), on all documents
# ROBUSTNESS for H5-H7 (preregistered, not confirmatory): (a) call-level OLS with
#  fixed effects and CR2 errors clustered by brief, t with G - 1 df; (b) linear
#  mixed models; (c) last-number parsing; (d) neutral label as reference.
# EXPLORATORY (Q8): placebo (v2) and each name vs neutral, Catherine vs Sergey,
#  Chen vs the other names, true-label match, label x generator, per-document
#  tests, genre, length, scale use, valid-reply rates.
#
# Exclusions (Q6): API errors and replies from another model are dropped (they
#  were re-run); the first valid record per trial is kept; replies without a
#  number in [0, 10] are excluded from scores and reported. Only complete
#  repetitions are used (stopping rule); at least opt2$min_reps are required.
#
# Depends: base R for all confirmatory analyses; clubSandwich (a), lme4 (b).
# ==============================================================================

opt2 <- list(
  in_dir   = "results_study2_main",
  out_dir  = "analysis_output_study2",
  gen_dir  = "results_study2",       # generate_documents.R output (document length)
  min_reps = 8,                      # preregistered minimum of complete repetitions
  n_perm   = 4999,
  seed     = 20261029,
  alpha    = 0.05,
  power    = 0.80
)
fams <- c("openai", "anthropic", "google")
fam_label <- c(openai = "ChatGPT", anthropic = "Claude", google = "Gemini")
lab_short <- c("Document.md" = "Neutral", "Document_v2.md" = "v2",
               "Document_from_Sergey.md" = "Sergey", "Document_from_Catherine.md" = "Catherine",
               "Document_from_Chen.md" = "Chen", "Document_from_ChatGPT.md" = "ChatGPT",
               "Document_from_Claude.md" = "Claude", "Document_from_Gemini.md" = "Gemini")
labs <- unname(lab_short)
ai_labs <- unname(fam_label)
human_labs <- c("Sergey", "Catherine", "Chen")
dir.create(opt2$out_dir, showWarnings = FALSE)
sink(file.path(opt2$out_dir, "analysis_log.txt"), split = TRUE)
cat("Study 2 analysis run:", format(Sys.time()), "\n")
set.seed(opt2$seed)

# ------------------------------- Load and clean -------------------------------
load_study2 <- function(score_col = "score") {
  fs <- list.files(opt2$in_dir, "^calls_.*\\.csv$", full.names = TRUE)
  if (!length(fs)) stop("No calls_*.csv files in ", opt2$in_dir)
  d <- do.call(rbind, lapply(fs, read.csv, stringsAsFactors = FALSE))
  n_rows <- nrow(d)
  d <- d[which(d$status == "ok" & d$model_returned == d$model_requested), ]
  d <- d[!duplicated(d$trial_id), ]                    # first valid record per trial
  sched <- read.csv(file.path(opt2$in_dir, "schedule.csv"), stringsAsFactors = FALSE)
  R <- vapply(fams, function(f) {                      # complete repetitions per judge
    s <- sched[sched$family == f, ]
    ok <- tapply(s$trial_id %in% d$trial_id, s$rep, all)
    r <- 0; for (k in sort(as.integer(names(ok)))) if (ok[as.character(k)]) r <- k else break
    r
  }, 0)
  d <- d[d$rep <= R[d$family], ]
  unknown <- setdiff(unique(d$label), names(lab_short))
  if (length(unknown)) stop("Labels not in the analysis plan: ", paste(unknown, collapse = ", "))
  d$lab <- factor(unname(lab_short[d$label]), levels = labs)
  d$y <- d[[score_col]]
  d$valid <- !is.na(d$y)
  attr(d, "info") <- list(n_rows = n_rows, R = R)
  d
}

# Cell means as an array [brief, judge, generator, label].
cell_array <- function(d) {
  v <- d[d$valid, ]
  tapply(v$y, list(factor(v$brief_id), factor(v$family, fams),
                   factor(v$generator, fams), v$lab), mean)
}

# ---------------------------- Helper statistics -------------------------------
t_tests <- function(C, hyp, holm = TRUE) {
  res <- do.call(rbind, lapply(colnames(C), function(j) {
    x <- C[, j]; x <- x[!is.na(x)]; n <- length(x)
    se <- sd(x) / sqrt(n); est <- mean(x); df <- n - 1
    data.frame(test = hyp, judge = j, n_briefs = n, estimate = est, se = se,
               sd_briefs = sd(x), t = est / se, df = df,
               p_raw = 2 * pt(-abs(est / se), df),
               ci_lo = est - qt(0.975, df) * se, ci_hi = est + qt(0.975, df) * se,
               mde80 = (qt(1 - opt2$alpha / (2 * length(fams)), df) + qt(opt2$power, df)) * se,
               positive_briefs = sum(x > 0), negative_briefs = sum(x < 0))
  }))
  res$p_holm <- if (holm) p.adjust(res$p_raw, "holm") else NA
  res
}
per_brief <- function(m, f) {
  out <- sapply(fams, function(j) sapply(dimnames(m)[[1]], function(b) f(m, b, j)))
  matrix(out, ncol = length(fams), dimnames = list(dimnames(m)[[1]], fams))
}
rival_labs <- function(j) setdiff(ai_labs, fam_label[[j]])
fmt <- function(df) { for (k in names(df)) if (is.numeric(df[[k]]))
  df[[k]] <- if (grepl("^p_", k)) signif(df[[k]], 3) else round(df[[k]], 3); df }

# ------------------------------- Load ----------------------------------------
d <- load_study2("score")
info <- attr(d, "info")
cat("\n================ DATA ================\n")
cat("Rows in calls files:", info$n_rows, "| usable records:", nrow(d), "\n")
cat("Complete repetitions per judge:", paste(names(info$R), info$R, sep = " = ", collapse = ", "), "\n")
if (any(info$R < opt2$min_reps))
  stop("Fewer than ", opt2$min_reps, " complete repetitions for: ",
       paste(names(info$R)[info$R < opt2$min_reps], collapse = ", "),
       ". The preregistration requires at least ", opt2$min_reps, ".")
cat("Valid replies:", sum(d$valid), "of", nrow(d), sprintf("(%.2f%%)\n", 100 * mean(d$valid)))
dv <- d[d$valid, ]
docs_meta <- unique(dv[, c("doc_id", "brief_id", "generator", "genre")])
docs_meta <- docs_meta[order(docs_meta$doc_id), ]
m <- cell_array(d)
cat("Briefs:", dim(m)[1], "| documents:", nrow(docs_meta), "| labels:", length(labs),
    "| empty cells:", sum(is.na(m)), "\n")

# Per judge: document x label matrices of cell means and of sampling variance
# of each cell mean (within-cell variance / n).
doc_mats <- lapply(setNames(fams, fams), function(j) {
  s <- dv[dv$family == j, ]
  M <- tapply(s$y, list(s$doc_id, s$lab), mean)
  N <- tapply(s$y, list(s$doc_id, s$lab), function(x) var(x) / length(x))
  list(M = M[docs_meta$doc_id, labs], N = N[docs_meta$doc_id, labs])
})

# ================== Q1 EXISTENCE: permutation test ============================
cat("\n================ Q1 EXISTENCE (confirmatory) ================\n")
cat("Permutation test, labels shuffled within each document,", opt2$n_perm, "draws.\n")
between_ss <- function(y, cell, n_cells) {
  sums <- tabulate(cell, n_cells) ; tot <- rowsum(y, cell, reorder = TRUE)
  idx <- as.integer(rownames(tot))
  sum(tot[, 1]^2 / sums[idx])
}
q1 <- do.call(rbind, lapply(fams, function(j) {
  s <- dv[dv$family == j, ]
  doc <- as.integer(factor(s$doc_id)); lab <- as.integer(s$lab); L <- length(labs)
  y <- s$y - ave(s$y, doc)                              # remove document means
  cellid <- function(l) (doc - 1L) * L + l
  n_cells <- max(doc) * L
  obs <- between_ss(y, cellid(lab), n_cells)
  groups <- split(seq_along(lab), doc)
  perm <- vapply(seq_len(opt2$n_perm), function(k) {
    pl <- lab; for (g in groups) pl[g] <- lab[g][sample.int(length(g))]
    between_ss(y, cellid(pl), n_cells)
  }, 0)
  # Descriptive: per-document Welch tests, Benjamini-Hochberg within judge
  pd <- vapply(groups, function(g) oneway.test(y[g] ~ factor(lab[g]))$p.value, 0)
  data.frame(test = "Q1 labels change scores within documents", judge = j,
             between_label_ss = obs, perm_mean_ss = mean(perm),
             p_raw = (1 + sum(perm >= obs)) / (1 + opt2$n_perm),
             docs_significant_bh05 = sum(p.adjust(pd, "BH") < 0.05), n_docs = length(groups))
}))
q1$p_holm <- p.adjust(q1$p_raw, "holm")
print(fmt(q1), row.names = FALSE)
write.csv(q1, file.path(opt2$out_dir, "q1_existence.csv"), row.names = FALSE)

# ================== Q2 SIZE and Q3 PERSISTENCE: variance components ==========
# For one judge and a set of briefs:
#   total   = mean over documents of [variance of label means within the document
#             minus the mean sampling variance of its cells]   (label SD^2)
#   persist = variance of the persistent label effects, from products of brief-
#             level label deviations between DIFFERENT briefs (unbiased whatever
#             the similarity of documents within a brief)
#   between = variance of document means minus their sampling variance
components <- function(M, N, brief) {
  L <- ncol(M)
  dev <- M - rowMeans(M)
  total <- mean(rowSums(dev^2) / (L - 1) - rowMeans(N))
  E <- rowsum(dev, brief) / as.vector(table(brief)[unique(sort(brief))])   # brief x label
  B <- nrow(E)
  persist <- sum((colSums(E)^2 - colSums(E^2)) / (B * (B - 1))) / (L - 1)
  between <- var(rowMeans(M)) - mean(rowMeans(N) / L)
  c(label_var = total, persistent_var = persist, specific_var = total - persist,
    between_var = between)
}
derived <- function(cv) c(
  label_sd = sqrt(max(0, cv[["label_var"]])),
  between_sd = sqrt(max(0, cv[["between_var"]])),
  label_to_between = sqrt(max(0, cv[["label_var"]])) / sqrt(max(1e-12, cv[["between_var"]])),
  persistent_sd = sqrt(max(0, cv[["persistent_var"]])),
  specific_sd = sqrt(max(0, cv[["specific_var"]])),
  persistent_share = cv[["persistent_var"]] / cv[["label_var"]])

vc_rows <- list()
for (j in fams) {
  M <- doc_mats[[j]]$M; N <- doc_mats[[j]]$N; brief <- docs_meta$brief_id
  est <- derived(components(M, N, brief))
  ub <- unique(brief); G <- length(ub)
  jk <- t(sapply(ub, function(b) { k <- brief != b; derived(components(M[k, ], N[k, ], brief[k])) }))
  se <- sqrt((G - 1) / G * colSums(sweep(jk, 2, colMeans(jk))^2))
  q <- qt(0.975, G - 1)
  vc_rows[[j]] <- data.frame(judge = j, quantity = names(est), estimate = est, se_jackknife = se,
                             ci_lo = est - q * se, ci_hi = est + q * se, row.names = NULL)
}
vc <- do.call(rbind, vc_rows)
cat("\n================ Q2 SIZE (confirmatory estimates; points on the 0-10 scale) ================\n")
cat("label_sd: SD of label effects within a document; between_sd: SD of document means;\n",
    "label_to_between: their ratio. Jackknife-over-briefs 95% CIs.\n")
print(fmt(vc[vc$quantity %in% c("label_sd", "between_sd", "label_to_between"), ]), row.names = FALSE)
gap <- sapply(fams, function(j) { M <- doc_mats[[j]]$M; g <- apply(M, 1, max) - apply(M, 1, min)
  c(median_gap = median(g), p90_gap = unname(quantile(g, 0.9)), max_gap = max(g)) })
cat("\nLargest minus smallest label mean per document (descriptive; noise inflates it slightly):\n")
print(round(gap, 3))

cat("\n================ Q3 PERSISTENCE (confirmatory) ================\n")
cat("Split of the within-document label variance into persistent and document-specific parts:\n")
print(fmt(vc[vc$quantity %in% c("persistent_sd", "specific_sd", "persistent_share"), ]), row.names = FALSE)
write.csv(vc, file.path(opt2$out_dir, "q2_q3_variance_components.csv"), row.names = FALSE)
write.csv(gap, file.path(opt2$out_dir, "q2_label_gaps.csv"))

# Brief-level label effects vs neutral (averaged over the three generators)
brief_effects <- function(j) sapply(setdiff(labs, "Neutral"), function(l)
  rowMeans(m[, j, , l, drop = FALSE][, 1, , 1] - m[, j, , "Neutral", drop = FALSE][, 1, , 1]))
hot <- do.call(rbind, lapply(fams, function(j) {
  X <- brief_effects(j); X <- X[complete.cases(X), ]
  n <- nrow(X); p <- ncol(X); xb <- colMeans(X); S <- cov(X)
  T2 <- n * drop(t(xb) %*% solve(S) %*% xb)
  F <- (n - p) / (p * (n - 1)) * T2
  data.frame(test = "Q3 any persistent label effect (Hotelling T2)", judge = j, n_briefs = n,
             T2 = T2, F = F, df1 = p, df2 = n - p, p_raw = pf(F, p, n - p, lower.tail = FALSE))
}))
hot$p_holm <- p.adjust(hot$p_raw, "holm")
cat("\nJoint test that all 7 label effects (vs neutral) are zero on average:\n")
print(fmt(hot), row.names = FALSE)
write.csv(hot, file.path(opt2$out_dir, "q3_hotelling.csv"), row.names = FALSE)

# Persistent effect of each label vs neutral (estimates; named tests follow)
pers <- do.call(rbind, lapply(fams, function(j) {
  X <- brief_effects(j)
  t_tests(X, "x", holm = FALSE)[, c("judge", "estimate", "se", "ci_lo", "ci_hi",
                                    "positive_briefs", "negative_briefs")] |>
    transform(label = colnames(X), judge = j)
}))
pers <- pers[, c("judge", "label", "estimate", "se", "ci_lo", "ci_hi", "positive_briefs", "negative_briefs")]
cat("\nPersistent effect of each label vs neutral (mean over briefs; estimates, no test):\n")
print(fmt(pers), row.names = FALSE)
write.csv(pers, file.path(opt2$out_dir, "q3_label_effects.csv"), row.names = FALSE)

# Named persistent biases H5-H7
h5_brief <- function(m) {
  t(sapply(dimnames(m)[[1]], function(b) {
    M <- m[b, , , "Neutral"]                              # rows judge, cols generator
    if (anyNA(M)) return(setNames(rep(NA_real_, 3), fams))
    off <- which(row(M) != col(M))
    df <- data.frame(y = M[off], j = factor(fams[row(M)[off]], fams),
                     g = factor(fams[col(M)[off]], fams))
    fit <- lm(y ~ j + g, data = df)
    pred <- predict(fit, newdata = data.frame(j = factor(fams, fams), g = factor(fams, fams)))
    setNames(diag(M) - pred, fams)
  }))
}
h6_fun  <- function(m, b, j) m[b, j, j, fam_label[[j]]] - mean(m[b, j, j, rival_labs(j)])
h7_fun  <- function(m, b, j) mean(sapply(fams, function(g) mean(m[b, j, g, ai_labs]) - mean(m[b, j, g, human_labs])))
h6n_fun <- function(m, b, j) m[b, j, j, fam_label[[j]]] - m[b, j, j, "Neutral"]
h7n_fun <- function(m, b, j) mean(sapply(fams, function(g) mean(m[b, j, g, ai_labs]) - m[b, j, g, "Neutral"]))

C5 <- h5_brief(m); C6 <- per_brief(m, h6_fun); C7 <- per_brief(m, h7_fun)
named <- rbind(t_tests(C5, "H5 self-recognition"), t_tests(C6, "H6 own label on own text"),
               t_tests(C7, "H7 AI labels minus human names"),
               t_tests(matrix(rowMeans(C5), dimnames = list(rownames(C5), "pooled")),
                       "H5 self-recognition", holm = FALSE))
cat("\nNamed persistent biases (brief = unit, df = 29; Holm across judges; H5 pooled row secondary):\n")
print(fmt(named), row.names = FALSE)
write.csv(named, file.path(opt2$out_dir, "q3_named_biases.csv"), row.names = FALSE)
long <- function(C, hyp) data.frame(test = hyp, brief_id = rep(rownames(C), ncol(C)),
                                    judge = rep(colnames(C), each = nrow(C)), contrast = as.vector(C))
pb <- rbind(long(C5, "H5"), long(C6, "H6"), long(C7, "H7"))
write.csv(pb, file.path(opt2$out_dir, "per_brief_contrasts.csv"), row.names = FALSE)

# ================== ROBUSTNESS for H5-H7 =====================================
cat("\n================ ROBUSTNESS for H5-H7 (preregistered, not confirmatory) ================\n")
rob <- list()
add_rob <- function(check, hyp, judge, est, se, df, note = "") {
  p <- if (is.finite(df)) 2 * pt(-abs(est / se), df) else 2 * pnorm(-abs(est / se))
  rob[[length(rob) + 1]] <<- data.frame(check = check, test = hyp, judge = judge,
                                        estimate = est, se = se, df = df, p_raw = p, note = note)
}
contrast <- function(b, V, w) {
  w <- w[names(w) %in% names(b)]
  c(sum(w * b[names(w)]), sqrt(drop(t(w) %*% V[names(w), names(w)] %*% w)))
}
w6 <- function(j) c(setNames(1, paste0("lab", fam_label[[j]])),
                    setNames(c(-0.5, -0.5), paste0("lab", rival_labs(j))))
w7 <- c(setNames(rep(1/3, 3), paste0("lab", ai_labs)), setNames(rep(-1/3, 3), paste0("lab", human_labs)))
dr <- dv
dr$brief_id <- factor(dr$brief_id); dr$doc_id <- factor(dr$doc_id)
dr$judge <- factor(dr$family, fams); dr$gen <- factor(dr$generator, fams)
for (f in fams) dr[[paste0("own_", f)]] <- as.numeric(dr$family == f & dr$generator == f)
neu <- dr[dr$lab == "Neutral", ]
G <- nlevels(dr$brief_id)

# (a) OLS with fixed effects, CR2 clustered by brief, t with G - 1 df
if (requireNamespace("clubSandwich", quietly = TRUE)) {
  cr2 <- function(fit, cl) { V <- as.matrix(clubSandwich::vcovCR(fit, cluster = cl, type = "CR2"))
    dimnames(V) <- list(names(coef(fit)), names(coef(fit))); V }
  for (j in fams) {
    s <- dr[dr$family == j & dr$generator == j, ]
    fit <- lm(y ~ lab + brief_id, data = s)
    e <- contrast(coef(fit), cr2(fit, s$brief_id), w6(j)); add_rob("a: OLS + CR2", "H6", j, e[1], e[2], G - 1)
    s <- dr[dr$family == j, ]
    fit <- lm(y ~ lab + doc_id, data = s)
    e <- contrast(coef(fit), cr2(fit, s$brief_id), w7); add_rob("a: OLS + CR2", "H7", j, e[1], e[2], G - 1)
  }
  bj <- model.matrix(~ 0 + interaction(neu$brief_id, neu$judge))
  bg <- model.matrix(~ 0 + interaction(neu$brief_id, neu$gen))
  bg <- bg[, !grepl(paste0("\\.", fams[3], "$"), colnames(bg)), drop = FALSE]
  X <- cbind(bj, bg, as.matrix(neu[, paste0("own_", fams)]))
  colnames(X) <- make.names(colnames(X))
  fit <- lm(neu$y ~ 0 + X); names(fit$coefficients) <- colnames(X)
  V <- cr2(fit, neu$brief_id)
  for (j in fams) { e <- contrast(coef(fit), V, setNames(1, paste0("own_", j)))
    add_rob("a: OLS + CR2", "H5", j, e[1], e[2], G - 1) }
} else message("clubSandwich not installed: skipping robustness check (a).")

# (b) Linear mixed models, random intercepts for brief and brief x label
#     (normal approximation for p-values)
if (requireNamespace("lme4", quietly = TRUE)) {
  ctl <- lme4::lmerControl(optimizer = "bobyqa", calc.derivs = FALSE)
  mm <- function(expr) tryCatch(suppressMessages(suppressWarnings(expr)), error = function(e) e)
  note <- function(fit) if (lme4::isSingular(fit)) "singular fit" else ""
  for (j in fams) {
    fit <- mm(lme4::lmer(y ~ lab + (1 | brief_id) + (1 | brief_id:lab),
                         data = dr[dr$family == j & dr$generator == j, ], control = ctl))
    if (!inherits(fit, "error")) { e <- contrast(lme4::fixef(fit), as.matrix(vcov(fit)), w6(j))
      add_rob("b: mixed model", "H6", j, e[1], e[2], Inf, note(fit)) }
    fit <- mm(lme4::lmer(y ~ lab + gen + (1 | brief_id) + (1 | brief_id:gen) + (1 | brief_id:lab),
                         data = dr[dr$family == j, ], control = ctl))
    if (!inherits(fit, "error")) { e <- contrast(lme4::fixef(fit), as.matrix(vcov(fit)), w7)
      add_rob("b: mixed model", "H7", j, e[1], e[2], Inf, note(fit)) }
  }
  fit <- mm(lme4::lmer(y ~ judge + gen + own_openai + own_anthropic + own_google +
                         (1 | brief_id) + (1 | brief_id:judge) + (1 | brief_id:gen),
                       data = neu, control = ctl))
  if (!inherits(fit, "error")) for (j in fams) {
    e <- contrast(lme4::fixef(fit), as.matrix(vcov(fit)), setNames(1, paste0("own_", j)))
    add_rob("b: mixed model", "H5", j, e[1], e[2], Inf, note(fit))
  }
} else message("lme4 not installed: skipping robustness check (b).")

# (c) Last-number parsing, primary method
m_alt <- cell_array(load_study2("score_alt"))
for (r in list(list("H5", h5_brief(m_alt)), list("H6", per_brief(m_alt, h6_fun)),
               list("H7", per_brief(m_alt, h7_fun)))) {
  tt <- t_tests(r[[2]], r[[1]])
  for (i in seq_len(nrow(tt))) add_rob("c: last-number score", tt$test[i], tt$judge[i],
                                       tt$estimate[i], tt$se[i], tt$df[i])
}
# (d) Neutral label as reference, primary method
for (r in list(list("H6 vs neutral", per_brief(m, h6n_fun)), list("H7 vs neutral", per_brief(m, h7n_fun)))) {
  tt <- t_tests(r[[2]], r[[1]])
  for (i in seq_len(nrow(tt))) add_rob("d: neutral reference", tt$test[i], tt$judge[i],
                                       tt$estimate[i], tt$se[i], tt$df[i])
}
rob <- do.call(rbind, rob)
rob$p_holm <- ave(rob$p_raw, rob$check, rob$test, FUN = function(p) p.adjust(p, "holm"))
print(fmt(rob), row.names = FALSE)
write.csv(rob, file.path(opt2$out_dir, "robustness.csv"), row.names = FALSE)

# ================== EXPLORATORY ==============================================
cat("\n================ EXPLORATORY (not tests of the preregistration; no correction) ================\n")
ex_fun <- function(a, b) function(m, bb, j) mean(sapply(fams, function(g) mean(m[bb, j, g, a]) - mean(m[bb, j, g, b])))
truelab_fun <- function(m, b, j) mean(sapply(fams, function(g)
  m[b, j, g, fam_label[[g]]] - mean(m[b, j, g, setdiff(ai_labs, fam_label[[g]])])))
h6x_fun <- function(m, b, j) h6_fun(m, b, j) - mean(sapply(setdiff(fams, j), function(g)
  m[b, j, g, fam_label[[j]]] - mean(m[b, j, g, rival_labs(j)])))
expl <- rbind(
  t_tests(per_brief(m, ex_fun("v2", "Neutral")), "Placebo v2 minus neutral", FALSE),
  t_tests(per_brief(m, ex_fun(human_labs, "Neutral")), "Human names minus neutral", FALSE),
  t_tests(per_brief(m, ex_fun(human_labs, "v2")), "Human names minus placebo v2", FALSE),
  t_tests(per_brief(m, ex_fun("Catherine", "Sergey")), "Catherine minus Sergey", FALSE),
  t_tests(per_brief(m, ex_fun("Chen", c("Sergey", "Catherine"))), "Chen minus Sergey and Catherine", FALSE),
  t_tests(per_brief(m, truelab_fun), "True-label match", FALSE),
  t_tests(per_brief(m, h6x_fun), "H6 own text minus rival text", FALSE))
print(fmt(expl[, c("test", "judge", "estimate", "se", "p_raw", "positive_briefs", "negative_briefs")]), row.names = FALSE)
write.csv(expl, file.path(opt2$out_dir, "exploratory_tests.csv"), row.names = FALSE)

pb$genre <- tapply(docs_meta$genre, docs_meta$brief_id, `[`, 1)[pb$brief_id]
by_genre <- aggregate(contrast ~ test + judge + genre, data = pb, FUN = mean)
cat("\nMean per-brief contrast by genre:\n"); print(fmt(by_genre), row.names = FALSE)
write.csv(by_genre, file.path(opt2$out_dir, "exploratory_genre.csv"), row.names = FALSE)

gen_sums <- file.path(opt2$gen_dir, "document_checksums.csv")
if (file.exists(gen_sums)) {
  s <- read.csv(gen_sums, stringsAsFactors = FALSE); len <- setNames(s$words, s$doc_id)
  len_tab <- do.call(rbind, lapply(fams, function(j) {
    M <- doc_mats[[j]]$M
    k <- rowMeans(M[, ai_labs]) - rowMeans(M[, human_labs])
    spread <- apply(M, 1, sd)
    w <- len[rownames(M)] / 100
    f1 <- summary(lm(k ~ w))$coefficients; f2 <- summary(lm(spread ~ w))$coefficients
    data.frame(judge = j, h7_slope_per_100w = f1[2, 1], h7_p = f1[2, 4],
               label_spread_slope_per_100w = f2[2, 1], spread_p = f2[2, 4])
  }))
  cat("\nLength (per 100 words) vs H7 contrast and vs within-document label spread:\n")
  print(fmt(len_tab), row.names = FALSE)
  write.csv(len_tab, file.path(opt2$out_dir, "exploratory_length.csv"), row.names = FALSE)
} else message(gen_sums, " not found: skipping length analysis.")

scale_use <- do.call(rbind, lapply(fams, function(j) {
  y <- dv$y[dv$family == j]
  data.frame(judge = j, min = min(y), q05 = quantile(y, .05), median = median(y),
             q95 = quantile(y, .95), max = max(y), distinct_values = length(unique(y)),
             top3_share = sum(sort(table(y), decreasing = TRUE)[1:3]) / length(y), row.names = NULL)
}))
cat("\nScale use by judge:\n"); print(fmt(scale_use), row.names = FALSE)
write.csv(scale_use, file.path(opt2$out_dir, "descriptives_scale.csv"), row.names = FALSE)
vr <- round(100 * tapply(d$valid, list(d$family, d$lab), mean), 2)
cat("\nValid replies by judge and label (%):\n"); print(vr)
write.csv(vr, file.path(opt2$out_dir, "valid_rates.csv"))

# ================== FIGURES ==================================================
judge_names <- c(openai = "GPT-6.1 Sol", anthropic = "Claude Sonnet 5.5", google = "Gemini 4 Argon")
# Fig 1: each document's label effect vs neutral (grey) and the persistent mean (black)
png(file.path(opt2$out_dir, "fig1_label_effects_by_document.png"), width = 2700, height = 950, res = 200)
op <- par(mfrow = c(1, 3), mar = c(6, 4.5, 3, 1))
nl <- setdiff(labs, "Neutral")
ylim <- range(sapply(fams, function(j) doc_mats[[j]]$M[, nl] - doc_mats[[j]]$M[, "Neutral"]), na.rm = TRUE)
for (j in fams) {
  D <- doc_mats[[j]]$M[, nl] - doc_mats[[j]]$M[, "Neutral"]
  plot(NA, xlim = c(0.5, length(nl) + 0.5), ylim = ylim, xaxt = "n", xlab = "",
       ylab = "Label minus neutral (points)", main = judge_names[[j]])
  axis(1, seq_along(nl), nl, las = 2); abline(h = 0, lty = 2)
  for (k in seq_along(nl)) points(jitter(rep(k, nrow(D)), 0.5), D[, k], pch = 16,
                                  col = adjustcolor("grey40", 0.35), cex = 0.7)
  pj <- pers[pers$judge == j, ]
  points(seq_along(nl), pj$estimate, pch = 18, cex = 2)
  arrows(seq_along(nl), pj$ci_lo, seq_along(nl), pj$ci_hi, angle = 90, code = 3, length = 0.04, lwd = 2)
}
par(op); invisible(dev.off())
# Fig 2: per-brief contrasts for H5-H7
png(file.path(opt2$out_dir, "fig2_named_biases.png"), width = 2400, height = 900, res = 200)
op <- par(mfrow = c(1, 3), mar = c(4, 4.5, 3, 1))
for (h in c("H5", "H6", "H7")) {
  sub <- pb[pb$test == h, ]; x <- match(sub$judge, fams)
  plot(jitter(x, 0.6), sub$contrast, xaxt = "n", xlim = c(0.5, 3.5), pch = 16,
       col = adjustcolor("grey40", 0.5), xlab = "", ylab = "Per-brief contrast (points)",
       main = c(H5 = "H5 self-recognition", H6 = "H6 own label, own text",
                H7 = "H7 AI labels minus human names")[h])
  axis(1, 1:3, judge_names[fams]); abline(h = 0, lty = 2)
  pr <- named[startsWith(named$test, h) & named$judge %in% fams, ]
  points(1:3, pr$estimate, pch = 18, cex = 2)
  arrows(1:3, pr$ci_lo, 1:3, pr$ci_hi, angle = 90, code = 3, length = 0.05, lwd = 2)
}
par(op); invisible(dev.off())

cat("\nOutputs written to", opt2$out_dir, "\n")
sink()
