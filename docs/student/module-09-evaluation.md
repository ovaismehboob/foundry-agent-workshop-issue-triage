# Module 9 - Evaluate the agent with a local JSON dataset

## Objective
Evaluate the triage agent with a small, human-readable synthetic dataset: review and validate it, run a portal agent evaluation, find weak cases, change the agent instructions, evaluate again, and compare the results.

> **Workshop quick path**
> - In 9.5, select `gpt-5-mini` as the **Judge model**; it is already deployed. Don't deploy models yourself.
> - Evaluations can take a long time and use shared model capacity. Start yours when your instructor says, then continue with 9.6 locally while it runs.
> - In 9.3, 9.7 and 9.8, set `PROMPT_AGENT_VERSION` in `app/.env` to **your own** agent's version.
> - If a previous run failed within seconds with `probability_threshold is only supported for Decision models`, resume at **9.5** and create a **new evaluation** with only **Relevance** initially. Reuse the uploaded dataset and current Prompt Agent version; do not repeat 9.1 to 9.4 or use **Add run** on the unchanged failing configuration.

## Prerequisites
- Modules 1, 3, and 4 completed. `issue-triage-agent` has the knowledge base connected.
- **Foundry User** role on the project; see [evaluation permissions](https://learn.microsoft.com/azure/foundry/observability/how-to/evaluation-permissions) for the full role list.
- A GPT deployment for the AI-assisted (judge) evaluators, for example `gpt-4.1-mini`. Deploy one from **Discover** > **Models** if your instructor asks you to. In an instructor-led workshop, use the existing `gpt-5-mini` deployment.

## What is evaluated
| Option | Used here | Notes |
|---|---|---|
| **Agent** target, **Individual turns**, **Existing dataset** | Yes | The portal sends each `query` to `issue-triage-agent` (the Prompt Agent) and scores the live responses. |
| Hosted agent | No | Module 7 is deployment-only. Do not select `issue-triage-hosted` for evaluations; use the Prompt Agent `issue-triage-agent`. |
| Dataset target (saved responses) | No | Evaluates outputs you generated earlier, without calling the agent. |
| Local scorer | Yes | Runs the local engines and checks the exact business labels. |

The Prompt Agent can't run the app's local Python tools, so the portal evaluation measures response quality, instruction following, knowledge-base use, and safety. Tool behaviour (`route_issue`, `get_customer_context`) is checked locally with the scorer.

## Concepts introduced
- Evaluation dataset (JSONL), field mapping, evaluators, judge model.
- Comparing evaluation runs before and after a change.

## Steps

### 9.1 Review the dataset
Open [evaluation/dataset.jsonl](../../evaluation/dataset.jsonl) and [evaluation/README.md](../../evaluation/README.md). Find one record of each type: `straightforward`, `grounded`, `ambiguous`, `unsupported`, `safety`.

### 9.2 Validate the schema
From the repository root:

```powershell
python scripts/build_eval_dataset.py --check
python -m pytest tests/test_evaluation_dataset.py
```

### 9.3 Get a local baseline
```powershell
python scripts/score_triage.py --engine rules
python scripts/score_triage.py --engine prompt-agent
```
The `prompt-agent` engine calls your portal agent with the same `query` text as the dataset. Set `PROMPT_AGENT_VERSION` in `app/.env` to the agent's current version first (assigning the Module 8 guardrail created a new version). Note the category, priority, and known-incident accuracy, and the `XX` rows.

### 9.4 Upload the dataset to the project
```powershell
python scripts/upload_eval_dataset.py
```
This uses the documented SDK method `project.datasets.upload_file(...)` and creates the dataset `issue-triage-eval`, version 1.

### 9.5 Create the portal evaluation
1. Open **Build** > **Agents** > `issue-triage-agent` and select the **Evaluation** tab. It has sub-tabs **Automatic Evaluation**, **Human Evaluation**, and **Red team (Preview)**. On **Automatic Evaluation**, select **Create**. (You can also start from **Build** > **Evaluations**.)
2. The **Create new evaluation** wizard opens:
   1. **Target**: **Agent**, with `issue-triage-agent` and its current version selected. Select **Next**.
   2. **Scope**: **Individual turns**. Select **Next**.
   3. **Frequency**: **One time** (**Recurring** is preview). Select **Next**.
   4. **Data**: **Existing dataset**, then select `issue-triage-eval` version 1. (Other options: **Synthetic generation**, **Benchmarks**, **Existing traces**.) Select **Next**.
   5. **Configure agents**: select **Configure** to view the user prompt. Keep `{{item.query}}`. Select **Next**.
   6. **Criteria**: select the existing **Judge model** `gpt-5-mini`. For the first smoke test, remove the auto-suggested evaluators and select only **Relevance**. In particular, do not keep **ToolUseQuality** or **OutputQuality** in this initial run.

      Check the mappings: `query: {{item.query}}` and `response: {{sample.output_text}}`. Evaluators that need a reference answer use `ground_truth: {{item.ground_truth}}`.

      **Known configuration failure (observed 29 October 2026):** the portal configured ToolUseQuality and OutputQuality with `deployment_name: gpt-5-mini` and `probability_threshold: 0.5`. Runs failed before processing any rows with `probability_threshold is only supported for Decision models`. If **Probability threshold** is exposed for this judge, leave it unset; this is not the normal score/pass threshold. If the portal inserts it automatically, use the Relevance-only workaround. An instructor using the API/SDK can instead create corrected evaluator definitions without `probability_threshold`; do not grant broader Azure roles to address this configuration error.
   7. **Review**: enter **Evaluation name** `triage-eval-v<agent version>-relevance` and select **Submit**. Use a new name when recovering from a failed evaluation.
3. The evaluation page shows the run with **Status** **In progress**, and buttons **Make recurring**, **Add run**, and **Compare runs**. With many evaluators, a run can take a long time (more than 30 minutes in validation); continue with 9.6 locally while you wait.

Confirm that the smoke test produces dataset rows and Relevance scores before adding evaluators. The configuration error above is confirmed, but a successful Relevance-only rerun was not yet verified when this workaround was documented. After the smoke test succeeds, create an evaluation with the applicable criteria (for example Relevance, IntentResolution, TaskAdherence, TaskCompletion, Groundedness, and safety evaluators), checking each configuration. Use the same criteria, judge model, mappings, and dataset for the before/after comparison in 9.8 and 9.9. A new evaluator set should have its own evaluation definition; **Add run** on the original failed definition repeats its invalid settings.

> **SCREENSHOT PLACEHOLDER** - `docs/images/m09-evaluation-results.png`
> - **Screen**: evaluation run results with per-evaluator scores and per-row results.
> - **Navigation**: Build > Agents > issue-triage-agent > Evaluation > select the run.
> - **Purpose**: show where to find weak rows.
> - **Must be visible**: run name, status, evaluator summary, a row with a low score.
> - **Redact**: account menu, notifications, tenant or subscription details, user name in "Created by".
> - **Caption**: "Figure 9.1 - Results for the first evaluation run."
> - **Alt text**: "Foundry evaluation results showing evaluator scores for the triage dataset."

### 9.6 Identify weak cases
1. Open the run and sort or filter the rows by the lowest scores or failed evaluators.
2. Compare them with the `XX` rows from the local scorer.
3. Write down two weak cases and why they failed.

Validated local baseline for the Prompt Agent (version 5, with knowledge base and guardrail): category 95.5%, priority 86.4%, team 95.5%, known issue 90.9%. Typical weak cases:
- EVAL-016 (ambiguous "It's not working again.") rated P2 instead of P3/P4.
- EVAL-020 (restaurant question) answered without a triage card.
- EVAL-002 and EVAL-011 linked to a known incident that doesn't strictly match.
- EVAL-012 and EVAL-021 were blocked by the guardrail (prompt attack), so the scorer used the rules fallback.

### 9.7 Make one small change
1. In the agent playground, append the contents of [evaluation/instruction-change-v2.md](../../evaluation/instruction-change-v2.md) to the end of the **Instructions**, or write your own one-line rule for a weak case you found.
2. Select **Save**. Note the new version number and update `PROMPT_AGENT_VERSION` in `app/.env`.

### 9.8 Evaluate again
1. Repeat step 9.5 and name the run `triage-eval-v<new version>`. By default the agent endpoint serves the latest version; check the version in the run details if the wizard shows it.
2. Run the local scorer again: `python scripts/score_triage.py --engine prompt-agent`

### 9.9 Compare the results
- In the portal, open the evaluation, select both runs, and select **Compare runs** ("Select multiple runs to compare results statistically or use AI to analyze failed tests"). Use **Add run** on the same evaluation to add the second run.
- Locally, compare the two newest files in `evaluation/results/` (ignored by Git).
- Decide whether the change helped, made no difference, or caused a regression on other rows.

## Expected result
- Two completed evaluation runs and two local score files.
- A short written conclusion: which rows changed and whether you would keep the new instructions.

## Verification checkpoint
- [ ] You can explain the difference between the portal evaluators and the local exact-label scorer.
- [ ] You can name one row that improved and one that didn't change.

## Common errors and recovery
| Symptom | Likely cause | Recovery |
|---|---|---|
| Dataset not listed | Upload went to a different project | Check `FOUNDRY_PROJECT_ENDPOINT`; run the upload again with `--version 2`. |
| Fails within seconds with `probability_threshold is only supported for Decision models`, with no dataset rows or scores | An evaluator has an incompatible initialization parameter; observed with ToolUseQuality and OutputQuality using `gpt-5-mini` and `probability_threshold: 0.5` | Resume at 9.5, create a new evaluation, and start with Relevance only. Remove ToolUseQuality and OutputQuality; leave Probability threshold unset if exposed. Do not retry the unchanged evaluation or add Azure roles. |
| Status **Failed** or **Partial** | Judge model missing or out of quota, or a required field unassigned | Select a judge deployment with quota; check the field mapping. |
| Evaluation is slow | Many evaluators, judge model quota | Remove evaluators you don't need in **Criteria**; use a judge model with quota; use `--limit` for the local scorer. |
| Local scorer shows fallbacks | AI call failed (see Exercise 3.5) | Run one case with `python -m triage_desk triage ISS-1001 --engine prompt-agent --verbose`. |

## Cleanup
Uploaded datasets and evaluation runs remain in the project until you delete the resource group. Delete `evaluation/results/` locally if you don't need it.

## Knowledge check
1. Why is the dataset JSONL rather than one JSON array?
2. What does the `{{item.query}}` user prompt do?
3. Why can't the portal evaluation of the Prompt Agent test `route_issue`?

<details><summary>Answers</summary>

1. The portal supports CSV and JSONL datasets.
2. It sends each record's `query` field to the agent.
3. `route_issue` is a local Python tool in the app; the Prompt Agent doesn't have it.
</details>

## References
- [Run evaluations from the Microsoft Foundry portal](https://learn.microsoft.com/azure/foundry/how-to/evaluate-generative-ai-app)
- [Set up permissions for evaluation workflows](https://learn.microsoft.com/azure/foundry/observability/how-to/evaluation-permissions)
- [Evaluate existing datasets with the Microsoft Foundry SDK](https://learn.microsoft.com/azure/foundry/observability/how-to/cloud-evaluation-datasets)
- [Evaluate a hosted agent (quickstart)](https://learn.microsoft.com/azure/foundry/observability/quickstarts/quickstart-evaluate-hosted-agent)

> **Documentation gaps:** (1) The portal how-to says datasets are selected "from your project's data assets" but doesn't describe a portal upload step, so this lab uploads with the documented SDK method (validated). The wizard also offers **Upload new dataset**. (2) The validated wizard (5 October 2026) has the steps Target, Scope, Frequency, Data, Configure agents, Criteria, Review, and evaluator names such as `ToolSelection` and `OutputQuality` that differ from the how-to article. Follow the portal.
