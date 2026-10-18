---
layout: home

hero:
  name: Cybros
  text: A managed agent kernel you host yourself.
  tagline: Nexus keeps your conversations, drives the agent loop, gates tool calls and delivers tool work to runners on your own machines. rho, the agent that ships with it, is a personal assistant and a coding agent in one.
  actions:
    - theme: brand
      text: Install the default bundle
      link: /get-started/install
    - theme: alt
      text: Build your own agent
      link: /get-started/build-an-agent
    - theme: alt
      text: What is Cybros?
      link: /overview/what-is-cybros

features:
  - title: Use rho
    details: The default agent. Talk to it in a browser, in Telegram or from your editor; it remembers, schedules, asks before risky actions and works on your files through a runner. Enough for most daily needs out of the box.
    link: /use/conversations
    linkText: Use rho
  - title: Build your own agent
    details: Nexus runs the loop, keeps history, routes tools and records usage. Your application owns prompts, model choice and policy. rho is the reference implementation — it uses nothing you cannot use.
    link: /get-started/build-an-agent
    linkText: Build an agent
  - title: Run tools where the files are
    details: Runners execute tools on a workstation, a server or a container and only ever dial out. Execution environments are separate from the kernel by design.
    link: /runners/
    linkText: Runners
---

## Choose your starting point

| You want to | Start here |
| --- | --- |
| Use the default bundle — Nexus and rho on your own machine or server | [Install the stack](/get-started/install), then [use rho](/use/conversations) |
| Run Cybros for a small team: models, members, upgrades and backups | [Operate](/operate/deployment-layouts) |
| Build an agent application with your own prompts, interface or channel | [Build your own agent](/get-started/build-an-agent) |
| Add an execution environment — a laptop, a server, a container | [Runners](/runners/) |
| Call models directly through the configured providers | [Direct model calls](/build/direct-model-calls) |
| Look up an endpoint, an event type, a status or a limit | [Reference](/reference/) |

## What Cybros is

- **Nexus** is the kernel and gateway: one Account with human and agent members, workspaces, conversations, durable runs, model access across providers, tool delivery, approvals, usage accounting and retention.
- **rho** is the default agent application: an always-on personal agent and a coding agent, served through a browser page, Telegram, an ACP server for editors and a CLI. It is built only on Nexus's public APIs and is the reference for building your own.
- **Runners** and **tool providers** execute tools. They register with Nexus, announce what they serve and claim work from an inbox over outbound HTTP.

Cybros is built for professional users and small teams who want a managed agent platform without sending their work to a hosted harness. It runs on a laptop, a LAN server or a public host. The source is at [jasl/cybros.ai](https://github.com/jasl/cybros.ai).
