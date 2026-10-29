# Instructor runbook: onboard a class on shared infrastructure

Follow this top to bottom to set up a class of about 20 students on one Foundry resource, one project per student, and one shared search service, registry and Application Insights. Students never create Azure resources or assign roles.

The background and trade-offs are in [instructor-guide.md](instructor-guide.md#shared-workshop-infrastructure). Commands use placeholders: replace `<subscription-id>`, `<resource-group>` and `<foundry-resource>` with your values (your private copy is `deployment/instructor-commands.txt`, which Git ignores).

## What you need
- Azure CLI signed in (`az login`) as **Owner** on the resource group.
- A Microsoft Entra role that can create users (**User Administrator**) and create Temporary Access Passes (**Authentication Administrator** or **Privileged Authentication Administrator**).
- An existing resource group with the Foundry resource, a chat deployment (`gpt-5-mini`) and, ideally, a container registry. The scripts create everything else.
- Windows PowerShell. In each new window run:

  ```powershell
  cd <path-to>\foundry-agent-workshop-issue-triage
  Set-ExecutionPolicy -Scope Process Bypass
  az login
  ```

## Timeline
| When | What |
|---|---|
| **Day before** | Steps 1 to 6 (the scripts take 30 to 60 minutes in total; role assignments need time to apply) |
| **Morning of the class** | Step 7 (one sign-in check), then hand out |
| **During the class** | Step 8 |
| **End of the class** | Step 9 |

## Step 1. Decide the student list
Students are `user1_foundrywksp` to `user22_foundrywksp` with projects `proj-student01` to `proj-student22` and ids `s01` to `s22`. If you have test accounts in `deployment/students.csv`, delete their rows now unless you want them to get access too.

## Step 2. Create the accounts and projects
Preview, then run:

```powershell
./deployment/create-student-accounts.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group> -FoundryAccountName <foundry-resource> -Count 22 -SkipProvisioning -DryRun
./deployment/create-student-accounts.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group> -FoundryAccountName <foundry-resource> -Count 22 -SkipProvisioning
```

- Existing accounts and projects are reused, never changed. It takes about 20 to 30 minutes.
- Each account gets a random password nobody knows, so students sign in with a Temporary Access Pass.
- It writes `deployment/students.csv`. Don't put passwords or passes in it.

## Step 3. Create the Temporary Access Passes (by hand)
The script's own pass creation (`-IssueTap`) is refused in some tenants, including the validation tenant, so create them in the Entra admin center.

1. **Protection** > **Authentication methods** > **Temporary Access Pass**: make sure it is **enabled** for the students.
2. For each student: **Users** > the user > **Authentication methods** > **Add authentication method** > **Temporary Access Pass**.
3. **Lifetime: longer than the whole class** (for example 8 hours). The Entra default is 1 hour, and a student whose pass expires gets "You don't have permission to perform this action in this project" partway through. Set the start time to the class start. Leave **one-time use** off.
4. Record each pass next to the student's name in a private note. Never commit it.

## Step 4. Create the infrastructure and assign roles
Preview, then run:

```powershell
./deployment/provision-workshop.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group> -FoundryAccountName <foundry-resource> -StudentsCsv ./deployment/students.csv -DryRun
./deployment/provision-workshop.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group> -FoundryAccountName <foundry-resource> -StudentsCsv ./deployment/students.csv
```

It creates or reuses the shared Standard search service (about USD 0.34 per hour while it exists), Log Analytics (1 GB/day cap), Application Insights and the embedding deployment. For each student it assigns Foundry User and Foundry Project Manager on their own project, plus the search, registry and monitoring roles, and creates the project's search connection. It is safe to re-run.

For Module 8.3, it grants each project's managed identity **Monitoring Metrics Publisher** on the shared Application Insights resource and each student **Log Analytics Reader** on Application Insights and its Log Analytics workspace. These are resource-scoped grants; students do not receive permission to assign roles. The script does not configure the Application Insights connection. As the instructor, open each project's **Prompt Agent** `issue-triage-agent` > **Traces** > **Connect**, select the shared Application Insights resource and **Project Managed Identity**, and complete the connection before students run Module 8 tests. The connection is project-wide, but students generate and review only Prompt Agent traces; do not test or configure tracing from the hosted agent.

- If it stops with "The students CSV has problems", that can be a one-off Entra lookup failure. Nothing was changed; run it again.
- It writes `deployment/output/`: `handout.csv`, and for each student `sNN.env.txt` (Modules 3 and 5) and `sNN.module7.txt` (Module 7). None contain secrets.

**Do not** grant students Foundry Owner or any role on the whole Foundry resource beyond Reader. The script gives them the roles they need and creates the search connection so they never use the portal's **Connect** button (which only works with Foundry Owner on the resource).

## Step 5. Create the guardrail once
In the Foundry portal as yourself: **Build** > **Guardrails** > **Create**. Name it `grissuetriage`, keep the default controls, turn on **PII** (for example credit card) and **Task adherence**, and don't select any agents or models. Students assign it to their own agent in Module 8.1; they cannot create guardrails.

## Step 6. Check the evaluation works
Module 9 depends on the portal evaluation. On 29 October 2026, student runs failed in about 8 to 12 seconds before processing rows. The confirmed error was `probability_threshold is only supported for Decision models`: ToolUseQuality and OutputQuality were configured with `gpt-5-mini` and `probability_threshold: 0.5`. This is an evaluator configuration error, not evidence that the student needs more roles.

1. Follow [Module 9.5](student/module-09-evaluation.md#95-create-the-portal-evaluation): create a **new evaluation**, keep the existing dataset and Prompt Agent version, and select only **Relevance** with `gpt-5-mini` for the first smoke test. Remove ToolUseQuality and OutputQuality; leave Probability threshold unset if the portal exposes it.
2. Verify dataset rows and scores appear before adding applicable evaluators. A successful smoke-test rerun has not yet been verified; compare the exact error if another failure occurs. **Add run** on the unchanged failed evaluation reuses the invalid configuration.
3. Students who already uploaded the dataset resume at **9.5**, not the beginning of Module 9. Use identical evaluator settings for the before/after comparison.
4. An earlier validation run completed but every evaluator errored on every row; that separate symptom remains undiagnosed. If portal evaluation stays blocked, use the local scorer (`score_triage.py`) and treat 9.5 to 9.9 as a demonstration rather than claiming portal results succeeded.

## Step 7. Check one student sign-in
In a private browser window, sign in at [ai.azure.com](https://ai.azure.com) as `user1_foundrywksp` with its pass, then check:
- The student can open **their own project** (`proj-student01`). They will also see other projects in the list; they cannot open them.
- **Build** > **Knowledge** already shows the shared search service and its knowledge bases (no greyed-out **Connect** screen).
- **Build** > **Agents** > **New agent** works.

Role assignments can take a few minutes. A browser session that was open before the roles were assigned can be stale: close it and sign in again.

## Step 8. Hand out and run the class
Give each student: their account name, their pass, `sNN.env.txt` and `sNN.module7.txt` (`user1` is `s01`, `user2` is `s02`, and so on). Point them to the [student guide](student-guide.md#workshop-day-at-a-glance-instructor-led).

During the class:
- **Module 4.** Students create `kstriage-<id>` and `kbtriage-<id>` on the shared service. Tell them to leave other students' objects alone.
- **Module 7.** Students deploy the hosted agent and verify its active status in 7.6. That completes the exercise. Do not collect agent principal IDs, assign hosted-agent Search roles, or ask students to invoke or test the hosted agent.
- **Module 8.** Use only the Prompt Agent `issue-triage-agent` for guardrail tests, traces, and monitoring. Complete its project's Application Insights connection as the instructor (Step 4); students send messages and review traces without role-administration permissions.
- **"You don't have permission" anywhere.** First close the browser and sign in again; check the pass hasn't expired. Re-run `provision-workshop.ps1` if a student's roles or connection are missing.
- **Quota.** If many students run evaluations or knowledge-base indexing at once, expect slowdowns; stagger Module 9.

## Step 9. After the class
1. Preview, then remove the shared infrastructure and the students' role assignments:

   ```powershell
   ./deployment/remove-workshop-infra.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group> -FoundryAccountName <foundry-resource> -StudentsCsv ./deployment/students.csv -DryRun
   ./deployment/remove-workshop-infra.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group> -FoundryAccountName <foundry-resource> -StudentsCsv ./deployment/students.csv
   ```

   It deletes only what the provisioning script tagged, never the Foundry resource, the projects, or a registry that existed before. The Search service is the main cost, so do this promptly.
2. Remove hosted agents (each student can run `python scripts/delete_lab_agents.py`, or delete them in the portal).
3. Delete the student accounts and projects if you no longer need them (not automated).
4. Delete `deployment/students.csv` and the `deployment/output/` folder, and revoke or let the passes expire.

## Known limits
- Search roles are service-wide, so a student could change another student's knowledge base. Unique names prevent accidents only.
- Application Insights and Log Analytics are shared; students can see each other's traces. Use only synthetic data.
- Students can see all projects in the **All resources** list but cannot open the others.
- Module 6 needs Docker on the student's machine and is optional.
- Module 9 evaluation: see Step 6.
