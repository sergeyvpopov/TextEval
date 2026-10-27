# ==============================================================================
# DIRECT-API FILENAME PROBE  (OpenAI / Anthropic / Google)
#
# Question: when a file is attached through the provider's own API, does the
# model SEE the filename we give it?  OpenRouter strips it, so this has to be
# tested provider by provider before any data collection.
#
# Each test sends one labelled attachment and asks
#   "What is the exact filename of the attached document? Reply with the filename only."
# and checks whether the reply contains the exact label.  ~5 calls per variant.
# Cost: a few cents in total.  Nothing here writes to results_main/.
#
# Setup (in .Renviron, then restart R):
#   OPENAI_API_KEY=...   ANTHROPIC_API_KEY=...   GEMINI_API_KEY=...
#
# Model ids: DIRECT-API ids differ from OpenRouter's (Anthropic uses hyphens,
# e.g. claude-sonnet-5-5). Check each provider's model list and edit `mdl`.
#
# Usage:
#   source("probe_direct.R")
#   probe_openrouter()   # run this FIRST: one key (OPENROUTER_API_KEY), all three models
#   probe_openai();  probe_anthropic();  probe_google()   # direct APIs, only if needed
# Each returns a data frame and prints share seen per variant and label.
# ==============================================================================

library(httr2)
library(jsonlite)
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

mdl <- list(openai    = "gpt-6.1-sol",          # verify on platform.openai.com
            anthropic = "claude-sonnet-5-5",    # verify on platform.claude.com
            google    = "gemini-4-argon")       # verify via the Gemini models list

doc_path <- "documents/Cournot.md"   # any one of your frozen documents; short is fine
labels <- c("Document.md", "Document_from_Sergey.md", "Document_from_Chen.md",
            "Document_from_ChatGPT.md", "Document_from_Claude.md",
            "Document_from_Gemini.md")
reps <- 2
q <- "What is the exact filename of the attached document? Reply with the filename only."

stopifnot(file.exists(doc_path))
doc_raw <- readBin(doc_path, "raw", file.size(doc_path))
b64 <- function(x) gsub("[\r\n ]", "", jsonlite::base64_enc(x))
key <- function(n) { k <- Sys.getenv(n); if (!nzchar(k)) stop("Set ", n, " in .Renviron"); k }

post_json <- function(url, headers, body) {
  req <- request(url) |> req_headers(!!!headers) |> req_body_json(body, auto_unbox = TRUE) |>
    req_timeout(180) |> req_error(is_error = \(r) FALSE)
  r <- tryCatch(req_perform(req), error = identity)
  if (inherits(r, "error")) return(list(ok = FALSE, text = conditionMessage(r)))
  list(ok = resp_status(r) < 400, text = resp_body_string(r), http = resp_status(r))
}

# Run one variant over all labels; `send(label)` must return a list(ok, reply).
run_variant <- function(provider, variant, send) {
  out <- do.call(rbind, lapply(labels, function(lab) {
    do.call(rbind, lapply(seq_len(reps), function(i) {
      r <- tryCatch(send(lab), error = function(e) list(ok = FALSE, reply = conditionMessage(e)))
      Sys.sleep(0.5)
      data.frame(provider = provider, variant = variant, label = lab, rep = i, ok = r$ok,
                 seen = isTRUE(r$ok) && grepl(lab, r$reply, fixed = TRUE),
                 reply = substr(gsub("\\s+", " ", r$reply), 1, 100))
    }))
  }))
  cat("\n---", provider, "|", variant, "---\n")
  print(aggregate(cbind(ok, seen) ~ label, data = transform(out, ok = as.numeric(ok),
                                                              seen = as.numeric(seen)), FUN = mean),
        row.names = FALSE)
  cat("Example reply:", out$reply[nrow(out)], "\n")
  out
}

save_probe <- function(res, name) {
  f <- paste0("probe_direct_", name, ".csv"); write.csv(res, f, row.names = FALSE)
  cat("Saved:", f, "\n"); invisible(res)
}

# ---------------------------------- OpenAI -------------------------------------
# Responses API, input_file with an explicit `filename`.
probe_openai <- function(model = mdl$openai) {
  h <- list(Authorization = paste("Bearer", key("OPENAI_API_KEY")))
  txt <- function(r) {                       # extract the output text from a Responses reply
    j <- fromJSON(r$text, simplifyVector = FALSE)
    if (!is.null(j$error)) return(toJSON(j$error, auto_unbox = TRUE))
    paste(unlist(lapply(j$output, \(o) lapply(o$content, \(c) c$text))), collapse = "")
  }
  v1 <- run_variant("openai", "input_file base64 + filename", function(lab) {
    body <- list(model = model, max_output_tokens = 200,
      input = list(list(role = "user", content = list(
        list(type = "input_file", filename = lab,
             file_data = paste0("data:text/markdown;base64,", b64(doc_raw))),
        list(type = "input_text", text = q)))))
    r <- post_json("https://api.openai.com/v1/responses", h, body)
    list(ok = r$ok, reply = if (r$ok) txt(r) else r$text)
  })
  save_probe(v1, "openai")
}

