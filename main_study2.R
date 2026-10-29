# ==============================================================================
# MAIN STUDY 2 - "Same Text, Different Filename", Study 2 (LLM-generated documents)
# Pre-registration: AsPredicted #[number] ([link])
#
# Three judges score 90 frozen LLM-written documents (30 briefs x 3 generators)
# under 8 labels, 12 repetitions each: 25,920 calls (8,640 per judge).
#
# Input : the output of generate_documents.R, in cfg2$gen_dir:
#           documents/<brief>_<family>.md, document_checksums.csv
#         Every document is checked against its frozen MD5 before any call.
#         Documents whose genre is "Pilot" are used only by the pilot.
# Delivery: as in Study 1, the label is sent inline as a header line,
#         "[Attached file: <name>]", above the document text.
# Schedule: repetition-major. Within each repetition the 720 document-label
#         cells are shuffled (fixed seed); repetitions run in order, so stopping
#         at any point leaves complete, balanced repetitions (preregistered
#         stopping rule).
# Files : one calls/raw file PER JUDGE, so the three judges can run in parallel
#         R sessions without writing to the same file (the Study 1 collision).
#
# Outputs (cfg2$out_dir):
#   schedule.csv            fixed before collection
#   documents.csv           the documents used, with checksums
#   calls_<family>.csv      one row per API call
#   raw_<family>.jsonl      full JSON response per call
#
# Depends: httr2, jsonlite
# Use    : see the bottom of this file.
# ==============================================================================

library(httr2)
library(jsonlite)
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

# ---------------------------------- Config ------------------------------------
cfg2 <- list(
  api_key   = Sys.getenv("OPENROUTER_API_KEY"),
  models    = c(openai    = "openai/gpt-6.1-sol",
                anthropic = "anthropic/claude-sonnet-5.5",
                google    = "google/gemini-4-argon"),
  labels    = c("Document.md",                 # neutral (reference)
                "Document_v2.md",              # placebo: names no source
                "Document_from_Sergey.md",
                "Document_from_Catherine.md",
                "Document_from_Chen.md",
                "Document_from_ChatGPT.md",
                "Document_from_Claude.md",
                "Document_from_Gemini.md"),
  gen_dir   = "results_study2",      # output of generate_documents.R
  n_briefs  = 30,                    # preregistered; checked before running
  n_reps    = 12,                    # preregistered
  seed      = 20261029,              # put this number in the preregistration (Q4)
  budget_usd = 60,                   # stop when total logged cost reaches this
  max_tokens = 1000,
  suppress_reasoning = TRUE,
  pause_sec = 0.5,
  out_dir   = "results_study2_main",
  pilot_dir = "results_study2_pilot",
  pilot_reps = 2,
  prompt    = paste(
    "Evaluate the attached document for quality of writing on a scale from 0 to 10.",
    "Use one decimal place. Do not elaborate, just return the number."
  )
)

digest_md5 <- function(x) {
  tf <- tempfile(); writeBin(charToRaw(enc2utf8(x)), tf)
  on.exit(unlink(tf)); unname(tools::md5sum(tf))
}
prompt_md5 <- digest_md5(cfg2$prompt)

# ----------------------- Documents: load and verify ---------------------------
load_docs <- function(pilot = FALSE) {
  sums <- read.csv(file.path(cfg2$gen_dir, "document_checksums.csv"), stringsAsFactors = FALSE)
  sums <- sums[if (pilot) sums$genre == "Pilot" else sums$genre != "Pilot", ]
  if (!nrow(sums)) stop("No ", if (pilot) "pilot " else "", "documents in ", cfg2$gen_dir)
  docs <- lapply(seq_len(nrow(sums)), function(i) {
    s <- sums[i, ]
    f <- file.path(cfg2$gen_dir, "documents", paste0(s$doc_id, ".md"))
    if (!file.exists(f)) stop("Missing document file: ", f)
    md5 <- unname(tools::md5sum(f))
    if (md5 != s$md5) stop("Checksum mismatch for ", s$doc_id,
                           ": the frozen text has changed. Investigate before running.")
    raw <- readBin(f, "raw", file.size(f)); txt <- rawToChar(raw); Encoding(txt) <- "UTF-8"
    list(id = s$doc_id, brief_id = s$brief_id, generator = s$generator,
         genre = s$genre, md5 = md5, words = s$words, text = txt)
  })
  names(docs) <- sums$doc_id
  # Design check: every brief has all three generators.
  tab <- table(sums$brief_id, sums$generator)
  if (any(tab != 1) || !setequal(colnames(tab), names(cfg2$models)))
    stop("Each brief needs exactly one document from each of: ",
         paste(names(cfg2$models), collapse = ", "))
  if (!pilot && nrow(tab) != cfg2$n_briefs)
    warning(sprintf("Found %d briefs; the preregistration says %d.", nrow(tab), cfg2$n_briefs),
            call. = FALSE, immediate. = TRUE)
  message(sprintf("Verified %d %sdocuments from %d briefs.", length(docs),
                  if (pilot) "pilot " else "", nrow(tab)))
  docs
}

