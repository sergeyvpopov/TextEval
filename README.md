# TextEval: Same Text, Different Filename. Are LLMs Biased?

Code, data and analysis for an experiment on whether large language models score the *same* human-written text differently depending only on the file name attached to it.

**Author:** Sergey V. Popov (Cardiff University)
**Preregistration:** AsPredicted [#320377](https://aspredicted.org/vp8ez6.pdf) (current), which updates #314219 and #312192
**Data collection:** 27 October 2026, via OpenRouter
**Status:** collection and the registered analysis are complete; the paper is in preparation.

## What the experiment does

Four human-written documents are sent to three LLMs with the prompt

> Evaluate the attached document for quality of writing on a scale from 0 to 10. Use one decimal place. Do not elaborate, just return the number.

The text is identical in every call. Only the file name changes, across six conditions:

| Condition | File name |
|---|---|
| Neutral (reference) | `Document.md` |
| Sergey (human name) | `Document_from_Sergey.md` |
| Asian-coded human name | `Document_from_Chen.md` |
| AI, OpenAI | `Document_from_ChatGPT.md` |
| AI, Anthropic | `Document_from_Claude.md` |
| AI, Google | `Document_from_Gemini.md` |

Design: 4 documents x 6 conditions x 152 repetitions x 3 models = 10,944 calls (3,648 per model). Models: `openai/gpt-6.1-sol`, `anthropic/claude-sonnet-5.5`, `google/gemini-4-argon`. Every call is an independent conversation with no system prompt. Call order is randomised in a schedule fixed before collection (`results_main/schedule.csv`).

**How the file name is delivered.** OpenRouter strips file names from real attachments (checked by probes, see `results_main/probe_*` and `probe_direct_openrouter.csv`). The name is therefore sent inline as a header line, `[Attached file: <name>]`, above the document text. All three models reproduced the header correctly in the visibility check.

## Hypotheses

Estimated separately for each model by OLS on condition indicators with document fixed effects and HC3 standard errors. Two-sided, alpha = 0.05, Holm correction across the three models within each hypothesis.

| | Contrast |
|---|---|
| H1 | AI labels (mean of three) minus mean of Neutral and Sergey |
| H2 | Model's own-family label minus mean of the two rival-AI labels |
| H3 | Mean of the two rival-AI labels minus Neutral |
| H4 | Chen minus mean of Neutral and Sergey |
| H4b | Chen minus Sergey (supplementary) |

## Repository layout

| Path | What it is |
|---|---|
| `main_study.R` | Main data collection: configuration, prompt, schedule, API calls, logging, and a `run(<family>)` function. |
| `run_openai.R`, `run_anthropic.R`, `run_google.R` | One-line launchers, each calls `run()` for one model family. Safe to stop and restart; finished calls are skipped. |
| `analysis.R` | Registered analysis plus robustness checks. Reads `results_main/calls.csv`, writes to `analysis_output/`. Base R only. |
| `pre-registration-supplement.Rmd` | Decisions committed on 18 Sept 2026 before data collection (sample size, power, exclusions, schedule). Superseded in part by later registrations (see below). |
| `probe_direct.R` | Filename-visibility probes (direct APIs and OpenRouter Responses endpoint). `probe_direct_openrouter.csv` holds its output. |
| `practice_openrouter_free.R` | Pilot script run on a free model, used for pilot variance and parser testing. |
| `Document.pdf` | Tiny test PDF used only in the visibility probes. |
| `document_checksumsMD5.csv`, `document_checksumsSHA256.csv` | Checksums and descriptors (words, bytes, type, year) of the four frozen documents. |
| `results_main/` | Main study data (below). |
| `results_practice/`, `results_practice_v2/` | Pilot runs. Not used in the main analysis. |
| `analysis_output/` | Tables, figures, LaTeX fragments and log produced by `analysis.R`. |
| `TextEval.Rproj` | RStudio project file. |

### `results_main/`

| File | Content |
|---|---|
| `calls.csv` | One row per API call, 28 columns (below). The analysis input. |
| `raw.jsonl` | Full JSON response for every call. |
| `schedule.csv` | The randomised call schedule fixed before collection. |
| `documents.csv` | Frozen document checksums written on first run. |
| `probe_<model>_{text,file}.csv` | Filename-visibility checks, `file` = real attachment, `text` = inline header. |

Key columns of `calls.csv`: `trial_id`, `family`, `rep`, `position`, `model_requested`, `model_returned`, `provider`, `doc_id`, `doc_md5`, `label`, `delivery`, `prompt_md5`, `timestamp`, `status`, `reply`, `score` (first number in the reply; the registered score), `score_alt` (last number, robustness), `reply_shape`, `finish_reason`, token counts, `cost_usd`.

### `analysis_output/`

| File | Content |
|---|---|
| `hypothesis_tests.csv` | H1-H4b by model: estimate, SE, 95% CI, raw and Holm p, minimum detectable effect at 80% power, power at 0.10 points. |
| `condition_coefficients.csv` | Condition coefficients by model. |
| `descriptives.csv`, `per_document_h1.csv` | Descriptive tables; per-document AI-versus-Sergey contrast. |
| `fig1_condition_means.png`, `fig2_distributions.png` | Figures. |
| `table_hypotheses.tex`, `table_conditions.tex` | LaTeX tables. |
| `analysis_log.txt` | Full console log: collection diagnostics, descriptives, tests. |

## Reproducing the results

**Analysis only (no API key needed):**

```r
# from the project root, R >= 4.1, base R only
source("analysis.R")
```

**Re-running the collection** requires an OpenRouter key and the four source documents, which are not in this repository.

1. Put the documents in `documents/` as `Assignment.md`, `Book.md`, `Chess.md`, `Cournot.md` and check them against `document_checksumsMD5.csv`. The directory is git-ignored.
2. Add `OPENROUTER_API_KEY=...` to `.Renviron` (git-ignored) and restart R.
3. `install.packages(c("httr2", "jsonlite"))`.
4. Run `run_openai.R`, `run_anthropic.R`, `run_google.R` (for example as RStudio background jobs). Cost of the original run was about USD 36.

## Preregistration chain and deviations

1. **#312192** (18 Sept 2026): original registration, five labels. `pre-registration-supplement.Rmd` was committed the same day, before any main-study call.
2. **#314219**: adds the Chen condition (H4) and fixes 152 repetitions per cell.
3. **#320377**: delivery changed from file attachment to the inline header, because OpenRouter strips file names. This is the current registration.

The supplement still describes the earlier design (five labels, 150 repetitions, attachment delivery). Where it conflicts with the code or with #320377, the later registration and the code are authoritative.

## Notes on the data

- Routing was left to OpenRouter's defaults. Providers are logged per call; Sonnet always used Claude Platform on AWS, GPT-6.1 Sol almost always OpenAI, and Gemini-4 Argon was split between two Google routes.
- Scores are bunched in a narrow range (all scores between 2.5 and 6.8), so effects are small in absolute terms; see `analysis_log.txt` for residual SDs and minimum detectable effects.

## Licence and citation

- **Code** (`*.R`, `*.Rmd`, `TextEval.Rproj`): MIT, see [`LICENSE`](LICENSE).
- **Data and outputs** (`results_*`, `analysis_output/`, probe and checksum files): CC BY 4.0, see [`LICENSE-DATA.md`](LICENSE-DATA.md).
- The four source documents are not distributed and are not licensed here.

Citation: Popov, S. V. (2026). *Same Text, Different Filename: Are LLMs Biased?* Preregistration AsPredicted #320377. Add the preprint or DOI here once available.
