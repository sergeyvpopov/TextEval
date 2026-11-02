# ==============================================================================
# Study 2: label bias at the judge x document level, and its bridge to the
# variance decomposition used in analysis_study2.R (Q2 size, Q3 persistence).
# Pre-registration: AsPredicted #321045 (https://aspredicted.org/82v8c4.pdf)
#
# Run from the folder that holds results_study2_main/:   source("doc_level_bias.R")
# Writes to analysis_output_study2/:
#   doc_judge_label_effects.csv   one row per judge x document x label (3 x 90 x 8)
#   doc_judge_summary.csv         one row per judge x document        (3 x 90)
# EXPLORATORY / descriptive: the confirmatory numbers are in analysis_study2.R.
# ==============================================================================

in_dir  <- "results_study2_main"
out_dir <- "analysis_output_study2"
dir.create(out_dir, showWarnings = FALSE)
fams <- c("openai", "anthropic", "google")
lab_short <- c("Document.md" = "Neutral", "Document_v2.md" = "v2",
               "Document_from_Sergey.md" = "Sergey", "Document_from_Catherine.md" = "Catherine",
               "Document_from_Chen.md" = "Chen", "Document_from_ChatGPT.md" = "ChatGPT",
               "Document_from_Claude.md" = "Claude", "Document_from_Gemini.md" = "Gemini")
labs <- unname(lab_short)

# ---- Load: same filters as analysis_study2.R ---------------------------------
d <- do.call(rbind, lapply(list.files(in_dir, "^calls_.*\\.csv$", full.names = TRUE),
                           read.csv, stringsAsFactors = FALSE))
d <- d[which(d$status == "ok" & d$model_returned == d$model_requested), ]
d <- d[!duplicated(d$trial_id), ]
sched <- read.csv(file.path(in_dir, "schedule.csv"), stringsAsFactors = FALSE)
R <- vapply(fams, function(f) {                       # complete repetitions per judge
  s <- sched[sched$family == f, ]
  ok <- tapply(s$trial_id %in% d$trial_id, s$rep, all)
  r <- 0; for (k in sort(as.integer(names(ok)))) if (ok[as.character(k)]) r <- k else break
  r }, 0)
d <- d[d$rep <= R[d$family], ]
d$lab <- factor(unname(lab_short[d$label]), levels = labs)
d$y <- d$score
dv <- d[!is.na(d$y), ]
docs <- unique(dv[, c("doc_id", "brief_id", "generator", "genre")])
docs <- docs[order(docs$doc_id), ]
L <- length(labs)

# ---- Step 1: document x label cell means and their sampling variances --------
# M[d, l] = mean of the 12 scores judge j gave document d under label l
# N[d, l] = var of those scores / n  (squared standard error of the cell mean)
cells <- lapply(setNames(fams, fams), function(j) {
  s <- dv[dv$family == j, ]
  list(M = tapply(s$y, list(s$doc_id, s$lab), mean)[docs$doc_id, labs],
       N = tapply(s$y, list(s$doc_id, s$lab), function(x) var(x) / length(x))[docs$doc_id, labs],
       n = tapply(s$y, list(s$doc_id, s$lab), length)[docs$doc_id, labs])
})

# ---- Step 2: label effects per judge x document x label ----------------------
long <- do.call(rbind, lapply(fams, function(j) {
  M <- cells[[j]]$M; N <- cells[[j]]$N
  dev <- M - rowMeans(M)                               # label minus the document's own label mean
  vsn <- M - M[, "Neutral"]                            # label minus the neutral file name
  se_vsn <- sqrt(N + N[, "Neutral"])
  do.call(rbind, lapply(labs, function(l) data.frame(
    judge = j, docs[, c("doc_id", "brief_id", "generator", "genre")], label = l,
    mean_score = M[, l], se_mean = sqrt(N[, l]),
    effect_vs_neutral = vsn[, l], se_vs_neutral = if (l == "Neutral") NA else se_vsn[, l],
    z_vs_neutral = if (l == "Neutral") NA else vsn[, l] / se_vsn[, l],
    dev_from_doc_mean = dev[, l], row.names = NULL)))
}))
write.csv(long, file.path(out_dir, "doc_judge_label_effects.csv"), row.names = FALSE)

