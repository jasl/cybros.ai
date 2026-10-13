# Install with an agent

A coding agent with terminal access to the target machine can perform the stack installation for you. Give it this prompt:

```text
Help me install Cybros (Nexus + rho) on this machine and reach my first conversation.
Use the public source and guides at https://github.com/jasl/cybros.ai on main,
or my existing checkout. Follow the rolling installation instructions.

Read the "Install the stack" and "Your first conversation" guides first. Check that
Docker is running and Compose v2 is available; help me resolve missing prerequisites.
Use the documented stack installer with local-only access and the default
installation directory unless I specify otherwise. Preserve existing settings
and data. In a noninteractive shell, pass --yes to the documented installer.
Open the ordinary rho URL. Guide me through Connect to Nexus, direct first-owner
creation, application authorization and the return to rho. Choose the default
model under Settings > Defaults. The default installation requires no setup secret or
extra terminal step. If the operator
explicitly configured NEXUS_SETUP_SECRET, use the private instructions shown by
./cybros instructions for that optional check.
For a home-server deployment, use the documented explicit LAN HTTP mode if I
choose it; ordinary users should not need an SSH tunnel.

Let me create the Nexus account and enter provider credentials directly in the
browser. Keep private setup links and other secrets out of chat and shared logs;
no secrets.env lookup is needed. Existing registrations reconnect through the
same OAuth approval flow; logging in to a connected instance preserves its work.
Check service health, rho's connection and available models as setup progresses.
Give me the installation directory and saved browser URLs, and walk me through
the first-conversation guide. Report any remaining steps clearly; service health
alone does not prove that a model request works.
```

What the prompt deliberately keeps with you:

- Creating the owner account and entering provider credentials happen in your browser, not in the agent's transcript.
- Private setup links and `secrets.env` stay out of chat and logs.
- The agent verifies health and model discovery, but a successful model request is confirmed by your own first conversation.
