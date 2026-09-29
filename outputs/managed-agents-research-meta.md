# Managed Agents Research — Meta (and "Meta cloud agents")

*Compiled 2026-09-29. All claims trace to primary Meta sources (about.fb.com, Meta GitHub) unless marked otherwise; secondary sources are flagged inline. Lens: what Meta actually ships in managed-agent infrastructure, what it manages, execution substrate, control plane, continuation/handoff, pricing.*

## Scope

Covered: Meta's consumer personal agent (Muse) and its execution substrate (Muse Secure VM, Sentinel), the business-facing agent line (Meta Business Agent / Business Agent Platform), the brand-new Meta Enterprise Platform (announced 2026-09-28), the model layer (Muse Spark, Llama, Llama/Meta Model API), open infrastructure for running agents (Llama Stack → OGX), the Manus acquisition/unwind, and whether a product named "Meta cloud agents" exists.

Deliberately skipped: Meta's consumer chatbot Meta AI (not an agent platform), AI glasses hardware, ads/Andromeda, training infrastructure (MTIA, data centers), and Meta's internal-agent research (e.g. "Meta Agents" HCI papers) — none are managed-agent *offerings*.

## Key Findings

1. **There is no Meta product named "Meta cloud agents."** A Meta Newsroom search for "cloud agents" returns no product or announcement under that name (https://about.fb.com/news/). The closest actual offerings are **Muse** (consumer personal agent), **Meta Business Agent** (SMB customer-service agent), and **Meta Enterprise Platform** (umbrella, announced 2026-09-28). Inference: the phrase "Meta cloud agents" in the market refers to Muse's cloud-VM architecture, not a product.

2. **Muse is Meta's flagship managed agent and its architecture is the most Keg-relevant data point in this cluster.** Announced 2026-09-08: every user gets a **dedicated Muse Secure VM** — "a dedicated, virtual machine (VM) that houses both the agent and a person's data… Muse runs on its own dedicated computer in the cloud, contained so no one else's agent can reach it" (https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/). Per-user isolation, browser, credential store — i.e., **one microVM-equivalent per agent**, the same one-VM-per-workload bet Keg makes with Apple Container.

3. **Meta ships a two-agent permission architecture: Muse proposes, a separate Sentinel agent disposes.** "A separate Sentinel agent runs on that same machine, kept apart from Muse at the system level. Nothing Muse does reaches the internet unless the Sentinel approves it, and it asks the person for permission when needed." Credentials go into secure storage the agent "can use… without seeing them"; users get per-app/per-scope access grants, an audit trail of everything done and planned, and can revoke or opt out of training. A **Muse Confidential VM** (whole-VM encryption with a user-held key, "so not even Meta can access it") is promised "later this year" (https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/). This is a direct reference design for Keg's approval gate + secrets handling.

4. **Continuation model = the agent lives in the cloud VM, not on the device.** "For tasks that take more time, Muse keeps working after people close the app, and comes back when something changes or when it needs approval" (https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/). Surfaces (iOS/Android app, muse.ai, WhatsApp, AI glasses "coming months", plus a Mac app reported 2026-09-18 by TechCrunch — secondary: https://techcrunch.com/2026/09/18/metas-muse-hits-mac-letting-the-ai-take-actions-on-your-computer/) are all thin clients over the cloud-resident session; Connect 2026 added connectors (Notion, Granola, GitHub, Box, Shopify catalog, Stripe Link/ShopPay/PayPal) and "Muse gets its own email address" (https://about.fb.com/news/2026/09/the-biggest-news-from-connect-2026/). There is no local→cloud migration of state because state is never local — the inverse of Keg's local-first-with-cloud-continuation pitch.

5. **Payments/commerce are first-class in the loop.** Muse checks out via Stripe Link with one-time-use virtual cards and is "the first AI agent covered by Link's purchase protections"; 1Password support announced (https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/). Zuckerberg also floated a transaction fee on agent-completed purchases (secondary: https://superpowerdaily.com/posts/meta-adds-muse-to-its-ai-glasses-as-it-builds-toward-agent-led-shopping). Control plane = Meta's cloud; approvals surface on whichever client the user has.

6. **Pricing posture: freemium consumer subscription, token-metered.** Newsroom: "free for most of what people need, with subscription plans for people who want to do more" (https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/). Reported tiers (secondary, consistent across multiple outlets citing Meta's help center): Free (~100M tokens/week), Power $20/mo (500M tokens/week), Maximum $100/mo (3B tokens/week) — e.g. https://www.layer3labs.io/guides/meta-muse-pricing, https://gingerlabs.ai/blog/meta-muse-agent-capabilities-and-how-to-use-it. Not directly verified against a Meta page (help center behind JS/bot wall).

7. **Meta Business Agent (2026-06-03) is Meta's managed agent for SMBs, with an extensibility platform.** "Meta Business Agent – AI that lets every business show up for every customer… can be set up in minutes or plugged directly into your existing enterprise infrastructure" across WhatsApp, Messenger, Instagram (https://about.fb.com/news/2026/06/meta-business-agent/). Secondary coverage: a companion **Meta Business Agent Platform** lets businesses/partners build and deploy agents at scale with integrations (Shopify, Zendesk, Shopee cited), free to start, paid tiers announced but unpriced (https://www.yugatech.com/news/meta-launches-meta-business-agent-for-whatsapp-messenger-and-instagram/, https://news.creeta.com/en/meta-business-ai-whatsapp-messenger-instagram-2026/).

8. **Meta Enterprise Platform (2026-09-28, i.e. yesterday) is the umbrella that formalizes Meta as a managed-agent vendor for business.** Zuckerberg: "we will focus on bringing our full technology stack, including **the Muse agent, Meta Business Agent, Muse API, Muse Code, and more** to businesses and developers" (https://about.fb.com/news/2026/09/launching-meta-enterprise-platform/). Led by new Chief Enterprise Platform Officer Chirantan "CJ" Desai (ex-MongoDB CEO); "security and privacy are built into Meta's enterprise products from the outset." This names **Muse API** and **Muse Code** as developer-facing products. Pricing/details not yet published.

9. **The model layer has shifted from open Llama to proprietary Muse Spark for agentic work.** Muse is "powered by Muse Spark, Meta's most capable model to date, built for real-world agentic work" (https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/). Muse Spark (2026-04-08, first model from Meta Superintelligence Labs) launched with Meta AI and "private preview via API to select partners" with hope to "open-source future versions" (https://about.fb.com/news/2026/04/introducing-muse-spark-meta-superintelligence-labs/). Note: Llama 4 Scout/Maverick are under an EU usage restriction as of June 2026 (secondary: https://www.digitalapplied.com/blog/meta-ai-business-agents-enterprise-llama-launch-2026).

10. **The Llama API exists but its current status is murky.** Announced at LlamaCon 2025-04-29 as a limited preview, free during preview, OpenAI-SDK-compatible, no training on customer data (https://www.theverge.com/meta/658057/meta-developers-api-llama-ai-model). Today llama.com serves a JS-rendered site titled "Meta Model API — Products & Solutions for AI Developers | Meta" (observed fetching https://llama.com/ and https://llama.meta.com/docs/ on 2026-09-29) — suggesting a rebrand to "Meta Model API" aligning with the Enterprise Platform's "Muse API," but page content could not be extracted, so this is **unverified**.

11. **Meta's open agent infrastructure, Llama Stack, is no longer Meta's — it was renamed OGX and re-scoped.** The GitHub repo (meta-llama/llama-stack → ogx-ai/ogx) now states: "**Llama Stack is now OGX.** The name changed, and so did the mission — model-agnostic, multi-SDK, production-grade" (https://github.com/ogx-ai/ogx). Per the official migration post, OGX is "a server-side agentic loop that speaks the native API of every major frontier lab," implementing OpenAI Responses/Chat, Anthropic Messages, and Google Interactions APIs with built-in RAG, MCP, skills, vector stores — 23 inference providers, runs "on your laptop, your datacenter, or the cloud" (https://ogx-ai.github.io/blog/from-llama-stack-to-ogx). Inference only: "isn't an inference server — it routes to inference backends like vLLM, Ollama, or Bedrock." It manages agent *orchestration* (tool loop, conversation state, RAG, skills) but not sandboxes, git, secrets, or checkpoints. Whether Meta still controls the project post-rename is not stated on either page (inference: moved to a neutral org; Red Hat ships it in OpenShift AI per https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_ogx/llama-stack-to-ogx-migration_rag).

12. **The Manus acquisition — Meta's big agent acqui-hire — was unwound.** Meta announced the acquisition 2025-12-29 (~$2B, per Reuters via secondary) to deploy "advanced AI agents across its social media, messaging and enterprise platforms" (https://www.tmtpost.com/7825433.html). China ordered the deal revoked; by 2026-09-01 "Manus formally resumes independent operations, after Meta's acquisition deal ordered to be revoked" (https://www.globaltimes.cn/page/202609/1369553.shtml); Manus is now raising independently at a reported $4B valuation (https://techcrunch.com/2026/09/18/manus-seeks-4b-valuation-in-new-500m-fundraise-as-it-resumes-independent-ops/). Net: Meta kept some integration work but not the company.

## Comparison notes

(Bullets for the cross-offering table; "—" = not offered / not applicable)

- **Muse (consumer personal agent)**
  - Manages: per-user agent + data + credentials, goals/plans, long-term memory ("tell it to forget"), audit trail, approval queue (Sentinel); checkpoints — not mentioned
  - Substrate: one dedicated Muse Secure VM (Linux VM + browser) per user, in Meta's cloud; agent harness further sandboxed (secondary detail: systemd-nspawn container per engineering post coverage — not primary-verified)
  - Control plane: Meta cloud (VM fleet); approval requests surface on any client
  - Continuation: cloud-native — session persists in the VM; all clients (app/WhatsApp/web/glasses/Mac) are views. No local↔cloud handoff because nothing runs locally (except reported Mac-app actions, secondary)
  - Pricing: free tier + $20/$100 per month tiers (secondary-reported; token allowances weekly)
  - Local component: none required (Mac app reported as an action surface, not an execution surface)
- **Meta Business Agent (+ Business Agent Platform)**
  - Manages: business knowledge, customer conversations, handoff to humans, integrations; substrate: Meta-hosted, surfaces inside WhatsApp/Messenger/Instagram
  - Control plane: Meta; platform APIs for partners/builders; pricing: free at launch, paid tiers announced unpriced
- **Meta Enterprise Platform (Muse API, Muse Code, agents for business)** — announced 2026-09-28; enterprise deployment of the same stack; details/pricing TBD; leader: CJ Desai
- **Llama/Meta Model API** — hosted inference API (limited preview 2025; current status/rebrand unverified); no agent management
- **OGX (ex-Llama Stack)** — open-source server-side agentic loop (OpenAI/Anthropic/Google API surfaces, MCP, RAG, skills); substrate: you run it (laptop/DC/cloud); no sandbox/git/secrets/checkpoint management; control plane: self-hosted; pricing: OSS (Apache-style licensing not re-verified)
- **Llama open weights** — downloadable models; every major cloud (Bedrock, OCI, etc.) hosts them; this is the "bring your own model" substrate many managed-agent vendors build on, not a managed-agent product itself

## Unverified / uncertain

- **"Meta cloud agents" as a named product: confirmed absent** from Meta Newsroom as of 2026-09-29 (search returned no such product; only cloud-*gaming* from 2021). Confidence high.
- Muse tier prices/allowances ($20/$100, weekly token quotas) are consistently reported by secondary sources citing Meta's help center, but I could not load the help-center/pricing page itself (meta.com/muse.ai bot-blocked/JS).
- The detailed Muse security engineering post (isolated runtime cells, credential surrogates, taint-tracked egress, eBPF) is widely quoted and clearly exists on Meta's site (ai.meta.com / engineering.fb.com), but I could not extract its URL or text directly; all primary claims above come from the Newsroom post instead. The deeper mechanism claims (nspawn, eBPF) are secondary-only here.
- Muse Mac app capabilities ("take actions on your computer") — TechCrunch (secondary) only; no Meta newsroom post found.
- Muse Confidential VM — promised "later this year" (2026); shipping status unknown as of 2026-09-29.
- Llama API current branding/pricing ("Meta Model API" title observed on llama.com; content not extractable); whether it remains a distinct product under Meta Enterprise Platform's "Muse API" is unclear.
- Muse API / Muse Code — named in the Enterprise Platform post; no docs, pricing, or GA dates published yet.
- OGX governance: the rename post and GitHub org (ogx-ai) don't state Meta's ongoing role; treated as de-Meta'd pending evidence.
- Manus deal terms ($2B) and unwind mechanics — secondary sources (Reuters/Global Times/TechCrunch); Meta published no newsroom post on either event that I could find.

## Sources

1. https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/ — *Introducing Muse* (Meta Newsroom, 2026-09-08) — primary
2. https://about.fb.com/news/2026/09/the-biggest-news-from-connect-2026/ — Connect 2026 recap (Meta Newsroom, 2026-09-25) — primary
3. https://about.fb.com/news/2026/04/introducing-muse-spark-meta-superintelligence-labs/ — *Introducing Muse Spark* (Meta Newsroom, 2026-04-08, updated 2026-05-12) — primary
4. https://about.fb.com/news/2026/06/meta-business-agent/ — *Be There for Every Customer With Meta Business Agent* (Meta Newsroom, 2026-06-03) — primary (partial extraction)
5. https://about.fb.com/news/2026/09/launching-meta-enterprise-platform/ — *Launching Meta Enterprise Platform* (Meta Newsroom, 2026-09-28) — primary
6. https://about.fb.com/news/ — Meta Newsroom index (used for negative search: no "cloud agents" product) — primary
7. https://github.com/ogx-ai/ogx — OGX repo (formerly meta-llama/llama-stack) — primary (vendor-controlled repo)
8. https://ogx-ai.github.io/blog/from-llama-stack-to-ogx — *From Llama Stack to OGX* (OGX blog, 2026-04-28) — primary
9. https://llama.com/ and https://llama.meta.com/docs/ — observed page title "Meta Model API — Products & Solutions for AI Developers | Meta" (content JS-rendered, not extractable)
10. https://www.theverge.com/meta/658057/meta-developers-api-llama-ai-model — Llama API limited-preview announcement coverage (2025-04-29) — secondary
11. https://techcrunch.com/2026/09/18/metas-muse-hits-mac-letting-the-ai-take-actions-on-your-computer/ — Muse Mac app — secondary
12. https://www.layer3labs.io/guides/meta-muse-pricing and https://gingerlabs.ai/blog/meta-muse-agent-capabilities-and-how-to-use-it — Muse tier pricing reported from Meta help center — secondary
13. https://www.yugatech.com/news/meta-launches-meta-business-agent-for-whatsapp-messenger-and-instagram/ and https://news.creeta.com/en/meta-business-ai-whatsapp-messenger-instagram-2026/ — Business Agent Platform details/pricing posture — secondary
14. https://www.tmtpost.com/7825433.html and https://www.globaltimes.cn/page/202609/1369553.shtml and https://techcrunch.com/2026/09/18/manus-seeks-4b-valuation-in-new-500m-fundraise-as-it-resumes-independent-ops/ — Manus acquisition and unwind — secondary
15. https://superpowerdaily.com/posts/meta-adds-muse-to-its-ai-glasses-as-it-builds-toward-agent-led-shopping — transaction-fee monetization intent — secondary
16. https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_ogx/llama-stack-to-ogx-migration_rag — Red Hat OpenShift AI ships OGX — primary (partner docs)
