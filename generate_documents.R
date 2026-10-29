# ==============================================================================
# STUDY 2: DOCUMENT GENERATION
# "Same Text, Different Filename", Study 2 (LLM-generated documents)
#
# A small Shiny app. Type a brief, press Generate: the same brief goes to the
# three generator models via OpenRouter. Each text is checked against the
# preregistered rules; Freeze writes the three .md files and their checksums.
#
# Regeneration rules (match these to the preregistration, Q4):
#   * automatic: word count outside [400, 600], or a truncated/empty reply
#   * manual, with a logged reason: refusal, commentary about the task, or a
#     format violation (title, headings, lists)
#   * at most 3 regenerations per generator per brief; technical failures
#     (HTTP errors, rate limits) are retried separately and do not count
#   * texts are never edited, only trimmed of leading/trailing whitespace
#
# Audit trail (all in out_dir):
#   generation_log.csv      one row per API attempt, kept or not
#   generation_events.csv   manual flags (with reason), freezes and abandons
#   raw_generation.jsonl    full JSON response for every attempt
#   briefs.csv              one row per frozen brief
#   document_checksums.csv  doc_id, words, bytes, md5, sha256, attempt kept
#   documents/<brief>_<family>.md
#
# A brief ID can be used once. Abandoning a brief is logged and the ID stays
# used, so nothing can be silently regenerated from scratch.
#
# Depends: shiny, httr2, jsonlite, openssl
# Run:     source("generate_documents.R")   (opens the app)
# ==============================================================================

library(shiny)
library(httr2)
library(jsonlite)
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

# ---------------------------------- Config ------------------------------------
gcfg <- list(
  api_key    = Sys.getenv("OPENROUTER_API_KEY"),
  models     = c(openai    = "openai/gpt-6.1-sol",
                 anthropic = "anthropic/claude-sonnet-5.5",
                 google    = "google/gemini-4-argon"),
  genres     = c("Academic or teaching", "General-audience essay",
                 "Report or narrative", "Pilot"),
  word_min   = 400,
  word_max   = 600,
  max_regen  = 3,          # regenerations allowed per generator per brief
  max_tech   = 3,          # technical retries per attempt (not counted above)
  max_tokens = 4000,       # ~500 words is ~700 tokens; headroom for reasoning
  out_dir    = "results_study2",
  template   = paste(
    "Write an original piece of about 500 words on the following brief: %s.",
    "Write continuous prose with no title, headings or lists.",
    "Do not refer to yourself or to how the text was produced.",
    "Return only the text."
  ),
  flag_reasons = c("Refusal", "Commentary about the task",
                   "Format: title, headings or lists")
)

dir.create(file.path(gcfg$out_dir, "documents"), showWarnings = FALSE, recursive = TRUE)
log_path   <- file.path(gcfg$out_dir, "generation_log.csv")
raw_path   <- file.path(gcfg$out_dir, "raw_generation.jsonl")
brief_path <- file.path(gcfg$out_dir, "briefs.csv")
sum_path   <- file.path(gcfg$out_dir, "document_checksums.csv")

md5_text <- function(x) as.character(openssl::md5(enc2utf8(x)))
count_words <- function(txt) {
  if (is.null(txt) || !nzchar(trimws(txt))) return(0L)
  length(strsplit(trimws(txt), "\\s+")[[1]])
}
append_csv <- function(row, path) {
  new <- !file.exists(path)
  write.table(row, path, sep = ",", row.names = FALSE, qmethod = "double",
              col.names = new, append = !new, fileEncoding = "UTF-8")
}
read_log <- function() {
  if (!file.exists(log_path)) return(data.frame())
  read.csv(log_path, stringsAsFactors = FALSE)
}

