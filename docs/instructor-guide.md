# Instructor guide

## Lab purpose
Give participants hands-on experience of the full lifecycle of a Microsoft Foundry agent (build, ground, host, govern, monitor, evaluate) using one realistic telecom scenario that matches the customer's use cases: issue classification, context- and keyword-based categorisation, prioritisation and routing, acknowledgments with troubleshooting steps, and notifications that link issues to known solutions.

## Target audience
Developers, solution architects, and technical support/operations engineers who will design or build AI agents on Microsoft Foundry.

## Required student knowledge
- Basic Python (reading code, virtual environments, running scripts).
- Basic Azure portal navigation and the idea of resource groups and role assignments.
- No prior Foundry or Agent Framework experience needed.

## Required instructor knowledge
- Microsoft Foundry (new) portal, projects, model deployments, agents.
- Microsoft Agent Framework for Python (agents, tools, sessions, context providers, hosting adapter).
- Azure RBAC, Azure AI Search basics, Docker, `azd`.
- The preview features listed under [Preview-feature risks](#preview-feature-risks).

## Architecture overview
See [architecture.md](architecture.md). Key teaching idea: **one application, two agent styles**. The portal Prompt Agent (`issue-triage-agent`) is configuration stored in Foundry; the code-defined agent in `app/triage_desk` becomes the hosted agent (`issue-triage-hosted`). Both use the same instructions file.

## Environment preparation

### Delivery model (choose one)
| Model | When to use | Notes |
|---|---|---|
| One resource group and project per student | Recommended | Clean isolation and cleanup; needs quota per student. |
| Shared Foundry resource, one project per student | Limited subscriptions | Shared quota; guardrails need Foundry Account Owner on the shared resource. |
| Instructor-provisioned projects, students as Foundry User / Project Manager | Locked-down tenants | Instructor does the steps that need Owner (resource creation, role assignments, guardrails). |
| **Shared infrastructure for a larger class** (one Foundry resource, one project per student, one shared search service, registry and Application Insights) | Lowest cost for about 20 students; students can't create resources or assign roles | Set up with [provision-workshop.ps1](../deployment/provision-workshop.ps1); see [Shared workshop infrastructure](#shared-workshop-infrastructure). |

### Shared workshop infrastructure
**Start with the step-by-step [instructor runbook](instructor-runbook.md)** to onboard a class. This section explains what the scripts create and why.

Use this when students must not create Azure resources or assign permissions. You keep the existing resource group, Foundry resource and one project per student, and the script adds only what is missing.

| Shared resource | Notes |
|---|---|
| Azure AI Search, **Standard** (S1), 1 replica, 1 partition | Each student creates their own knowledge source (`kstriage-<id>`) and knowledge base (`kbtriage-<id>`). Basic allows only 5 or 15 knowledge bases and Free only 3, so Standard is needed for about 20 students. Basic and higher are required for the search managed identity. |
| Azure Container Registry | An existing registry is reused; otherwise a Basic one is created. Stops `azd` from creating a Premium registry. |
| Log Analytics workspace (1 GB/day cap) + Application Insights | Shared by all projects (Module 8). |
| Embedding deployment | `text-embedding-3-small` on the existing Foundry resource. |

Not needed: storage account (students use the **File** knowledge source), one search service or registry per student.

**Steps**
1. Create the student accounts and the Foundry projects. Either do it yourself, or run [create-student-accounts.ps1](../deployment/create-student-accounts.ps1), which creates `user<N>_foundrywksp@<domain>` accounts (no usable password; they sign in with a Temporary Access Pass) and one project `proj-student<NN>` each, writes `deployment/students.csv`, and then calls the provisioning script in step 3:

   ```powershell
   ./deployment/create-student-accounts.ps1 -SubscriptionId <id> -ResourceGroup <rg> -FoundryAccountName <foundry-resource> -Count 22 -DryRun
   ./deployment/create-student-accounts.ps1 -SubscriptionId <id> -ResourceGroup <rg> -FoundryAccountName <foundry-resource> -Count 22 `
       -IssueTap -TapStartTime "2026-11-02 08:30" -TapLifetimeMinutes 600
   ```
   Passes are saved to `deployment/output/accounts.csv` (sensitive; delete it after the class). If TAP creation is refused, create the passes in the Entra admin center. It needs User Administrator and, for passes, an authentication administrator role, and Temporary Access Pass must be enabled in the tenant. To manage accounts yourself instead, copy [students.example.csv](../deployment/students.example.csv) to `deployment/students.csv` (Git ignores it) and fill in `UserPrincipalName` and `ProjectName` (plus optional `StudentId`, `ObjectId`). Never put passwords or Temporary Access Passes in it.
2. Sign in with `az login` as Owner on the resource group.
3. Preview, then run (use `Set-ExecutionPolicy -Scope Process Bypass` first if scripts are blocked):

   ```powershell
   ./deployment/provision-workshop.ps1 -SubscriptionId <id> -ResourceGroup <rg> -FoundryAccountName <foundry-resource> `
       -StudentsCsv ./deployment/students.csv -DryRun
   ./deployment/provision-workshop.ps1 -SubscriptionId <id> -ResourceGroup <rg> -FoundryAccountName <foundry-resource> `
       -StudentsCsv ./deployment/students.csv
   ```
   The script is safe to re-run. It writes `deployment/output/handout.csv` and, for each student, `<student>.env.txt` (Modules 3 and 5 settings) and `<student>.module7.txt` (the Module 7 commands, including the shared-registry values). Neither contains secrets. Give each student both files.
4. In the Foundry portal, create the guardrail once (**Build** > **Guardrails**). Students assign it to their own agent in Module 8.
5. Before Module 8, open each project's Prompt Agent `issue-triage-agent` > **Traces** > **Connect** as the instructor and connect shared Application Insights using **Project Managed Identity**. Students test and trace only the Prompt Agent. Module 7 ends after hosted deployment verification; no hosted-agent Search role assignment or invocation is required.
6. After the workshop, preview and run [remove-workshop-infra.ps1](../deployment/remove-workshop-infra.ps1). It deletes only resources tagged `workshop=foundry-agent-lab`, never the Foundry resource, projects, or a registry that existed before.

**Roles the script assigns** (all scoped to lab resources, none at subscription or resource group level)
| Principal | Role | Scope |
|---|---|---|
| Student | Foundry User, Foundry Project Manager | Their own project |
| Student | Reader | Foundry resource |
| Student | Search Service Contributor, Search Index Data Contributor, Search Index Data Reader | Shared search service |
| Student | Container Registry Tasks Contributor | Registry (remote image build) |
| Student | Log Analytics Reader | Application Insights and workspace |
| Project managed identity | Search Index Data Reader, Search Index Data Contributor, Search Service Contributor | Shared search service |
| Project managed identity | AcrPull (Repository Reader if the registry uses ABAC) | Registry |
| Project managed identity | Monitoring Metrics Publisher | Application Insights |
| Search service managed identity | Cognitive Services User | Foundry resource |

**Known trade-offs**
- Search roles apply to the whole service, so a student can change another student's knowledge base. Unique names prevent accidents only. Brief students not to touch other names.
- Application Insights and the workspace are shared: students can see each other's traces. Acceptable only with synthetic data.
- Students with Foundry Project Manager at **Foundry resource** scope can manage every project. The script grants it on the student's own project only.
- **The portal's Connect button needs more than students have.** On **Build** > **Knowledge**, a student with Foundry User and Foundry Project Manager on their own project (plus Reader on the resource) sees **Connect** greyed out with "You don't have permission to perform this action in this project". In testing, adding Foundry User or Foundry Project Manager on the whole Foundry resource did **not** fix it; only Foundry Owner on the resource did, which would let students manage every project and assign roles. Instead `provision-workshop.ps1` creates the project's Cognitive Search connection itself, so students never press Connect. With that connection in place, a student with only the roles above could create a knowledge source and knowledge base, connect it to their agent, and get grounded answers (validated 26 October 2026). Connection names are unique across the whole Foundry resource, so the script names them `<search-service>-<project>`.
- A student's portal session can go stale after you change roles. Run `provision-workshop.ps1` before students first sign in, or ask them to sign in again.

**Pilot with one student account before the class** (these points depend on the tenant and preview features)
- Module 4: **validated** with a student-level account (see above): knowledge source, knowledge base, agent connection, and grounded answers.
- Module 5: **validated** with a student-level account.
- Module 7: **deployment validated** with a student-level account (26 October 2026, `azd` 1.37.1, `azure.ai.agents` beta.22): `azd ai agent init --no-prompt`, then `azd env set` to point `azd` at the shared registry, then `azd deploy` (about 2.5 minutes, remote build) and `azd ai agent show`. The exercise ends when the deployment is active; do not invoke or test it. **Students can't run `azd provision`:** it is a subscription-level deployment and fails with `AuthorizationFailed`; without the registry values `azd` plans a new Premium registry in a new resource group. The handout `<student>.module7.txt` carries the exact commands.
- Module 8: the instructor completes the Application Insights connection for each project from the Prompt Agent's Traces tab. Preassigned Monitoring Metrics Publisher does not bypass the portal's caller-permission check. Students assign the instructor's guardrail to `issue-triage-agent`, test that Prompt Agent, and review its traces without role-assignment permission. Hosted agents are not tested or traced.
- Quota: run 3-4 students at once to check model rate limits and knowledge-base indexing time.

### Resource preparation checklist (per student project)
1. Confirm the region supports everything in [prerequisites.md](prerequisites.md#region).
2. Confirm model quota for the chat model, the embedding model, and the judge model.
3. Create the lab resource group with a neutral name, for example `rg-foundry-agent-lab-<nn>`.
4. Assign the roles below.
5. Decide the Azure AI Search tier (Free per student if available; otherwise Basic).
6. Decide whether students create Application Insights themselves (Module 8.3) or you pre-connect one.

### Role checklist
For the shared-infrastructure model, [provision-workshop.ps1](../deployment/provision-workshop.ps1) assigns the roles listed in [Shared workshop infrastructure](#shared-workshop-infrastructure); the table below is the general (per-student environment) checklist.

| Principal | Role | Scope | Module |
|---|---|---|---|
| Student | Foundry User | Foundry resource or project | 1, 3, 9 |
| Student | Foundry Project Manager | Project | 4 (connections), 7 (hosted agent) |
| Student or instructor | Foundry Account Owner | Foundry resource | 8 (guardrails) |
| Student | Search Service Contributor + Search Index Data Contributor | Search service | 4 (create knowledge base) |
| Student | Search Index Data Reader + Reader (Reader is covered if they have Search Service Contributor) | Search service | 5 |
| Student (if they create search/storage themselves) | Contributor | Lab resource group | 4 |
| Student | Log Analytics Reader | Application Insights / workspace | 8 |
| Project managed identity | Search Index Data Reader, Search Index Data Contributor, Search Service Contributor | Search service | 4 (Project Managed Identity connection) |
| Project managed identity | Container Registry Repository Reader | Registry used by `azd` | 7 (assigned automatically only for new projects) |
| Project managed identity | Monitoring Metrics Publisher | Application Insights | 8.3 (instructor completes connection) |
| Search service managed identity | Cognitive Services User | Foundry resource | 4/5 (knowledge base calls embedding and chat models) |
| Search service managed identity | Storage Blob Data Reader | Storage account | 4 option A |

Never grant subscription-wide roles for the lab. Don't change subscription policies or unrelated resources.

## Validate the environment before delivery
Run the whole lab once in the **target tenant and region**, as a user with the student roles:

1. `python -m pytest` passes (offline checks, 48 tests; set `LAB_CHECK_STARTER=1` to also check that the committed starter files match the solution).
2. Module 1: create the Prompt Agent; confirm the portal labels match the guide (**New Foundry**, **Build** > **Agents** > **New agent** > **Build an agent**, **YAML**, **Version**, **Publish**).
3. Module 3: `python scripts/lab_state.py solution`, then `python -m triage_desk triage ISS-1009 --engine agent` and `--engine prompt-agent`.
4. Module 4/5: knowledge source becomes **active**; `python scripts/score_triage.py --engine agent --ids EVAL-001,EVAL-003,EVAL-017,EVAL-019,EVAL-022`.
5. Module 6: `docker build` succeeds on the training machines (check proxy/mirror access) and `/readiness` returns 200.
6. Module 7: `azd ai agent init ...`, `azd deploy`, then `azd ai agent show` to verify active deployment. No hosted-agent invocation or runtime test; delete the deployment during cleanup.
7. Module 8: guardrail creation and assignment; traces appear.
8. Module 9: dataset upload, an evaluation run completes, a second run after the instruction change.
9. `python scripts/lab_state.py reset` before handing the repository to students.

Record any portal differences in the [documentation gap register](#documentation-gap-register) and update the student guide.

## Reset the lab
| Reset | Command |
|---|---|
| Student code back to starter | `python scripts/lab_state.py reset` |
| Catch a student up | `python scripts/lab_state.py upto <step>` (for example `upto 3.5`) |
| Remove lab agents but keep resources | `python scripts/delete_lab_agents.py` |
| Remove hosted agent only | `azd ai agent delete issue-triage-hosted --force` |
| Regenerate the evaluation dataset after changing issues | `python scripts/build_eval_dataset.py` |
| Full teardown | `./scripts/cleanup-lab.ps1 -ResourceGroup <rg>` |

## Teaching points and demonstration checkpoints

| Module | Teaching points | Demonstration checkpoint |
|---|---|---|
| 1 | Projects, deployments, agents, versions; Prompt Agent = configuration; instructions as policy; prompt injection in ticket text | ISS-1012 handled safely in the playground |
| 2 | Business workflow first; rules are cheap and auditable but brittle | `queue` shows ISS-1009/1019 as UNCLASSIFIED and ISS-1006 as BILLING ("Pre**paid**") |
| 3.1 | `FoundryAgent` vs `Agent` + `FoundryChatClient`; keyless auth | Same issue, three engines, `--compare` |
| 3.2 | Instructions + structured output; never trust model output for policy | Routing `NOTE` when the agent proposes `Unassigned` |
| 3.3 | Tools = existing app functions; least privilege; model chooses tools | `[tool call]` lines; CUST-9999 not found |
| 3.4 | Sessions and context | Follow-up fails without a session, works with one |
| 3.5 | Defence in depth: validation, timeouts, fallback, logging | Wrong deployment name gives a labelled fallback |
| 4 | Knowledge source vs knowledge base; agentic retrieval; preview status | ISS-1001 linked to KI-2041; Old Town not invented |
| 5 | Context providers; citations only if returned | `Sources returned by Foundry IQ` |
| 6 | Same code, new host; no secrets in images; amd64 | `/readiness` 200 and `docker logs` tool calls |
| 7 | Hosted agent identity, scale to zero, azure.yaml, platform-injected variables | Successful `azd deploy` + active status from `azd ai agent show` |
| 8 | Layers of control; what guardrails do and don't do; optional Defender/Purview | Prompt-attack test blocked; trace with a knowledge tool call |
| 9 | Quality evaluators vs exact labels; change-and-compare loop | Two runs compared |

## Common failure modes
| Failure | Prevention |
|---|---|
| Model quota exhausted during the class | Pre-check quota; have an approved alternative model; stagger evaluation runs. |
| Proxy blocks pip or Docker Hub | Pre-install packages; provide a mirror; build the image remotely in Azure Container Registry with `azd deploy` (validated). |
| Port 8088 already used on training machines | Use `PORT=18088` / `-p 18088:8088`. |
| Role assignments not effective yet | Assign roles the day before. |
| Portal labels changed since the guide was written | Validate the day before; announce differences. |
| `azd` extension incompatible | Pin and pre-install `azd` and the Foundry extensions on training machines. |

Full list: [troubleshooting.md](troubleshooting.md).

## Expected results
- Agent engine fixes most of the rules engine's mistakes (ISS-1006, 1009, 1014, 1019) and flags ISS-1012.
- Grounded answers link ISS-1001/1019 to KI-2041, ISS-1003 to KI-2043, ISS-1017 to KI-2042; Old Town has no incident.
- The hosted deployment is active; no hosted-agent responses or traces are required. Module 8 tests and traces the Prompt Agent.
- Results vary between runs and models; discuss variation as part of evaluation.

## Optional extensions
- Use the Foundry **Toolbox** to expose the knowledge base to the hosted agent instead of the context provider (see the official sample `17-foundry-iq-toolbox`).
- Add an **Invocations** protocol endpoint for batch triage of the whole queue.
- Enable continuous evaluation in **Monitor settings** for the Prompt Agent (outside the required exercise; watch token cost).
- Bilingual acknowledgments (Arabic/English) as an explicit requirement in the instructions, plus evaluation rows for it.
- Microsoft Defender and Microsoft Purview integrations with the customer's security team (separate enablement and licensing).

## Full cleanup procedure
[cost-and-cleanup.md](cost-and-cleanup.md#cleanup-steps). Confirm with `az group exists` for every student resource group, and check soft-deleted Foundry resources.

## Preview-feature risks
| Feature | Status found | Risk |
|---|---|---|
| Agent guardrails, tool call / tool response intervention points, PII and Task adherence risks | Preview | Behaviour and UI can change; not for production without review |
| Foundry IQ agentic retrieval in the Foundry and Azure portals | Preview-only portal access | Portal steps may change |
| Tracing, Agent Monitoring Dashboard metrics | Preview | Views may change |
| `azd ai agent init` | Preview | Prompts and flags may change; check `azd ai agent init --help` |
| `agent-framework-foundry-hosting`, `agent-framework-azure-ai-search` | Prerelease packages | API changes between builds; versions are pinned |
| Full-conversation evaluations | Preview | Not used in this lab (individual turns used) |
| Hosted agents | Generally available (per Agent Framework hosting docs) | Region list changes |

## Documentation gap register
| # | Area | Gap | Lab approach |
|---|---|---|---|
| 1 | Module 1 | Quickstart *Create a prompt agent* has no portal procedure | Steps validated in the live portal (Build > Agents > New agent > Build an agent) |
| 2 | Module 4 | Field-level knowledge-base steps, the **File (Preview)** source, and Project Managed Identity connection aren't on Learn | Steps validated in the live portal; Blob option follows the Microsoft Learning lab |
| 3 | Module 4 | Blob source blocked when tenant policy disables storage public network access | Option B (File knowledge source), validated |
| 4 | Module 5 | Provider reads the knowledge base definition (needs **Reader**); citation fields per source kind undocumented | Reader + Search Index Data Reader; display `metadata_storage_path` |
| 5 | Module 5 | GA `azure-search-documents` doesn't support the `file` source kind | Pinned preview 12.1.0b2 |
| 6 | Module 6 | No official guidance for authenticating a hosted-agent container with plain `docker run` | Local-only scope-aware dev token credential (validated) |
| 7 | Module 7 | `azd ai agent init` without a registry creates `rg-<env>-foundry` with a Premium registry | Documented; select an existing registry or delete the resource group during cleanup |
| 8 | Module 8 | Guardrail how-to describes an older wizard; severity table appears inconsistent | Steps validated in the live portal |
| 9 | Module 9 | Portal dataset upload step isn't described; evaluator names differ from the how-to | SDK upload (validated); evaluator list recorded from the portal |

## Validation status of this repository
**End-to-end validation in Azure: 5 October 2026**, Microsoft Non-Production tenant, region France Central, `gpt-5-mini` / `text-embedding-3-small` / `gpt-4.1-mini` (GlobalStandard), `azd` 1.34.1 with `azure.ai.agents` 1.0.0-beta.16, Python 3.11, the pinned packages in `app/requirements.txt`.

| Module | Result |
|---|---|
| 1 | Validated in the portal (Prompt Agent created, multi-turn test; ISS-1012 blocked by the default guardrail) |
| 2 | Validated (offline) |
| 3 | All exercises validated against the live project (3.1 to 3.5) |
| 4 | Validated with the **File (Preview)** knowledge source and Project Managed Identity; Blob option not validated (tenant storage policy) |
| 5 | Validated: KI-2041/KI-2042/KI-2043 linked; Old Town not invented; sources shown |
| 6 | Run, invoke, logs, and cleanup validated with the image built by Azure Container Registry; local `docker build` not possible in the authoring network (PyPI blocked) |
| 7 | Deployment-only exercise: `azd ai agent init`, shared-registry configuration, `azd deploy` (remote build), and `show` to verify active status. Earlier runtime validation is not part of the exercise |
| 8 | Validated: guardrail created and assigned; jailbreak and PII blocked; abusive complaint allowed; Application Insights connected; traces and Monitor tab reviewed |
| 9 | Dataset upload, local scorer, and the full portal evaluation wizard validated up to **Submit**. The run (22 evaluators) was still **In progress** after 30+ minutes and its results weren't reviewed; steps 9.6-9.9 for the portal results and the results screenshot remain to be confirmed at the first delivery |

Offline checks: 48 tests pass (`python -m pytest`, with `LAB_CHECK_STARTER=1` for the starter check).

Before each delivery, repeat the [pre-delivery validation](#validate-the-environment-before-delivery): the portal changes often.

## Documentation references
All module pages end with a References section. Core sources:
- [Microsoft Foundry documentation](https://learn.microsoft.com/azure/foundry/)
- [Agent Framework documentation](https://learn.microsoft.com/agent-framework/)
- [Foundry samples (hosted agents)](https://github.com/microsoft-foundry/foundry-samples/tree/main/samples/python/hosted-agents/agent-framework)
- [Microsoft Learning: agent quickstart lab](https://microsoftlearning.github.io/mslearn-agent-quickstart/) and [AI agents labs](https://microsoftlearning.github.io/mslearn-ai-agents/)