# ------------------------------ Request building ------------------------------
build_content <- function(doc, filename, instruction) {
  list(list(type = "text", text = paste0(
    instruction, "\n\n[Attached file: ", filename, "]\n\n", doc$text)))
}

call_openrouter <- function(model, content) {
  body <- list(model = model,
               messages = list(list(role = "user", content = content)),
               max_tokens = cfg2$max_tokens,
               usage = list(include = TRUE))
  if (isTRUE(cfg2$suppress_reasoning)) body$reasoning <- list(exclude = TRUE)
  t0 <- Sys.time()
  resp <- tryCatch(
    request("https://openrouter.ai/api/v1/chat/completions") |>
      req_auth_bearer_token(cfg2$api_key) |>
      req_headers(`X-Title` = "filename-attribution-study2") |>
      req_body_json(body) |>
      req_timeout(300) |>
      req_retry(max_tries = 4,
                is_transient = \(r) resp_status(r) %in% c(408, 429, 500, 502, 503, 504),
                backoff = \(i) min(60, 5 * 2^(i - 1))) |>
      req_error(is_error = \(r) FALSE) |>
      req_perform(),
    error = identity)
  secs <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  if (inherits(resp, "error"))
    return(list(status = "request_error", http = NA, error = conditionMessage(resp),
                secs = secs, json = NULL))
  http <- resp_status(resp)
  j <- tryCatch(resp_body_json(resp), error = function(e) NULL)
  if (is.null(j) || http >= 400 || !is.null(j$error))
    return(list(status = if (http == 429) "rate_limited" else "api_error", http = http,
                error = if (is.null(j)) resp_body_string(resp)
                        else as.character(toJSON(j$error %||% j, auto_unbox = TRUE)),
                secs = secs, json = j))
  msg <- j$choices[[1]]$message$content
  if (is.list(msg)) msg <- paste(vapply(msg, \(p) p$text %||% "", ""), collapse = "")
  fin <- j$choices[[1]]$finish_reason %||% NA
  list(status = if (identical(fin, "length")) "truncated" else "ok",
       http = http, text = msg %||% "", secs = secs, json = j)
}

# --------------------------------- Parsing ------------------------------------
# PREREGISTERED: the score is the FIRST number in the reply, valid if in [0, 10].
parse_first <- function(txt) {
  if (is.null(txt) || !nzchar(txt)) return(NA_real_)
  m <- regmatches(txt, gregexpr("\\d+(\\.\\d+)?", txt))[[1]]
  if (!length(m)) return(NA_real_)
  x <- as.numeric(m[1])
  if (is.na(x) || x < 0 || x > 10) NA_real_ else x
}
parse_last <- function(txt) {
  if (is.null(txt) || !nzchar(txt)) return(NA_real_)
  t <- gsub("(?s)<think>.*?</think>", " ", txt, perl = TRUE)
  t <- gsub("(/\\s*10|out of 10)", " ", t, ignore.case = TRUE)
  t <- gsub("(?m)^\\s*\\d+\\s*[.)]\\s", " ", t, perl = TRUE)
  m <- as.numeric(regmatches(t, gregexpr("\\d+(\\.\\d+)?", t))[[1]])
  m <- m[!is.na(m) & m >= 0 & m <= 10]
  if (!length(m)) NA_real_ else tail(m, 1)
}
reply_shape <- function(txt) {
  if (is.null(txt) || !nzchar(trimws(txt))) return("empty")
  if (grepl("^\\d+(\\.\\d+)?$", trimws(txt))) "bare_number" else "prose"
}

