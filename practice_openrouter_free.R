# ==============================================================================
# Filename-attribution experiment via OpenRouter (practice / pilot runs)
#
# v2 (after the first pilot): reasoning models were truncating before they
# answered, and the parser was reading "1." out of their numbered thinking.
# Fixes: bigger token budget, optional reasoning suppression, a truncation
# check, a stricter parser, and a screen_models() helper to pick usable models.
#
# Folder layout expected (run from the project root / RStudio project):
#   documents/*.md                       <- git-ignored, frozen files
#   .Renviron with OPENROUTER_API_KEY=   <- git-ignored
#
# Outputs (in cfg$out_dir):
#   calls.csv       one row per API call: the tidy log you analyse
#   raw.jsonl       one line per call: the full JSON response
#   free_models.csv snapshot of free models available today
#
# install.packages(c("httr2", "jsonlite"))
# ==============================================================================

library(httr2)
library(jsonlite)
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

# ---------------------------------- Config ------------------------------------
cfg <- list(
  api_key   = Sys.getenv("OPENROUTER_API_KEY"),
  models    = c("REPLACE-WITH-A-MODEL"),   # see list_free_models() / screen_models()
  doc_dir   = "documents",
  labels    = c("Document.md",
                "Document_from_Sergey.md",
                "Document_from_ChatGPT.md",
                "Document_from_Claude.md",
                "Document_from_Gemini.md"),
  n_reps    = 1,          # 1 rep = n_docs x n_labels calls per model
  delivery  = "text",     # "text" works with any model; "file" = file content part
  max_tokens = 4000,      # reasoning models spent 1200-1700 tokens thinking in the pilot
  suppress_reasoning = TRUE,  # ask OpenRouter to drop reasoning from the reply
  pause_sec = 3.5,        # free tier: ~20 requests/minute
  seed      = 1,
  out_dir   = "results_practice_v2",
  prompt    = paste(
    "Evaluate the attached document for quality of writing on a scale from 0 to 10.",
    "Use one decimal place. Do not elaborate, just return the number."
  )
)

stopifnot("Set OPENROUTER_API_KEY in .Renviron" = nzchar(cfg$api_key))
dir.create(cfg$out_dir, showWarnings = FALSE)
csv_path <- file.path(cfg$out_dir, "calls.csv")
raw_path <- file.path(cfg$out_dir, "raw.jsonl")
digest_md5 <- function(x) {
  tf <- tempfile(); writeBin(charToRaw(enc2utf8(x)), tf)
  on.exit(unlink(tf)); unname(tools::md5sum(tf))
}
prompt_md5 <- digest_md5(cfg$prompt)

# -------------------------------- Documents -----------------------------------
doc_files <- list.files(cfg$doc_dir, pattern = "\\.md$", full.names = TRUE)
stopifnot("No .md files in documents/" = length(doc_files) > 0)
docs <- lapply(doc_files, function(f) {
  raw <- readBin(f, "raw", file.size(f))
  txt <- rawToChar(raw); Encoding(txt) <- "UTF-8"
  list(id = tools::file_path_sans_ext(basename(f)), raw = raw, text = txt,
       md5 = unname(tools::md5sum(f)))
})
names(docs) <- vapply(docs, `[[`, "", "id")
message("Loaded documents: ", paste(names(docs), collapse = ", "))

# --------------------------- Step 0: find free models -------------------------
list_free_models <- function() {
  j <- request("https://openrouter.ai/api/v1/models") |>
    req_auth_bearer_token(cfg$api_key) |> req_perform() |> resp_body_json()
  m <- do.call(rbind, lapply(j$data, function(x) data.frame(
    id = x$id, name = x$name %||% NA, context = x$context_length %||% NA,
    prompt_price = as.numeric(x$pricing$prompt %||% NA),
    completion_price = as.numeric(x$pricing$completion %||% NA),
    input_modalities = paste(unlist(x$architecture$input_modalities), collapse = ","),
    stringsAsFactors = FALSE)))
  free <- m[grepl(":free$", m$id) | (m$prompt_price == 0 & m$completion_price == 0), ]
  free <- free[order(free$id), ]
  write.csv(free, file.path(cfg$out_dir, "free_models.csv"), row.names = FALSE)
  free
}

# ------------------------------- API call -------------------------------------
build_content <- function(doc, filename, instruction) {
  if (cfg$delivery == "file") {
    list(list(type = "text", text = instruction),
         list(type = "file", file = list(
           filename  = filename,
           file_data = paste0("data:text/markdown;base64,", base64_enc(doc$raw)))))
  } else {
    list(list(type = "text", text = paste0(
      instruction, "\n\n[Attached file: ", filename, "]\n\n", doc$text)))
  }
}