# ---- Step 3: one row per judge x document ------------------------------------
summ <- do.call(rbind, lapply(fams, function(j) {
  M <- cells[[j]]$M; N <- cells[[j]]$N; brief <- docs$brief_id
  dev <- M - rowMeans(M)
  # (a) size: label variance in this document, minus the noise that sampling
  #     alone would create in 8 cell means.   [mean of this column = label_var]
  label_var <- rowSums(dev^2) / (L - 1) - rowMeans(N)
  # (b) significance: do the 8 labels differ within this document? (Welch, as in Q1 descriptive)
  s <- dv[dv$family == j, ]
  # Classic one-way F test: the Welch version returns NaN whenever one label's 12
  # scores are all identical (common near Gemini's ceiling), which made the count NA.
  p_doc <- vapply(docs$doc_id, function(id) { z <- s[s$doc_id == id, ]
    tryCatch(oneway.test(y ~ lab, data = z, var.equal = TRUE)$p.value, error = function(e) NA_real_) }, 0)
  # (c) persistent part of this document's pattern: the judge's average label
  #     pattern in all OTHER briefs (leave-one-brief-out), so a document never
  #     predicts itself.  Brief-level patterns E[b, l] = mean dev over the docs of brief b.
  E <- rowsum(dev, brief) / as.vector(table(brief)[unique(sort(brief))])
  pred <- t(sapply(brief, function(b) colMeans(E[rownames(E) != b, , drop = FALSE])))
  persistent_var <- rowSums(pred^2) / (L - 1)
  specific_var   <- label_var - persistent_var
  data.frame(judge = j, docs, doc_mean = rowMeans(M),
             label_sd = sqrt(pmax(0, label_var)),
             gap_max_min = apply(M, 1, max) - apply(M, 1, min),
             p_raw = p_doc, p_bh = p.adjust(p_doc, "BH"),
             persistent_sd = sqrt(pmax(0, persistent_var)),
             specific_sd   = sqrt(pmax(0, specific_var)),
             persistent_share = pmin(1, pmax(0, persistent_var / pmax(label_var, 1e-12))),
             label_var = label_var, persistent_var = persistent_var, specific_var = specific_var,
             row.names = NULL)
}))
write.csv(summ, file.path(out_dir, "doc_judge_summary.csv"), row.names = FALSE)

# ---- Step 4: the bridge to the confirmatory decomposition --------------------
# Same function as analysis_study2.R.  total = mean of the document-level label
# variances; persistent = products of brief-level patterns from DIFFERENT briefs.
components <- function(M, N, brief) {
  dev <- M - rowMeans(M)
  total <- mean(rowSums(dev^2) / (L - 1) - rowMeans(N))
  E <- rowsum(dev, brief) / as.vector(table(brief)[unique(sort(brief))])
  B <- nrow(E)
  persist <- sum((colSums(E)^2 - colSums(E^2)) / (B * (B - 1))) / (L - 1)
  c(label_var = total, persistent_var = persist, specific_var = total - persist)
}
cat("\nJudge level (confirmatory formulas) vs. the document-level columns:\n")
chk <- do.call(rbind, lapply(fams, function(j) {
  cv <- components(cells[[j]]$M, cells[[j]]$N, docs$brief_id)
  s <- summ[summ$judge == j, ]
  data.frame(judge = j,
             label_var_confirmatory = cv[["label_var"]], mean_doc_label_var = mean(s$label_var),
             persistent_share_confirmatory = cv[["persistent_var"]] / cv[["label_var"]],
             mean_doc_persistent_share = mean(s$persistent_var) / mean(s$label_var),
             docs_significant_bh05 = sum(s$p_bh < 0.05, na.rm = TRUE),
             docs_test_undefined = sum(is.na(s$p_bh)))
}))
print(round(chk[, -1], 4), row.names = chk$judge)
cat("\nFiles written to", out_dir, "\n")