# ----------------------------- Schedule ---------------------------------------
make_schedule <- function(docs, n_reps, out_dir) {
  p <- file.path(out_dir, "schedule.csv")
  if (file.exists(p)) {
    s <- read.csv(p, stringsAsFactors = FALSE)
    if (!setequal(unique(s$doc_id), names(docs)))
      stop("schedule.csv in ", out_dir, " was made for a different set of documents.")
    return(s)
  }
  set.seed(cfg2$seed)
  s <- do.call(rbind, lapply(names(cfg2$models), function(fam) {
    do.call(rbind, lapply(seq_len(n_reps), function(r) {
      cells <- expand.grid(doc_id = names(docs), label = cfg2$labels, stringsAsFactors = FALSE)
      cells <- cells[sample(nrow(cells)), ]            # random order within repetition
      data.frame(family = fam, model = unname(cfg2$models[fam]), rep = r,
                 doc_id = cells$doc_id, label = cells$label,
                 position = seq_len(nrow(cells)), row.names = NULL)
    }))
  }))
  s$trial_id <- sprintf("%s-r%02d-p%03d", s$family, s$rep, s$position)
  write.csv(s, p, row.names = FALSE)
  message("Schedule fixed: ", nrow(s), " calls -> ", p)
  s
}

calls_path <- function(out_dir, fam) file.path(out_dir, paste0("calls_", fam, ".csv"))

# A trial is done when it got a reply from the requested model (valid number or
# not: replies without a number are recorded, not re-run). Errors and replies
# from a different model are re-run.
done_trials <- function(out_dir, fam) {
  p <- calls_path(out_dir, fam)
  if (!file.exists(p)) return(character(0))
  prev <- read.csv(p, stringsAsFactors = FALSE)
  prev$trial_id[which(prev$status == "ok" & prev$model_returned == prev$model_requested)]
}

total_cost <- function(out_dir) {
  fs <- list.files(out_dir, "^calls_.*\\.csv$", full.names = TRUE)
  sum(vapply(fs, function(f) tryCatch(sum(read.csv(f)$cost_usd, na.rm = TRUE),
                                      error = function(e) 0), 0))
}

