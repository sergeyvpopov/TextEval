# TextEval: Same Text, Different Filename. Are LLMs Biased?

Code, data and analysis for two experiments on whether large language models change their quality scores for a text depending on a label attached to it.

- **Study 1** (complete): four human-written documents, scored under six labels that differ only in the file name.
- **Study 2** (preregistration pending): 90 LLM-written documents, scored under eight labels, asking whether label effects exist, how large they are, and whether they persist across documents.

**Author:** Sergey V. Popov (Cardiff University)
**Study 1 preregistration:** AsPredicted [#320377](https://aspredicted.org/vp8ez6.pdf), which updates #314219 and #312192
**Study 2 preregistration:** AsPredicted [#[number, added on registration]]
**Study 1 data collection:** 27 October 2026, via OpenRouter
**Status:** Study 1 collection and the registered analysis are complete; the paper is in preparation. Study 2 is designed and piloted but not yet registered or collected.

---

## Study 1: human-written documents

### What the experiment does

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

Design: 4 documents × 6 conditions × 152 repetitions × 3 models = 10,944 calls (3,648 per model). Models: `openai/gpt-6.1-sol`, `anthropic/claude-sonnet-5.5`, `google/gemini-4-argon`. Every call is an independent conversation with no system prompt. Call order is randomised in a schedule fixed before collection (`results_main/schedule.csv`).

**How the file name is delivered.** OpenRouter strips file names from real attachments (checked by probes, see `results_main/probe_*` and `probe_direct_openrouter.csv`). The name is therefore sent inline as a header line, `[Attached file: <name>]`, above the document text. All three models reproduced the header correctly in the visibility check.

### Hypotheses (Study 1)

Estimated separately for each model by OLS on condition indicators with document fixed effects and HC3 standard errors. Two-sided, alpha = 0.05, Holm correction across the three models within each hypothesis.

| | Contrast |
|---|---|
| H1 | AI labels (mean of three) minus mean of Neutral and Sergey |
| H2 | Model's own-family label minus mean of the two rival AI labels |
| H3 | Mean of the two rival AI labels minus Neutral |
| H4 | Chen minus mean of Neutral and Sergey |
| H4b | Chen minus Sergey (supplementary) |

### Repository layout (Study 1)

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
| `results_main/` | Study 1 data (below). |
| `results_practice/`, `results_practice_v2/` | Pilot runs. Not used in the main analysis. |
| `analysis_output/` | Tables, figures, LaTeX fragments and log produced by `analysis.R`. |
| `TextEval.Rproj` | RStudio project file. |

### `results_main/` (Study 1)

| File | Content |
|---|---|
| `calls.csv` | One row per logged call (10,953 rows for 10,944 trials; see the note below). The analysis input. |
| `raw.jsonl` | Full JSON response for every call. |
| `schedule.csv` | The randomised call schedule fixed before collection. |
| `documents.csv` | Frozen document checksums written on first run. |
| `probe_<model>_{text,file}.csv` | Filename-visibility checks, `file` = real attachment, `text` = inline header. |

Key columns of `calls.csv`: `trial_id`, `family`, `rep`, `position`, `model_requested`, `model_returned`, `provider`, `doc_id`, `doc_md5`, `label`, `delivery`, `prompt_md5`, `timestamp`, `status`, `reply`, `score` (first number in the reply; the registered score), `score_alt` (last number, robustness), `reply_shape`, `finish_reason`, token counts, `cost_usd`.

**Duplicate records.** Nine trials (`openai-0002-21` to `openai-0002-24` and `openai-0003-01` to `openai-0003-05`) were logged twice, a few seconds apart, and both records are valid. The analysis keeps the later record for each trial (`!duplicated(trial_id, fromLast = TRUE)`). The paper's account of the 5 re-run failures is separate from these duplicates.

### `analysis_output/` (Study 1)

| File | Content |
|---|---|
| `hypothesis_tests.csv` | H1–H4b by model: estimate, SE, 95% CI, raw and Holm p, minimum detectable effect at 80% power, power at 0.10 points. |
| `condition_coefficients.csv` | Condition coefficients by model. |
| `descriptives.csv`, `per_document_h1.csv` | Descriptive tables; per-document AI-versus-Sergey contrast. |
| `fig1_condition_means.png`, `fig2_distributions.png` | Figures. |
| `table_hypotheses.tex`, `table_conditions.tex` | LaTeX tables. |
| `analysis_log.txt` | Full console log: collection diagnostics, descriptives, tests. |

### Reproducing Study 1

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

### Preregistration chain and deviations (Study 1)

1. **#312192** (18 Sept 2026): original registration, five labels. `pre-registration-supplement.Rmd` was committed the same day, before any main-study call.
2. **#314219**: adds the Chen condition (H4) and fixes 152 repetitions per cell.
3. **#320377**: delivery changed from file attachment to the inline header, because OpenRouter strips file names. This is the current registration.

The supplement still describes the earlier design (five labels, 150 repetitions, attachment delivery). Where it conflicts with the code or with #320377, the later registration and the code are authoritative.

### Notes on the Study 1 data

- Routing was left to OpenRouter's defaults. Providers are logged per call; Sonnet always used Claude Platform on AWS, GPT-6.1 Sol almost always OpenAI, and Gemini-4 Argon was split between two Google routes.
- Scores are bunched in a narrow range (all scores between 2.5 and 6.8), so effects are small in absolute terms; see `analysis_log.txt` for residual SDs and minimum detectable effects.

---

## Study 2: LLM-generated documents

**Ethics:** Study 2 is covered by Cardiff Business School SREC approval #3355. The committee confirmed by email on [date of confirmation] that no further approval is needed.

### What the experiment asks

Study 1 used four human-written texts. Study 2 uses texts written by the judge models themselves, so it can test whether a judge rewards its own writing and whether label effects are consistent across documents. It asks three questions about each judge:

- **Q1 (existence).** Do labels change a judge's scores within documents?
- **Q2 (size).** How large are label effects within a document, in points and relative to how much documents differ?
- **Q3 (persistence).** Are label effects common to all documents or specific to each document? Three named persistent biases are tested:
  - **H5 self-recognition:** under the neutral label, a judge scores its own family's documents higher than rival documents on the same brief.
  - **H6 own label on own text:** on its own family's documents, a judge scores its own-family label higher than the two rival AI labels.
  - **H7 AI labels versus human names:** on all documents, a judge scores the three AI labels lower than the three human-name labels.

### Design (Study 2)

- **Briefs:** 30 writing prompts, 10 each in three genres (academic or teaching material, general-audience essays, reports or narratives).
- **Generators:** each brief is written once by each of the three models, giving 90 documents. Generation settings and the regeneration rules are in `generate_documents.R` and the registration.
- **Labels (8):** `Document.md` (neutral), `Document_v2.md` (placebo that names no source), `Document_from_Sergey.md`, `Document_from_Catherine.md`, `Document_from_Chen.md`, `Document_from_ChatGPT.md`, `Document_from_Claude.md`, `Document_from_Gemini.md`.
- **Judges (3):** `openai/gpt-6.1-sol`, `anthropic/claude-sonnet-5.5`, `google/gemini-4-argon`, via OpenRouter.
- **Repetitions:** 12 per document × label × judge, so 30 × 3 × 8 × 3 × 12 = **25,920 calls** (8,640 per judge). Judges are interleaved within each repetition, so a budget stop leaves all three with the same number of complete repetitions.
- **Delivery:** as in Study 1, the label is an inline header, `[Attached file: <label>]`, above the text.
- **Spending cap:** USD 60 (`budget_usd` in `main_study2.R`). The pilot projected about USD 51.

The pilot (one extra brief, three documents, two repetitions, 144 calls, about USD 0.57) is excluded from all analyses and is not part of the design above.

### Files (Study 2)

| Path | What it is |
|---|---|
| `generate_documents.R` | Shiny app. Enter a brief; the same brief is sent to the three generators via OpenRouter. Applies the word-count rule, logs manual flags, freezes the texts with MD5 and SHA256 checksums, and logs abandoned briefs. Never overwrites a frozen file. |
| `main_study2.R` | Data collection. Verifies every document against its frozen checksum before any call, fixes the schedule with seed 20261029, writes one calls file per judge, and stops at the spending cap. `run(pilot = TRUE)` and `estimate_cost()` run the pilot and project the main study's cost. |
| `analysis_study2.R` | Analysis, organised by Q1, Q2 and Q3, with the named biases, robustness checks (a)–(d) and exploratory analyses. Reads `results_study2_main/`, writes to `analysis_output_study2/`. |

Outputs (created by the scripts, not all committed):

| Path | Content |
|---|---|
| `results_study2/generation_log.csv`, `generation_events.csv`, `raw_generation.jsonl` | Every generation attempt, manual flags, freezes and abandoned briefs. The audit trail. |
| `results_study2/document_checksums.csv` | Per document: brief, generator, word count, MD5 and SHA256. |
| `results_study2/documents/` | The 90 generated texts. **Git-ignored by default**; see `DATA_USE.md`. |
| `results_study2_pilot/` | Pilot calls. Kept as the audit trail; excluded from analysis. |
| `results_study2_main/` | `schedule.csv`, `documents.csv`, `calls_<judge>.csv` and `raw_<judge>.jsonl`. |
| `analysis_output_study2/` | Tables (`q1_existence.csv`, `q2_q3_variance_components.csv`, `q3_named_biases.csv`, `robustness.csv`, `exploratory_tests.csv`, and others), two figures and `analysis_log.txt`. |

### Reproducing Study 2

1. Add `OPENROUTER_API_KEY=...` to `.Renviron` and restart R.
2. `install.packages(c("shiny", "httr2", "jsonlite", "openssl"))`.
3. Generate and freeze the briefs with `source("generate_documents.R")`, including one pilot brief (`P01`, genre "Pilot"). Keep the logs.
4. `source("main_study2.R")`, then `run(pilot = TRUE)` and `estimate_cost()`.
5. Register, then run `run()`. Collection resumes automatically if interrupted.
6. `source("analysis_study2.R")`. The analysis refuses to run if any judge has fewer than 8 complete repetitions.

Run the analysis from the project root. It needs `clubSandwich` for robustness check (a) and `lme4` for (b); both are optional and the script reports when a check is skipped.

---

## Licence, data use and citation

- **Code** (`*.R`, `*.Rmd`, `TextEval.Rproj`): MIT, see [`LICENSE`](LICENSE).
- **Data and outputs** (`results_*`, `analysis_output*/`, probe and checksum files): CC BY 4.0, see [`LICENSE-DATA.md`](LICENSE-DATA.md).
- The four Study 1 source documents are not distributed and are not licensed here.
- **Study 2 texts** are model outputs. They are not published by default. Before publishing them, read [`DATA_USE.md`](DATA_USE.md), which summarises the terms of each provider and the labelling conditions.

Citation: Popov, S. V. (2026). *Same Text, Different Filename: Are LLMs Biased?* Preregistration AsPredicted #320377. Add the preprint or DOI here once available.
