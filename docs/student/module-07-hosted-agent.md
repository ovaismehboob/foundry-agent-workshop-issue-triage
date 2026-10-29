# Module 7 - Deploy the containerized agent as a hosted agent

## Objective
Deploy the same Agent Framework triage agent to **Foundry Agent Service** as a **hosted agent** and verify its deployment status. This exercise ends after deployment verification: do not invoke, chat with, test, or enable tracing for the hosted agent. Modules 8 and 9 use the **Prompt Agent** `issue-triage-agent`.

## Status and availability (verify before delivery)
- Microsoft Learn (Agent Framework hosting) states that **Microsoft Foundry Hosted Agents is generally available**.
- `azd ai agent init` is marked **preview**, and the Python hosting package `agent-framework-foundry-hosting` is a **prerelease** build.
- Hosted agents are available in a [documented list of regions](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents#region-availability) (including UAE North at the time of writing).
- Container images must be **linux/amd64**; the container serves port **8088**; the platform provides `/readiness` routing, a dedicated Microsoft Entra **agent identity**, and a dedicated endpoint.

> **Workshop quick path (do this, skip that)**
> - **Use your handout file `<your-id>.module7.txt`.** It holds the exact commands for your project and the shared registry. Copy them into a **new PowerShell window** (so `azd` is on the PATH) from the repository root.
> - **Do:** 7.1 check tools, 7.2 `azd ai agent init`, 7.3 add the three `env` lines to `azure.yaml`, then the `azd env set` lines from your handout, **7.5 `azd deploy`**, and 7.6 verify deployment status. **That completes the exercise.**
> - **Skip 7.4 (`azd provision`).** You don't have the rights for it (it fails with `AuthorizationFailed`), and without the handout values `azd` would plan a new Premium registry. The handout's `azd env set` lines point `azd` at the shared registry instead.
> - **Skip:** creating a registry or resource group, hosted-agent Search role assignments, invocation, runtime tests, and hosted-agent tracing. You do not need to send your agent principal ID to the instructor.

## Prerequisites
- Module 3 completed (Module 5 optional). **Module 6 is optional** — `azd` builds the image remotely in Azure Container Registry, so you don't need a locally built image.
- **Foundry Project Manager** role at project scope (needed to deploy hosted agents). See [prerequisites.md](../prerequisites.md#roles).
- Azure Developer CLI `azd` 1.27.1 or later with the Foundry extensions (install the [Foundry Dev Pack](https://learn.microsoft.com/azure/foundry/how-to/develop/install-cli-sdk), or run `azd extension install azure.ai.agents`). Validated with `azd` 1.34.1 and `azure.ai.agents` 1.0.0-beta.16.
- Docker isn't required for the deployment itself: `azd` builds the image remotely in Azure Container Registry.
- Your **project resource ID**: in the Foundry portal select **Manage** > **Project details** and copy **Resource ID**. Keep it in your private notes; don't commit it.

## Concepts introduced
- **Hosted agent**: your container, run by Foundry in per-session, VM-isolated sandboxes that scale to zero after an idle timeout (2-60 minutes, default 15).
- **Agent identity**: created at deploy time; it can call models in the project by default. Other resources (for example the search service) need explicit role assignments.
- **azure.yaml**: the single azd manifest for the project, model, and agent service.
- **Deploy modes**: `container` (Dockerfile, used here) or `code` (ZIP upload and remote build).

## Starting state
`python scripts/lab_state.py status` shows 3.1a to 3.5b enabled (and 5.1 if you completed Module 5). If you did Module 6, the local container works; if you skipped it, that's fine — `azd` builds the image in Azure.

## Resources used
Foundry project (existing), model deployment, Azure Container Registry (created or selected by `azd`; in an instructor-led workshop, the shared registry your instructor provides), hosted agent compute (billed while sessions are active), optional search service (in a workshop, the shared one).

## Steps

### 7.1 Sign in and check tools
```powershell
azd version
azd extension list
azd auth login
```
`azure.ai.agents` must be installed and compatible with your `azd` version. If `azd` reports an incompatible extension, update `azd` first.

**What you should see** (captured 7 October 2026 with `azd` 1.34.1):

```text
PS> azd version
azd version 1.34.1 (commit ...) (stable)

PS> azd extension list
ID                   NAME                         STATUS         INSTALLED       LATEST
───────────────────────────────────────────────────────────────────────────────────────
azure.ai.agents      Foundry agents (Beta)        Up to date     1.0.0-beta.16   1.0.0-beta.16
microsoft.foundry    Microsoft Foundry (Beta)     Up to date     1.0.0-beta.2    1.0.0-beta.2
...
```

> **If step 7.1 fails in the terminal (common):** the Foundry extension auto-updated to a build that your `azd` version doesn't support, so `azd extension list` shows `azure.ai.agents` with **STATUS = Incompatible** and later `azd ai agent …` commands may fail or print a warning. (A mismatch often still runs with a warning, but if a command errors out, this is the usual cause.) Fix it by matching the versions:
>
> ```powershell
> azd version                                     # note your azd version
> azd extension list                              # look for "Incompatible" in the STATUS column
> # Option A (recommended): update azd, then the extension
> powershell -ex AllSigned -c "Invoke-RestMethod 'https://aka.ms/install-azd.ps1' | Invoke-Expression"
> azd extension update azure.ai.agents
> # Option B: pin the extension build this lab was validated with
> azd extension install azure.ai.agents --version 1.0.0-beta.16
> ```
>
> Re-run `azd extension list` and confirm `azure.ai.agents` shows **Up to date** (or at least not **Incompatible**) before continuing.

### 7.2 Initialize the azd project around the existing code
From the **repository root**:

```powershell
azd ai agent init --src ./app --agent-name issue-triage-hosted --deploy-mode container `
  --project-id "<project-resource-id>" --model-deployment "<model-deployment-name>" --protocol responses -e triage-lab
```
Answer the prompts. When asked about a container registry, prefer an **existing** registry your instructor provides (or pass `--acr-connection <connection-name>`).

> **Instructor-led workshop:** use the command in your handout file `<your-id>.module7.txt`. It adds `--no-prompt`, which is safe here because `init` only writes local files and you skip `azd provision` (the step that would create a registry). The shared registry is already set up: your instructor gave you permission to build images in it and gave your project permission to pull from it. No hosted-agent Search role assignment is needed for this deployment-only exercise.

> **Cost warning (validated):** if you run `azd provision` without pointing `azd` at an existing registry (for example with `--no-prompt`), `azd` plans a **new resource group** named `rg-<environment>-foundry` (for example `rg-triage-lab-foundry`) with a **Premium** Azure Container Registry, billed daily. Delete that resource group during cleanup ([cost-and-cleanup.md](../cost-and-cleanup.md)). In a workshop you never run `azd provision`.

The command generates `azure.yaml` at the repository root, `app/.agentignore`, and an `.azure/<environment>` folder (ignored by Git). It doesn't overwrite your code.

> **Warning (from Microsoft Learn):** when you initialize against an existing project with `--project-id`, the tooling skips the automatic role assignments it performs for new projects. Your instructor must confirm the roles in the [role checklist](../instructor-guide.md#role-checklist).

### 7.3 Review and complete azure.yaml
1. Open the generated `azure.yaml` and compare it with [deployment/azure.yaml.reference](../../deployment/azure.yaml.reference). Keep what `azd` generated; only add what's missing. In validation, `azd` generated:
   - `ai-project` with `endpoint: ${FOUNDRY_PROJECT_ENDPOINT}` (connects to your existing project),
   - the agent service with `language: docker`, `docker: remoteBuild: true` (the image is built in Azure Container Registry, so local Docker isn't needed), `kind: hosted`, the `responses` protocol, `startupCommand: python main.py`, and `cpu: "0.5"` / `memory: 1Gi`,
   - `env: AZURE_AI_MODEL_DEPLOYMENT_NAME: ${AZURE_AI_MODEL_DEPLOYMENT_NAME}` (the app accepts this name as well as `MICROSOFT_FOUNDRY_MODEL_DEPLOYMENT_NAME`).
2. Add these entries under the agent service `env:` if you completed Module 5:

   ```yaml
   AZURE_SEARCH_ENDPOINT: ${AZURE_SEARCH_ENDPOINT}
   AZURE_SEARCH_KNOWLEDGE_BASE_NAME: ${AZURE_SEARCH_KNOWLEDGE_BASE_NAME}
   LOG_LEVEL: INFO
   ```
   Don't add `FOUNDRY_PROJECT_ENDPOINT` or other `FOUNDRY_*` variables: the platform injects them.
3. Set the values in the azd environment (stored under `.azure/`, not in source):

   ```powershell
   azd env set AZURE_SEARCH_ENDPOINT https://<search-service>.search.windows.net -e triage-lab   # Module 5 only
   azd env set AZURE_SEARCH_KNOWLEDGE_BASE_NAME kbtriage -e triage-lab                           # Module 5 only (shared workshop: your own name, for example kbtriage-s01)
   ```

### 7.4 Provision (and optionally test locally with azd)
```powershell
azd provision -e triage-lab
```
Validated: about 1-2 minutes; it creates the container registry and its project connection. Optional: `azd ai agent run` starts the agent locally with the `startupCommand` and opens the Agent Inspector; in a second terminal, `azd ai agent invoke --local "Triage issue ISS-1001"`. Stop it with **Ctrl+C**.

> **Instructor-led workshop: skip this step.** `azd provision` runs a subscription-level deployment, which you aren't allowed to do (`AuthorizationFailed`), and the registry already exists. Instead, run the `azd env set` lines in your handout `<your-id>.module7.txt` (they point `azd` at the shared registry), then go straight to 7.5. If `azd` ever offers to create a new registry or resource group, stop and ask your instructor.

### 7.5 Deploy the hosted agent
```powershell
azd deploy -e triage-lab
```
`azd` packages the `app` folder, builds the image in Azure Container Registry, creates a hosted agent version, and polls until it's active (validated: about 2.5 minutes). The output ends with `SUCCESS` and the next steps (`azd ai agent show`, `azd ai agent invoke`).

**What you should see** (abbreviated):

```text
Packaging services (azd deploy)
  (✓) Done: Packaging service issue-triage-hosted
Deploying services (azd deploy)
  (✓) Done: Building image in Azure Container Registry
  (✓) Done: Deploying hosted agent issue-triage-hosted (version 1)
  Waiting for agent version to become active... active

SUCCESS: Your application was deployed to Azure in 2 minutes 30 seconds.

Next steps:
  - Show status:  azd ai agent show issue-triage-hosted -e triage-lab
```

The tooling may also suggest invoking the agent. **Do not run that suggestion in this lab**; continue only with deployment verification.

> **SCREENSHOT PLACEHOLDER** - `docs/images/m07-azd-deploy-success.png`
> - **Screen**: terminal showing a successful `azd deploy -e triage-lab` - the Packaging and Deploying steps with green checks and the `SUCCESS` line.
> - **Navigation**: run `azd deploy -e triage-lab` from the repository root (step 7.5).
> - **Redact**: subscription/tenant IDs, resource IDs, and your user name. See [docs/images/README.md](../images/README.md).

### 7.6 Verify deployment status
```powershell
azd ai agent show issue-triage-hosted -e triage-lab --output json
```
Check `"status": "active"`, the `container_configuration.image`, the `environment_variables`, `agent_endpoints.responses`, and `instance_identity.principal_id` (the agent identity). In the Foundry portal, `issue-triage-hosted` appears under **Build** > **Agents** with type **Hosted**.

**What you should see** (trimmed JSON; your IDs and endpoints differ):

```json
{
  "name": "issue-triage-hosted",
  "status": "active",
  "container_configuration": { "image": "<registry>.azurecr.io/issue-triage-hosted:1" },
  "agent_endpoints": { "responses": "https://<project-endpoint>/.../responses" },
  "instance_identity": { "principal_id": "00000000-0000-0000-0000-000000000000" }
}
```

If the version is not yet `active`, wait a minute and check again. The principal ID identifies the hosted agent, but no role assignment or principal-ID handoff is required in this exercise.

> **SCREENSHOT PLACEHOLDER** - `docs/images/m07-azd-agent-show.png`
> - **Screen**: terminal showing `azd ai agent show ... --output json` with `"status": "active"` and the container image, endpoints, and `instance_identity.principal_id` visible.
> - **Navigation**: run step 7.6 after a successful deploy.
> - **Redact**: the project endpoint, resource IDs, and the `principal_id` GUID. See [docs/images/README.md](../images/README.md).

**Module 7 is complete once deployment succeeds and the version is active.** Continue with the Prompt Agent `issue-triage-agent` in Module 8. Do not start a hosted-agent chat or configure hosted-agent tracing.

## Cleanup (when instructed)
The hosted agent is not needed for Modules 8 and 9. When your instructor asks you to remove the deployment (or at the end of the lab):

```powershell
azd ai agent delete issue-triage-hosted --force -e triage-lab
```
`--force` terminates active sessions. Don't run `azd down` against a shared or existing project unless your instructor confirms what it deletes. In an instructor-led workshop, delete only your own hosted agent: the registry and resource group are shared and your instructor removes them. Otherwise remove the `azd`-created resource group (`rg-<environment>-foundry`, which holds the Premium container registry) and the lab resource group as described in [cost-and-cleanup.md](../cost-and-cleanup.md).

## Expected output
- `azd deploy` ends with the agent playground link and endpoint.
- `azd ai agent show` reports an active version.
- No hosted-agent invocation, runtime test, or trace is required.

## Verification checkpoint
- [ ] `azd deploy` completes successfully.
- [ ] `azd ai agent show` reports `"status": "active"` and the expected container image.
- [ ] The agent appears in the portal with type **Hosted**.

## Common errors and recovery
| Symptom | Likely cause | Recovery |
|---|---|---|
| `azure.ai.agents` extension incompatible (`STATUS = Incompatible`), `azd ai agent …` fails in the terminal | `azd` and the Foundry extension versions don't match (the extension auto-updated) | Update `azd`, then `azd extension update --all` (or pin with `azd extension install azure.ai.agents --version 1.0.0-beta.16`). See the detailed note in step 7.1. |
| Authorization error during deploy | Missing **Foundry Project Manager** | Ask the instructor; wait a few minutes after assignment. |
| Image pull failure | Project managed identity lacks registry access | Instructor assigns **Container Registry Repository Reader** on the registry. |
| Agent version fails to start | Module 3 steps not enabled in the image, or a missing environment variable | `azd ai agent monitor`; `python scripts/lab_state.py upto 3.5`; check `env:` in `azure.yaml`; `azd deploy` again. |
| Remote build fails with `the --mount option requires BuildKit` | A Dockerfile uses BuildKit-only syntax | Azure Container Registry builds don't support it; use the provided Dockerfile. |
| Region not supported | Region not in the hosted-agent list | Use a supported region for the lab project. |

## Knowledge check
1. Which identity does the hosted agent use to call the model?
2. Why must you not declare `FOUNDRY_PROJECT_ENDPOINT` in `azure.yaml`?
3. When does a hosted agent stop consuming compute?

<details><summary>Answers</summary>

1. Its platform-created Microsoft Entra agent identity.
2. The platform injects it; `FOUNDRY_*` names are reserved.
3. After the idle timeout with no requests (default 15 minutes); the session state is persisted.
</details>

## References
- [Hosted agents in Foundry Agent Service](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents)
- [Quickstart: Deploy your first hosted agent](https://learn.microsoft.com/azure/foundry/agents/quickstarts/quickstart-hosted-agent)
- [Initialize a hosted agent project with azd](https://learn.microsoft.com/azure/foundry/agents/how-to/init-agent-project)
- [Author azure.yaml for hosted agents](https://learn.microsoft.com/azure/foundry/agents/how-to/author-azure-yaml) and [azure.yaml reference](https://learn.microsoft.com/azure/foundry/agents/concepts/azure-yaml-reference)
- [Deploy a hosted agent](https://learn.microsoft.com/azure/foundry/agents/how-to/deploy-hosted-agent)
- [Hosted agent permissions reference](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agent-permissions)
- [Foundry Hosted Agents (Agent Framework)](https://learn.microsoft.com/agent-framework/hosting/foundry-hosted-agent)

> **Documentation gaps:** (1) The documentation doesn't state that, without an existing registry, `azd ai agent init` creates a separate `rg-<environment>-foundry` resource group with a Premium registry (observed in validation). (2) The knowledge base provider's need for the **Reader** role isn't documented. (3) The agent identity principal ID is available as `instance_identity.principal_id` in `azd ai agent show --output json` (validated) and in the agent YAML.