# --------------------------------- Anthropic -----------------------------------
# Messages API. Variants: base64 text/plain document with `title`;
# Files API upload (filename set on upload) referenced by file_id.
probe_anthropic <- function(model = mdl$anthropic) {
  h <- list(`x-api-key` = key("ANTHROPIC_API_KEY"), `anthropic-version` = "2023-06-01")
  txt <- function(r) {
    j <- fromJSON(r$text, simplifyVector = FALSE)
    if (!is.null(j$error)) return(toJSON(j$error, auto_unbox = TRUE))
    paste(vapply(j$content, \(c) c$text %||% "", ""), collapse = "")
  }
  msg <- function(block_list) {
    body <- list(model = model, max_tokens = 200,
      messages = list(list(role = "user", content = c(block_list, list(list(type = "text", text = q))))))
    r <- post_json("https://api.anthropic.com/v1/messages", h, body)
    list(ok = r$ok, reply = if (r$ok) txt(r) else r$text)
  }
  v1 <- run_variant("anthropic", "base64 text/plain + title", function(lab)
    msg(list(list(type = "document", title = lab,
                  source = list(type = "base64", media_type = "text/plain",
                                data = b64(doc_raw))))))
  v2 <- run_variant("anthropic", "control: no title, no filename", function(lab)
    msg(list(list(type = "document",
                  source = list(type = "base64", media_type = "text/plain",
                                data = b64(doc_raw))))))
  # Files API: upload once per label, filename set via the multipart part name
  upload <- function(lab) {
    tf <- file.path(tempdir(), lab); writeBin(doc_raw, tf)
    r <- request("https://api.anthropic.com/v1/files") |> req_headers(!!!h) |>
      req_body_multipart(file = curl::form_file(tf, type = "text/plain", name = lab)) |>
      req_error(is_error = \(r) FALSE) |> req_perform()
    fromJSON(resp_body_string(r), simplifyVector = FALSE)
  }
  ids <- list()
  v3 <- run_variant("anthropic", "Files API file_id (filename at upload)", function(lab) {
    if (is.null(ids[[lab]])) ids[[lab]] <<- upload(lab)
    f <- ids[[lab]]
    if (is.null(f$id)) return(list(ok = FALSE, reply = toJSON(f, auto_unbox = TRUE)))
    msg(list(list(type = "document", source = list(type = "file", file_id = f$id))))
  })
  save_probe(rbind(v1, v2, v3), "anthropic")
}

# ----------------------------------- Google ------------------------------------
# Files API upload with display_name, then generateContent with file_data.
probe_google <- function(model = mdl$google) {
  k <- key("GEMINI_API_KEY"); base <- "https://generativelanguage.googleapis.com"
  upload <- function(lab) {
    r <- request(paste0(base, "/upload/v1beta/files")) |>
      req_headers(`x-goog-api-key` = k, `X-Goog-Upload-Protocol` = "resumable",
                  `X-Goog-Upload-Command` = "start",
                  `X-Goog-Upload-Header-Content-Length` = as.character(length(doc_raw)),
                  `X-Goog-Upload-Header-Content-Type` = "text/plain") |>
      req_body_json(list(file = list(display_name = lab)), auto_unbox = TRUE) |>
      req_error(is_error = \(r) FALSE) |> req_perform()
    url <- resp_header(r, "x-goog-upload-url")
    if (is.null(url)) stop("No upload url: ", resp_body_string(r))
    r2 <- request(url) |>
      req_headers(`Content-Length` = as.character(length(doc_raw)),
                  `X-Goog-Upload-Offset` = "0", `X-Goog-Upload-Command` = "upload, finalize") |>
      req_body_raw(doc_raw, type = "text/plain") |>
      req_error(is_error = \(r) FALSE) |> req_perform()
    fromJSON(resp_body_string(r2), simplifyVector = FALSE)$file
  }
  uris <- list()
  v1 <- run_variant("google", "Files API display_name + file_data", function(lab) {
    if (is.null(uris[[lab]])) uris[[lab]] <<- upload(lab)
    f <- uris[[lab]]
    body <- list(contents = list(list(parts = list(
      list(file_data = list(mime_type = "text/plain", file_uri = f$uri)),
      list(text = q)))))
    r <- post_json(paste0(base, "/v1beta/models/", model, ":generateContent"),
                   list(`x-goog-api-key` = k), body)
    reply <- if (r$ok) {
      j <- fromJSON(r$text, simplifyVector = FALSE)
      paste(unlist(lapply(j$candidates[[1]]$content$parts, \(p) p$text)), collapse = "")
    } else r$text
    list(ok = r$ok, reply = reply)
  })
  save_probe(v1, "google")
}

# ------------------------- OpenRouter Responses endpoint ------------------------
# Same OpenAI-style input_file shape, but through OpenRouter (/api/v1/responses),
# so one key covers all three models. Tests whether THIS route keeps the filename,
# unlike chat completions (which turned the file into plain text).
# Usage: probe_openrouter()                      # all three models in cfg-style ids
#        probe_openrouter("anthropic/claude-sonnet-5.5")
or_models <- c("openai/gpt-6.1-sol", "anthropic/claude-sonnet-5.5", "google/gemini-4-argon")

probe_openrouter <- function(models = or_models, mimes = c("text/markdown", "text/plain")) {
  h <- list(Authorization = paste("Bearer", key("OPENROUTER_API_KEY")))
  txt <- function(r) {
    j <- fromJSON(r$text, simplifyVector = FALSE)
    if (!is.null(j$error)) return(toJSON(j$error, auto_unbox = TRUE))
    paste(unlist(lapply(j$output, \(o) lapply(o$content, \(c) c$text))), collapse = "")
  }
  res <- do.call(rbind, lapply(models, function(m) {
    do.call(rbind, lapply(mimes, function(mime) {
      run_variant(paste0("openrouter:", m), paste("responses input_file,", mime), function(lab) {
        body <- list(model = m, max_output_tokens = 300,
          input = list(list(type = "message", role = "user", content = list(
            list(type = "input_text", text = q),
            list(type = "input_file", filename = lab,
                 file_data = paste0("data:", mime, ";base64,", b64(doc_raw)))))))
        r <- post_json("https://openrouter.ai/api/v1/responses", h, body)
        list(ok = r$ok, reply = if (r$ok) txt(r) else r$text)
      })
    }))
  }))
  save_probe(res, "openrouter")
}