# ------------------------------- API call -------------------------------------
call_openrouter <- function(model, prompt) {
  body <- list(model = model,
               messages = list(list(role = "user", content = prompt)),
               max_tokens = gcfg$max_tokens,
               reasoning = list(exclude = TRUE),
               usage = list(include = TRUE))
  resp <- tryCatch(
    request("https://openrouter.ai/api/v1/chat/completions") |>
      req_auth_bearer_token(gcfg$api_key) |>
      req_headers(`X-Title` = "filename-attribution-study2-generation") |>
      req_body_json(body) |>
      req_timeout(180) |>
      req_retry(max_tries = 3,
                is_transient = \(r) resp_status(r) %in% c(408, 429, 500, 502, 503, 504),
                backoff = \(i) min(60, 5 * 2^(i - 1))) |>
      req_error(is_error = \(r) FALSE) |>
      req_perform(),
    error = identity)
  if (inherits(resp, "error"))
    return(list(status = "request_error", error = conditionMessage(resp), json = NULL))
  j <- tryCatch(resp_body_json(resp), error = function(e) NULL)
  if (is.null(j) || resp_status(resp) >= 400 || !is.null(j$error))
    return(list(status = "api_error", json = j,
                error = if (is.null(j)) resp_body_string(resp)
                        else as.character(toJSON(j$error %||% j, auto_unbox = TRUE))))
  msg <- j$choices[[1]]$message$content
  if (is.list(msg)) msg <- paste(vapply(msg, \(p) p$text %||% "", ""), collapse = "")
  fin <- j$choices[[1]]$finish_reason %||% NA
  list(status = if (identical(fin, "length")) "truncated" else "ok",
       text = msg %||% "", json = j)
}

# ------------------------------- Checks ---------------------------------------
# Automatic rule: word count. Warnings: patterns that suggest a manual flag,
# shown to you but never acted on automatically.
check_text <- function(txt) {
  w <- count_words(txt)
  warn <- c(
    if (grepl("^\\s*#", txt, perl = TRUE) || grepl("(?m)^\\s*#{1,6}\\s", txt, perl = TRUE)) "markdown heading",
    if (grepl("(?m)^\\s*([-*•]|\\d+[.)])\\s", txt, perl = TRUE)) "list item",
    if (grepl("^[^\\n.!?]{3,90}\\n\\s*\\n", txt, perl = TRUE)) "possible title line",
    if (grepl("\\*\\*", txt)) "bold markup",
    if (grepl("(?i)\\b(here is|here's|as requested|word count|as an ai|language model|i can't|i cannot|i'm unable)\\b", txt, perl = TRUE)) "possible commentary or refusal"
  )
  list(words = w,
       auto_fail = w < gcfg$word_min || w > gcfg$word_max,
       auto_reason = if (w < gcfg$word_min || w > gcfg$word_max)
                       sprintf("word count %d outside [%d, %d]", w, gcfg$word_min, gcfg$word_max) else "",
       warnings = paste(warn, collapse = "; "))
}

