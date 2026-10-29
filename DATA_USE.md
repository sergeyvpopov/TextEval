# Data use: model outputs in this repository

This file records what the providers' terms allow for the model outputs in this repository, and the conditions applied to them. It is a summary for readers and for the author, not legal advice. Check any change against the current terms and, if in doubt, ask the university research office.

## What is published

| Material | Published? | Why |
|---|---|---|
| Study 1 scores, replies, schedule, analysis | Yes (CC BY 4.0) | Replies are bare numbers; see `LICENSE-DATA.md`. |
| Study 2 scores, replies, briefs, schedule, analysis | Yes | Replies are bare numbers. |
| Study 2 generation logs and checksums | Yes | They record what was generated, with no texts. |
| Study 2 generated texts (`results_study2/documents/`) | **No, by default** | Git-ignored. Available on request, verified against the published checksums. |

Publishing the texts is a separate decision, to be made only after the providers' current terms have been checked (see below).

## Provider terms

These summaries are from the documents as read on 29 October 2026. Each provider's terms can change; re-check before publication.

**Anthropic (Claude Sonnet 5.5), Commercial Terms, effective 17 June 2025.**
- The customer owns its outputs, and Anthropic assigns any rights it has to the customer (Section B).
- Nothing prohibits publishing outputs.
- Section D.3 asks the customer to evaluate outputs before using or sharing them, and to tell users that factual claims should be checked.
- Section D.4(a) prohibits using the services "to build a competing product or service, including to train competing AI models."

**Google (Gemini 4 Argon), Gemini API Additional Terms, last updated 28 April 2026, and Generative AI Prohibited Use Policy, last modified 17 December 2024.**
- Google "won't claim ownership over" generated content.
- The customer "is responsible for [its] use of generated content, and for the use of that content by anyone [it] share[s] it with."
- Attribution to end users may be required in some API applications.
- "You may not use the Services to develop models that compete with the Services."
- The Prohibited Use Policy bars "misrepresenting the provenance of generated content by claiming it was created solely by a human, in order to deceive."
- On the unpaid tier, human reviewers may read inputs and outputs.

**OpenAI (GPT-6.1 Sol).**
- *Services Agreement, effective 1 January 2026.* The customer "owns all Output" (§4.1). Section 3.3(e) prohibits using outputs to "develop artificial intelligence models that compete with OpenAI's products", except for a "Permitted Exception" (embedding and classifier models not distributed commercially; fine-tuning models for the customer's own use).
- *Usage Policies, version effective 20 November 2026.* Research, evaluation and benchmarking are permitted. The policy prohibits using OpenAI outputs to create "training material or signals" for alternative models, including "labels, scores, rankings, preferences". This clause is not yet in force; the version in force now is the previous one, which was not checked.
- *Sharing and Publication Policy, updated 14 November 2022.* Welcomes research publications on the API. Requires that outputs be reviewed before sharing, labelled as AI-generated "in a way no user could reasonably miss", not represented as wholly human or wholly AI-generated, and that a human take responsibility for them. Asks that content that may offend others not be shared.

**OpenRouter, Terms of Service.** OpenRouter does not give users rights in outputs. Ownership follows each model's terms (§6.1), and the user is "solely responsible" for complying with them (§5.1). The terms restrict reselling access and building a competing service (§7(4)).

## Conditions applied in this repository

1. **Labelling.** Every published text, and every file that describes one, is identified as AI-generated and names the generating model. Files are named by generator (`B01_google.md`), not by a human label.
2. **No human attribution.** The human-name labels (Sergey, Catherine, Chen) appear only in prompts. They must not appear in any published file name, metadata or description of a text.
3. **No training use.** The README states that the scores and texts are for evaluation and replication and are not to be used as training data, labels or scores for models that compete with the providers.
4. **Review before publication.** The author reads each text again before publication, as the OpenAI Sharing and Publication Policy requires.
5. **Responsibility.** The author takes responsibility for what is published.

## Open items before publishing texts

- [ ] Re-check the current OpenAI Usage Policies and Services Agreement once the 20 November 2026 version is in force, if publication is later than that date.
- [ ] Confirm the Gemini API terms for the route used via OpenRouter (Google AI Studio or Google Cloud) and whether the paid tier applies.
- [ ] Confirm the Anthropic route used via OpenRouter (Claude Platform on AWS in Study 1) falls under the same Commercial Terms.
- [ ] Decide whether the texts are published in the repository, on request, or not at all. The current default is on request.