call_openrouter <- function(model, content) {
  body <- list(model = model,
               messages = list(list(role = "user", content = content)),
               max_tokens = cfg$max_tokens,
               usage = list(include = TRUE))
  # Ask the provider not to return chain-of-thought. Support varies by model;
  # harmless where unsupported, and max_tokens is the real safety net.
  if (isTRUE(cfg$suppress_reasoning)) body$reasoning <- list(exclude = TRUE)
  
  t0 <- Sys.time()
  resp <- tryCatch(
    request("https://openrouter.ai/api/v1/chat/completions") |>
      req_auth_bearer_token(cfg$api_key) |>
      req_headers(`X-Title` = "filename-attribution-practice") |>
      req_body_json(body) |>
      req_timeout(300) |>
      req_retry(max_tries = 3,
                is_transient = \(r) resp_status(r) %in% c(408, 500, 502, 503, 504),
                backoff = \(i) 5 * i) |>
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
  # A reply cut off at max_tokens never reached its answer: do not score it.
  status <- if (identical(fin, "length")) "truncated" else "ok"
  list(status = status, http = http, text = msg %||% "", secs = secs, json = j)
}

# --------------------------------- Parsing ------------------------------------
# Returns c(score, note). note is "clean" when the whole reply is the number,
# "extracted" when a number had to be pulled out of surrounding text.
parse_score <- function(txt) {
  if (is.null(txt) || !nzchar(txt)) return(list(score = NA_real_, note = "empty"))
  trimmed <- trimws(txt)
  if (grepl("^\\d+(\\.\\d+)?$", trimmed)) {
    x <- as.numeric(trimmed)
    if (x >= 0 && x <= 10) return(list(score = x, note = "clean"))
  }
  t <- gsub("(?s)<think>.*?</think>", " ", trimmed, perl = TRUE)     # visible reasoning
  t <- gsub("(?s)<reasoning>.*?</reasoning>", " ", t, perl = TRUE)
  t <- gsub("(/\\s*10|out of 10)", " ", t, ignore.case = TRUE)        # "7.5/10" -> 7.5
  t <- gsub("(?m)^\\s*\\d+\\s*[.)]\\s", " ", t, perl = TRUE)          # drop "1." list numbering
  nums <- as.numeric(regmatches(t, gregexpr("\\d+(\\.\\d+)?", t))[[1]])
  nums <- nums[!is.na(nums) & nums >= 0 & nums <= 10]
  if (length(nums) == 0) return(list(score = NA_real_, note = "unparsed"))
  # the answer comes last, after any thinking the model printed
  list(score = tail(nums, 1), note = "extracted")
}

# ------------------------------- Logging --------------------------------------
log_call <- function(row, json) {
  new <- !file.exists(csv_path)
  write.table(row, csv_path, sep = ",", row.names = FALSE, qmethod = "double",
              col.names = new, append = !new, fileEncoding = "UTF-8")
  cat(toJSON(list(trial_id = row$trial_id, logged_at = row$timestamp, response = json),
             auto_unbox = TRUE, null = "null"), "\n",
      file = raw_path, append = TRUE, sep = "")
}

# ------------------- Step 1: is a model usable for this task? -----------------
# One call per model: reports latency, tokens, finish reason and whether the
# reply was a bare number. Run this before spending a rep on a model.
screen_models <- function(models, doc_id = names(docs)[1]) {
  res <- do.call(rbind, lapply(models, function(m) {
    r <- call_openrouter(m, build_content(docs[[doc_id]], "Document.md", cfg$prompt))
    p <- if (r$status %in% c("ok", "truncated")) parse_score(r$text)
    else list(score = NA_real_, note = r$status)
    Sys.sleep(cfg$pause_sec)
    data.frame(model = m, status = r$status, secs = round(r$secs, 1),
               completion_tokens = r$json$usage$completion_tokens %||% NA,
               reasoning_tokens = r$json$usage$completion_tokens_details$reasoning_tokens %||% NA,
               score = p$score, note = p$note,
               reply = substr(gsub("\\s+", " ", r$text %||% r$error %||% ""), 1, 60))
  }))
  print(res, row.names = FALSE)
  cat("\nUse models with status 'ok', note 'clean' and low latency.\n")
  invisible(res)
}

# ---------------------- Step 2: can the model see the filename? ---------------
probe_filename <- function(model, doc_id = names(docs)[1]) {
  q <- "What is the exact filename of the attached document? Reply with the filename only."
  out <- lapply(cfg$labels, function(lab) {
    r <- call_openrouter(model, build_content(docs[[doc_id]], lab, q))
    Sys.sleep(cfg$pause_sec)
    reply <- if (r$status %in% c("ok", "truncated")) trimws(r$text) else r$error
    data.frame(model = model, label = lab, status = r$status,
               reply = substr(reply, 1, 120),
               seen = r$status == "ok" && grepl(lab, reply, fixed = TRUE))
  })
  res <- do.call(rbind, out); print(res[, c("label", "status", "seen", "reply")],
                                    row.names = FALSE)
  write.csv(res, file.path(cfg$out_dir, paste0("filename_probe_", cfg$delivery, ".csv")),
            row.names = FALSE)
  invisible(res)
}

# ------------------------------ Step 3: run -----------------------------------
run <- function() {
  set.seed(cfg$seed)
  grid <- expand.grid(model = cfg$models, rep = seq_len(cfg$n_reps),
                      doc_id = names(docs), label = cfg$labels, stringsAsFactors = FALSE)
  grid <- do.call(rbind, lapply(split(grid, list(grid$model, grid$rep)),
                                \(b) b[sample(nrow(b)), ]))
  run_id <- format(Sys.time(), "%Y%m%d-%H%M%S")
  grid$trial_id <- paste(run_id, seq_len(nrow(grid)), sep = "-")
  grid$position <- ave(seq_len(nrow(grid)), grid$model, grid$rep, FUN = seq_along)
  
  for (i in seq_len(nrow(grid))) {
    g <- grid[i, ]; d <- docs[[g$doc_id]]
    r <- call_openrouter(g$model, build_content(d, g$label, cfg$prompt))
    j <- r$json
    p <- if (r$status == "ok") parse_score(r$text) else list(score = NA_real_, note = r$status)
    row <- data.frame(
      run_id = run_id, trial_id = g$trial_id, rep = g$rep, position = g$position,
      model_requested = g$model, model_returned = j$model %||% NA,
      provider = j$provider %||% NA, generation_id = j$id %||% NA,
      doc_id = g$doc_id, doc_md5 = d$md5, label = g$label,
      delivery = cfg$delivery, max_tokens = cfg$max_tokens,
      suppress_reasoning = isTRUE(cfg$suppress_reasoning), prompt_md5 = prompt_md5,
      timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
      response_secs = round(r$secs, 2), status = r$status, http_status = r$http,
      raw_response = if (r$status %in% c("ok", "truncated")) r$text else r$error,
      score = p$score, parse_note = p$note,
      finish_reason = j$choices[[1]]$finish_reason %||% NA,
      prompt_tokens = j$usage$prompt_tokens %||% NA,
      completion_tokens = j$usage$completion_tokens %||% NA,
      reasoning_tokens = j$usage$completion_tokens_details$reasoning_tokens %||% NA,
      cost_usd = j$usage$cost %||% NA,
      stringsAsFactors = FALSE)
    log_call(row, j)
    message(sprintf("[%d/%d] %-26s %-11s %-25s %-9s -> %s", i, nrow(grid), g$model,
                    g$doc_id, g$label, r$status,
                    ifelse(is.na(p$score), "-", format(p$score))))
    
    if (r$status == "rate_limited") {
      message("Rate limited (free tier: ~20/min, 50/day without credits; upstream ",
              "providers have their own caps). Stopping; re-run later or try another model.")
      break
    }
    if (r$status == "truncated")
      message("   ^ reply hit max_tokens before answering: raise cfg$max_tokens ",
              "or use a non-reasoning model.")
    Sys.sleep(cfg$pause_sec)
  }
}

# ------------------------------ Step 4: look ----------------------------------
summarise_calls <- function() {
  d <- read.csv(csv_path, stringsAsFactors = FALSE)
  cat("Calls by status:\n"); print(table(d$status))
  if ("parse_note" %in% names(d)) {
    cat("\nHow each score was read:\n"); print(table(d$parse_note, useNA = "ifany"))
  }
  ok <- d[d$status == "ok" & !is.na(d$score), ]
  if (!nrow(ok)) { cat("\nNo usable scores yet.\n"); return(invisible(d)) }
  cat("\nMean score by document and label:\n")
  print(round(tapply(ok$score, list(ok$doc_id, ok$label), mean), 2))
  cat("\nPrompt tokens by document and label (should differ only by a few tokens):\n")
  print(tapply(ok$prompt_tokens, list(ok$doc_id, ok$label), mean))
  cat("\nMedian seconds per call:", round(median(ok$response_secs), 1),
      "| total cost so far:", sum(d$cost_usd, na.rm = TRUE), "\n")
  invisible(d)
}

# ---------------------------------- Use ---------------------------------------
# free <- list_free_models(); View(free)
# screen_models(c("vendor/model-a:free", "vendor/model-b:free"))  # 1 call each
# cfg$models <- c("the model that passed")
# probe_filename(cfg$models[1])
# run()
# summarise_calls()