# Called by the custom `knit:` function in paper.Rmd.
# Updates an existing readme.md only when rmarkdown::render() returns a PDF successfully.

compile_paper <- function(input) {
  input <- normalizePath(input, mustWork = TRUE)
  project_dir <- dirname(input)

  # Uses the PDF options specified in the document's YAML (template, engine, etc.).
  output <- rmarkdown::render(
    input = input,
    output_format = "pdf_document",
    quiet = FALSE,
    envir = new.env(parent = globalenv())
  )

  if (!length(output) || !file.exists(output) ||
      !identical(tolower(tools::file_ext(output)), "pdf")) {
    stop("PDF rendering did not produce a PDF; README was not updated.")
  }

  readme_path <- file.path(project_dir, "readme.md")
  # No README means no update; never create a new file.
  if (!file.exists(readme_path)) return(invisible(output))

  timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")
  r_version <- as.character(getRversion())
  tinytex_version <- if (requireNamespace("tinytex", quietly = TRUE)) {
    as.character(utils::packageVersion("tinytex"))
  } else {
    "not installed"
  }

  # TeX Live distribution version; not the same as the R package 'tinytex'.
  tlmgr <- Sys.which("tlmgr")
  texlive_version <- "unavailable"
  if (nzchar(tlmgr)) {
    info <- tryCatch(
      suppressWarnings(system2(tlmgr, "--version", stdout = TRUE, stderr = TRUE)),
      error = function(e) character()
    )
    matches <- regmatches(info, regexpr("TeX Live [0-9]{4}", info))
    matches <- matches[nzchar(matches)]
    if (length(matches)) texlive_version <- matches[1]
  }

  record <- sprintf(
    "%s last compiled on %s using R version %s, tinytex package version %s, and %s.",
    basename(input), timestamp, r_version, tinytex_version,
    if (identical(texlive_version, "unavailable"))
      "TeX Live version unavailable" else texlive_version
  )

  lines <- readLines(readme_path, warn = FALSE)
  prefix <- paste0(basename(input), " last compiled on ")
  old <- which(startsWith(lines, prefix))

  if (length(old)) {
    lines[old[1]] <- record
    if (length(old) > 1) lines <- lines[-old[-1]]
  } else {
    lines <- c(lines, if (length(lines)) "" else character(), record)
  }

  writeLines(lines, readme_path, useBytes = TRUE)
  message("Updated ", readme_path, " after successful PDF compilation.")
  invisible(output)
}