# One attempt (with technical retries), logged whatever the outcome.
generate_attempt <- function(brief_id, family, brief, attempt, trigger) {
  model  <- gcfg$models[[family]]
  prompt <- sprintf(gcfg$template, brief)
  for (tech in seq_len(gcfg$max_tech + 1)) {
    r <- call_openrouter(model, prompt)
    j <- r$json
    txt <- if (identical(r$status, "ok")) trimws(r$text) else NA_character_
    ok  <- identical(r$status, "ok") && nzchar(txt %||% "")
    chk <- if (ok) check_text(txt) else list(words = NA, auto_fail = NA, auto_reason = "", warnings = "")
    row <- data.frame(
      event = "attempt", brief_id = brief_id, family = family,
      model_requested = model, model_returned = j$model %||% NA,
      provider = j$provider %||% NA, generation_id = j$id %||% NA,
      attempt = attempt, tech_try = tech, trigger = trigger,
      timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
      status = if (ok) "ok" else if (identical(r$status, "ok")) "empty" else r$status,
      error = if (ok) NA else substr(r$error %||% "", 1, 300),
      words = chk$words, auto_fail = chk$auto_fail, auto_reason = chk$auto_reason,
      warnings = chk$warnings, text_md5 = if (ok) md5_text(txt) else NA,
      prompt_md5 = md5_text(prompt),
      prompt_tokens = j$usage$prompt_tokens %||% NA,
      completion_tokens = j$usage$completion_tokens %||% NA,
      cost_usd = j$usage$cost %||% NA,
      stringsAsFactors = FALSE)
    append_csv(row, log_path)
    message(format(Sys.time(), "%H:%M:%S "), sprintf("%s / %s attempt %d try %d: %s%s",
            brief_id, family, attempt, tech, row$status,
            if (ok) paste0(", ", chk$words, " words") else paste0(" - ", row$error)))
    cat(toJSON(list(brief_id = brief_id, family = family, attempt = attempt,
                    tech_try = tech, response = j), auto_unbox = TRUE, null = "null"),
        "\n", file = raw_path, append = TRUE, sep = "")
    # Wrong model served: logged, then treated as a technical failure and retried.
    if (ok && !is.na(row$model_returned) && row$model_returned != model) ok <- FALSE
    if (ok) return(list(text = txt, check = chk, attempt = attempt, failed = FALSE,
                        model_returned = row$model_returned))
  }
  list(text = "", check = list(words = NA, auto_fail = NA, auto_reason = "technical failure",
                               warnings = ""), attempt = attempt, failed = TRUE)
}

# Generate for one family, regenerating automatically while the word rule fails.
generate_family <- function(brief_id, family, brief, start_attempt = 0, trigger = "initial") {
  a <- start_attempt
  repeat {
    res <- generate_attempt(brief_id, family, brief, a, trigger)
    if (res$failed || !isTRUE(res$check$auto_fail) || a >= gcfg$max_regen) return(res)
    a <- a + 1; trigger <- paste("auto:", res$check$auto_reason)
  }
}

freeze_brief <- function(brief_id, genre, brief, current) {
  docs <- lapply(names(gcfg$models), function(fam) {
    txt <- current[[fam]]$text
    f <- file.path(gcfg$out_dir, "documents", paste0(brief_id, "_", fam, ".md"))
    if (file.exists(f)) stop("File already exists: ", f, ". Frozen documents are never overwritten.")
    writeBin(charToRaw(enc2utf8(txt)), f)
    data.frame(doc_id = paste0(brief_id, "_", fam), brief_id = brief_id, genre = genre,
               generator = fam, model = gcfg$models[[fam]],
               attempt_kept = current[[fam]]$attempt, words = count_words(txt),
               bytes = file.size(f), md5 = unname(tools::md5sum(f)),
               sha256 = as.character(openssl::sha256(file(f))),
               stringsAsFactors = FALSE)
  })
  sums <- do.call(rbind, docs)
  for (i in seq_len(nrow(sums))) append_csv(sums[i, ], sum_path)
  append_csv(data.frame(brief_id = brief_id, genre = genre, brief = brief,
                        frozen_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
                        stringsAsFactors = FALSE), brief_path)
  sums
}

log_event <- function(event, brief_id, family = NA, reason = NA) {
  append_csv(data.frame(event = event, brief_id = brief_id, family = family,
                        reason = reason, timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
                        stringsAsFactors = FALSE),
             file.path(gcfg$out_dir, "generation_events.csv"))
}
used_brief_ids <- function() {
  ids <- character(0)
  lg <- read_log(); if (nrow(lg)) ids <- c(ids, lg$brief_id)
  ev <- file.path(gcfg$out_dir, "generation_events.csv")
  if (file.exists(ev)) ids <- c(ids, read.csv(ev, stringsAsFactors = FALSE)$brief_id)
  unique(ids)
}