# ------------------------------ Data collection -------------------------------
# family = one of names(cfg2$models), or NULL for all (sequentially).
# Safe to stop and re-run: completed trials are skipped.
run <- function(family = NULL, pilot = FALSE, max_calls = Inf) {
  stopifnot("Set OPENROUTER_API_KEY in .Renviron" = nzchar(cfg2$api_key))
  out_dir <- if (pilot) cfg2$pilot_dir else cfg2$out_dir
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  docs <- load_docs(pilot)
  doc_tab <- data.frame(doc_id = names(docs),
                        brief_id = vapply(docs, `[[`, "", "brief_id"),
                        generator = vapply(docs, `[[`, "", "generator"),
                        genre = vapply(docs, `[[`, "", "genre"),
                        md5 = vapply(docs, `[[`, "", "md5"), row.names = NULL)
  write.csv(doc_tab, file.path(out_dir, "documents.csv"), row.names = FALSE)
  sched <- make_schedule(docs, if (pilot) cfg2$pilot_reps else cfg2$n_reps, out_dir)

  fams <- family %||% names(cfg2$models)
  # Judges are interleaved within each repetition, so a budget stop leaves every
  # judge with the same number of complete repetitions.
  spent <- total_cost(out_dir); t_start <- Sys.time(); fails <- 0
  for (pass in 1:3) {
    todo <- do.call(rbind, lapply(fams, function(fam)
      sched[sched$family == fam & !sched$trial_id %in% done_trials(out_dir, fam), ]))
    if (is.null(todo) || !nrow(todo)) { if (pass == 1) message("Nothing left to run."); break }
    todo <- todo[order(todo$rep, todo$position, todo$family), ]
    todo <- head(todo, max_calls)
    message(sprintf("%d calls to make (%s)%s", nrow(todo), paste(fams, collapse = ", "),
                    if (pass > 1) "; re-running failed or wrong-model trials" else ""))
    for (i in seq_len(nrow(todo))) {
      g <- todo[i, ]; fam <- g$family
      if (i %% 50 == 1) spent <- total_cost(out_dir)   # all judges' files
      if (!pilot && spent >= cfg2$budget_usd) {
        message(sprintf("Budget of $%.2f reached ($%.2f spent). Stopping; analysis uses complete repetitions.",
                        cfg2$budget_usd, spent))
        return(invisible(NULL))
      }
      d <- docs[[g$doc_id]]
      r <- call_openrouter(g$model, build_content(d, g$label, cfg2$prompt))
      j <- r$json
      txt <- if (r$status %in% c("ok", "truncated")) r$text else NA_character_
      row <- data.frame(
        trial_id = g$trial_id, family = fam, rep = g$rep, position = g$position,
        model_requested = g$model, model_returned = j$model %||% NA,
        provider = j$provider %||% NA, generation_id = j$id %||% NA,
        doc_id = g$doc_id, brief_id = d$brief_id, generator = d$generator, genre = d$genre,
        doc_md5 = d$md5, label = g$label, delivery = "text",
        max_tokens = cfg2$max_tokens, prompt_md5 = prompt_md5,
        timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
        response_secs = round(r$secs, 2), status = r$status, http_status = r$http %||% NA,
        raw_response = if (is.na(txt)) r$error else txt,
        score = if (r$status == "ok") parse_first(txt) else NA_real_,      # preregistered
        score_alt = if (r$status == "ok") parse_last(txt) else NA_real_,   # robustness
        reply_shape = if (is.na(txt)) NA_character_ else reply_shape(txt),
        finish_reason = j$choices[[1]]$finish_reason %||% NA,
        prompt_tokens = j$usage$prompt_tokens %||% NA,
        completion_tokens = j$usage$completion_tokens %||% NA,
        reasoning_tokens = j$usage$completion_tokens_details$reasoning_tokens %||% NA,
        cost_usd = j$usage$cost %||% NA,
        stringsAsFactors = FALSE)
      p <- calls_path(out_dir, fam); new <- !file.exists(p)
      write.table(row, p, sep = ",", row.names = FALSE, qmethod = "double",
                  col.names = new, append = !new, fileEncoding = "UTF-8")
      cat(toJSON(list(trial_id = row$trial_id, logged_at = row$timestamp, response = j),
                 auto_unbox = TRUE, null = "null"), "\n",
          file = file.path(out_dir, paste0("raw_", fam, ".jsonl")), append = TRUE, sep = "")
      spent <- spent + (row$cost_usd %||% 0)

      if (i %% 50 == 0 || i == nrow(todo)) {
        el <- as.numeric(difftime(Sys.time(), t_start, units = "mins"))
        message(sprintf("  %d/%d | rep %d | %.1f min | ~%.0f min left | $%.2f spent | %d failures",
                        i, nrow(todo), g$rep, el, el / i * (nrow(todo) - i), spent, fails))
      }
      if (r$status != "ok") {
        fails <- fails + 1
        message(sprintf("  [%s] %s / %s / %s", r$status, fam, g$doc_id, g$label))
        if (r$status == "rate_limited") { message("  Rate limited: pausing 60s."); Sys.sleep(60) }
        if (fails >= 20) { message("20 failures; stopping. Re-run to resume."); break }
      } else if (!identical(row$model_returned, g$model)) {
        message(sprintf("  [wrong model: %s] %s / %s / %s - will be re-run",
                        row$model_returned, fam, g$doc_id, g$label))
      }
      Sys.sleep(cfg2$pause_sec)
    }
    if (fails >= 20 || !is.finite(max_calls)) break
  }
  invisible(NULL)
}

# Projected cost of the main study from the pilot's logged costs.
estimate_cost <- function() {
  fs <- list.files(cfg2$pilot_dir, "^calls_.*\\.csv$", full.names = TRUE)
  if (!length(fs)) stop("Run the pilot first: run(pilot = TRUE)")
  d <- do.call(rbind, lapply(fs, read.csv, stringsAsFactors = FALSE))
  per_call <- tapply(d$cost_usd, d$family, mean, na.rm = TRUE)
  n_per_judge <- cfg2$n_briefs * 3 * length(cfg2$labels) * cfg2$n_reps
  est <- per_call * n_per_judge
  print(data.frame(judge = names(per_call), cost_per_call = signif(per_call, 3),
                   calls = n_per_judge, projected_usd = round(est, 2)), row.names = FALSE)
  cat(sprintf("Projected total: $%.2f (budget $%.2f). Pilot valid replies: %.1f%%\n",
              sum(est), cfg2$budget_usd, 100 * mean(!is.na(d$score))))
  invisible(est)
}

# ---------------------------------- Use ---------------------------------------
# 1. Generate and freeze documents with generate_documents.R (incl. one "Pilot" brief).
# 2. run(pilot = TRUE)        # pilot brief only, 2 reps, writes results_study2_pilot/
#    estimate_cost()          # projected cost of the main study from the pilot
# 3. Submit the preregistration (seed above in Q4).
# 4. run("openai"); run("anthropic"); run("google")
#    (or each in its own R session / RStudio background job; files do not collide)
# 5. source("analysis_study2.R")