# --------------------------------- App ----------------------------------------
fam_panel <- function(fam) {
  column(4,
    h4(gcfg$models[[fam]]),
    uiOutput(paste0("status_", fam)),
    tags$div(style = "max-height:420px; overflow-y:auto; white-space:pre-wrap;
                      border:1px solid #ccc; padding:8px; font-size:13px;",
             textOutput(paste0("text_", fam))),
    selectInput(paste0("reason_", fam), "Flag reason", choices = gcfg$flag_reasons),
    actionButton(paste0("flag_", fam), "Flag and regenerate")
  )
}

ui <- fluidPage(
  titlePanel("Study 2: document generation"),
  sidebarLayout(
    sidebarPanel(width = 3,
      textInput("brief_id", "Brief ID", placeholder = "B01, ..., B30; P01 for the pilot"),
      selectInput("genre", "Genre", choices = gcfg$genres),
      textAreaInput("brief", "Brief", rows = 6,
                    placeholder = "e.g. why the Cournot model predicts higher prices than Bertrand"),
      actionButton("go", "Generate", class = "btn-primary"),
      tags$hr(),
      actionButton("freeze", "Freeze all three", class = "btn-success"),
      actionButton("abandon", "Abandon brief", class = "btn-danger"),
      tags$hr(),
      textOutput("msg"),
      tags$hr(),
      textOutput("spend")
    ),
    mainPanel(width = 9, fluidRow(lapply(names(gcfg$models), fam_panel)))
  )
)

server <- function(input, output, session) {
  rv <- reactiveValues(active = NULL, frozen = FALSE, msg = "",
                       current = setNames(vector("list", 3), names(gcfg$models)),
                       tick = 0)

  output$msg <- renderText(rv$msg)
  output$spend <- renderText({
    rv$tick
    lg <- read_log()
    sprintf("Generation spend so far: $%.3f (%d attempts)",
            if (nrow(lg)) sum(lg$cost_usd, na.rm = TRUE) else 0, nrow(lg))
  })

  # Pop-up notifications reach the browser immediately, even while a long
  # generation is still running; the sidebar text only updates at the end.
  say <- function(msg, type = "message", duration = 10) {
    rv$msg <- msg
    showNotification(msg, type = type, duration = duration)
    message(format(Sys.time(), "%H:%M:%S "), msg)
  }

  observeEvent(input$go, {
    id <- trimws(input$brief_id %||% ""); brief <- trimws(input$brief %||% "")
    if (!nzchar(gcfg$api_key)) return(say("OPENROUTER_API_KEY is not set. Add it to .Renviron and restart R.", "error"))
    if (!grepl("^[A-Za-z0-9_-]+$", id)) return(say("Enter a brief ID: letters, digits, _ or - only.", "error"))
    if (!nzchar(brief)) return(say("Write a brief first.", "error"))
    if (id %in% used_brief_ids())
      return(say(paste0("Brief ID ", id, " is already used (generated, frozen or abandoned). Choose a new ID."), "error"))

    rv$active <- list(id = id, brief = brief, genre = input$genre)
    rv$frozen <- FALSE
    say(paste0("Sending brief ", id, " to three models, one after another. ",
               "This can take a few minutes."), duration = 20)
    ok <- tryCatch({
      withProgress(message = "Generating", value = 0, {
        for (fam in names(gcfg$models)) {
          setProgress(value = match(fam, names(gcfg$models)) - 1, detail = gcfg$models[[fam]])
          t0 <- Sys.time()
          res <- generate_family(id, fam, brief)
          rv$current[[fam]] <- res
          secs <- round(as.numeric(difftime(Sys.time(), t0, units = "secs")))
          if (res$failed) say(sprintf("%s failed (%d s). See the R console for the API error.", fam, secs), "error", 30)
          else say(sprintf("%s done: %s words (%d s).", fam, res$check$words, secs), duration = 8)
        }
      }, min = 0, max = 3)
      TRUE
    }, error = function(e) { say(paste("Error:", conditionMessage(e)), "error", NULL); FALSE })
    rv$tick <- rv$tick + 1
    failed <- names(Filter(\(x) isTRUE(x$failed), rv$current))
    if (ok && length(failed))
      say(paste0("Brief ", id, ": no text from ", paste(failed, collapse = ", "),
                 ". Check the R console, then abandon this brief and retry under a new ID."), "error", NULL)
    else if (ok) say(paste0("Generated brief ", id, ". Read all three, flag if needed, then freeze."))
  })

  lapply(names(gcfg$models), function(fam) {
    output[[paste0("text_", fam)]] <- renderText(rv$current[[fam]]$text %||% "")
    output[[paste0("status_", fam)]] <- renderUI({
      cur <- rv$current[[fam]]
      if (is.null(cur)) return(tags$p("Not generated yet."))
      chk <- cur$check
      ok <- !cur$failed && isFALSE(chk$auto_fail)
      tags$div(
        tags$p(tags$b(if (ok) "Passes word rule" else if (cur$failed) "Technical failure" else "FAILS word rule"),
               sprintf(" | %s words | regeneration %d of %d",
                       chk$words %||% NA, cur$attempt, gcfg$max_regen),
               style = paste0("color:", if (ok) "#1a7f37" else "#b42318")),
        if (nzchar(chk$warnings %||% "")) tags$p(paste("Check:", chk$warnings), style = "color:#b54708")
      )
    })
    observeEvent(input[[paste0("flag_", fam)]], {
      a <- rv$active; cur <- rv$current[[fam]]
      if (is.null(a) || is.null(cur) || rv$frozen) { rv$msg <- "Nothing to regenerate."; return() }
      if (cur$attempt >= gcfg$max_regen) {
        rv$msg <- paste0(fam, ": regeneration limit reached. Freeze as is, or abandon the brief.")
        return()
      }
      reason <- input[[paste0("reason_", fam)]]
      log_event("manual_flag", a$id, fam, reason)
      withProgress(message = paste("Regenerating", fam), value = 0.5, {
        rv$current[[fam]] <- generate_family(a$id, fam, a$brief, cur$attempt + 1,
                                             paste("manual:", reason))
      })
      rv$tick <- rv$tick + 1
      rv$msg <- paste0(fam, " regenerated (", reason, ").")
    })
  })

  observeEvent(input$freeze, {
    a <- rv$active
    if (is.null(a) || rv$frozen) { rv$msg <- "Nothing to freeze."; return() }
    bad <- names(Filter(\(x) is.null(x) || x$failed || !isFALSE(x$check$auto_fail), rv$current))
    if (length(bad)) {
      rv$msg <- paste("Cannot freeze: no valid text for", paste(bad, collapse = ", "),
                      "- abandon this brief instead.")
      return()
    }
    sums <- tryCatch(freeze_brief(a$id, a$genre, a$brief, rv$current),
                     error = function(e) { rv$msg <- conditionMessage(e); NULL })
    if (is.null(sums)) return()
    log_event("freeze", a$id)
    rv$frozen <- TRUE; rv$tick <- rv$tick + 1
    rv$msg <- sprintf("Frozen %s: %s words.", a$id, paste(sums$words, collapse = " / "))
  })

  observeEvent(input$abandon, {
    a <- rv$active
    if (is.null(a) || rv$frozen) { rv$msg <- "Nothing to abandon."; return() }
    showModal(modalDialog(
      title = paste("Abandon brief", a$id, "?"),
      textInput("abandon_reason", "Reason (logged)"),
      footer = tagList(modalButton("Cancel"), actionButton("abandon_ok", "Abandon"))))
  })
  observeEvent(input$abandon_ok, {
    removeModal()
    log_event("abandon", rv$active$id, reason = input$abandon_reason)
    rv$msg <- paste0("Abandoned ", rv$active$id, "; the ID stays used.")
    rv$active <- NULL
    rv$current <- setNames(vector("list", 3), names(gcfg$models))
  })
}

app <- shinyApp(ui, server)
if (!identical(Sys.getenv("GEN_TEST"), "1")) runApp(app, launch.browser = TRUE)
