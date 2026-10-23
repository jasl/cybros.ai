import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { defineConfig, type SiteConfig } from 'vitepress'

const title = 'Cybros'
const description = 'A self-hosted managed agent kernel: Nexus, rho and runners.'

// The public documentation site. Markdown under guides/ is the source; the
// internal development manual under docs/ is not part of this site.
export default defineConfig({
  title,
  description,
  lang: 'en-US',
  cleanUrls: true,
  lastUpdated: true,

  buildEnd: writeLlmExports,

  markdown: {
    config(md) {
      // Prompt macros such as `{{agent}}` appear in inline code throughout the
      // reference. Fenced blocks are already rendered verbatim; inline code is
      // not, and Vue would otherwise compile the mustache as an expression.
      const renderInlineCode = md.renderer.rules.code_inline!
      md.renderer.rules.code_inline = (tokens, index, options, env, self) => {
        if (tokens[index].content.includes('{{')) {
          return `<code v-pre>${md.utils.escapeHtml(tokens[index].content)}</code>`
        }
        return renderInlineCode(tokens, index, options, env, self)
      }
    },
  },

  themeConfig: {
    nav: [
      { text: 'Overview', link: '/overview/what-is-cybros', activeMatch: '^/(overview|get-started)/' },
      { text: 'Use rho', link: '/use/conversations', activeMatch: '^/use/' },
      { text: 'Operate', link: '/operate/deployment-layouts', activeMatch: '^/operate/' },
      { text: 'Build agents', link: '/build/', activeMatch: '^/build/' },
      { text: 'Runners', link: '/runners/', activeMatch: '^/runners/' },
      { text: 'Reference', link: '/reference/', activeMatch: '^/reference/' },
    ],

    sidebar: {
      '/overview/': overviewSidebar(),
      '/get-started/': overviewSidebar(),
      '/use/': [
        {
          text: 'Use rho',
          items: [
            { text: 'Conversations', link: '/use/conversations' },
            { text: 'Approvals and questions', link: '/use/approvals-and-questions' },
            { text: 'Models, workspaces and runners', link: '/use/models-workspaces-runners' },
            { text: 'Terminal requests', link: '/use/terminal-requests' },
            { text: 'Files, images and memory', link: '/use/files-images-memory' },
            { text: 'Schedules', link: '/use/schedules' },
            { text: 'Agent Presets', link: '/use/agent-presets' },
            { text: 'Agents and bots', link: '/use/sub-agents' },
            { text: 'Telegram', link: '/use/telegram' },
            { text: 'Editors (ACP)', link: '/use/editors-acp' },
            { text: 'Plugins and code mode', link: '/use/plugins-and-code-mode' },
            { text: 'Troubleshooting', link: '/use/troubleshooting' },
          ],
        },
      ],
      '/operate/': [
        {
          text: 'Operate',
          items: [
            { text: 'Deployment layouts', link: '/operate/deployment-layouts' },
            { text: 'Deploy with Dokploy', link: '/operate/dokploy' },
            { text: 'Models and providers', link: '/operate/models-and-providers' },
            { text: 'Reuse a model definition', link: '/operate/model-definitions' },
            { text: 'Users', link: '/operate/members' },
            { text: 'Inspect and recover work', link: '/operate/work-console' },
            { text: 'Export retained data', link: '/operate/export-data' },
            { text: 'Read and cancel Conversation inputs', link: '/operate/read-conversation-inputs' },
            { text: 'Inspect running corrections', link: '/operate/inspect-running-corrections' },
            { text: 'Organize a Conversation', link: '/operate/organize-conversation' },
            { text: 'Recover a Conversation cost limit', link: '/operate/recover-conversation-cost' },
            { text: 'Connect and inspect an Agent', link: '/operate/connect-agent' },
            { text: 'Inspect an Agent configuration', link: '/operate/configure-an-agent' },
            { text: 'Schedules and results', link: '/operate/schedules' },
            { text: 'Workspace data', link: '/operate/workspace-data' },
            { text: 'Balances and allowances', link: '/operate/budgets' },
            { text: 'Workspaces and access', link: '/operate/workspaces-and-access' },
            { text: 'Retention, usage and budgets', link: '/operate/retention-usage-budgets' },
            { text: 'Status, logs and upgrades', link: '/operate/status-logs-upgrades' },
            { text: 'Backup and restore', link: '/operate/backup-and-restore' },
            { text: 'cmctl', link: '/operate/cmctl' },
          ],
        },
      ],
      '/build/': [
        {
          text: 'Build agents',
          items: [
            { text: 'Overview', link: '/build/' },
            { text: 'Quickstart', link: '/build/quickstart' },
            { text: 'Standalone SDK Agent', link: '/build/standalone-agent' },
            { text: 'HTTP MCP Agent', link: '/build/http-mcp-agent' },
            { text: 'Offline application', link: '/build/offline-agents' },
            { text: 'Credentials and planes', link: '/build/credentials-and-planes' },
            { text: 'Agents and configuration', link: '/build/agents-and-configuration' },
            { text: 'Conversations and inputs', link: '/build/conversations-and-inputs' },
            { text: 'Events and streaming', link: '/build/events-and-streaming' },
            { text: 'Orchestration', link: '/build/orchestration' },
            { text: 'Approvals and rules', link: '/build/approvals-and-rules' },
            { text: 'Schedules', link: '/build/schedules' },
            { text: 'Lifecycle hooks', link: '/build/lifecycle-hooks' },
            { text: 'Memory, store and uploads', link: '/build/memory-store-and-uploads' },
            { text: 'Direct model calls', link: '/build/direct-model-calls' },
            { text: 'Errors and recovery', link: '/build/errors-and-recovery' },
            { text: 'Usage and cost', link: '/build/usage-and-cost' },
            { text: 'SDKs', link: '/build/sdks' },
            { text: 'Ruby SDK', link: '/build/sdk-ruby' },
            { text: 'TypeScript SDK', link: '/build/sdk-typescript' },
            { text: 'Rust SDK', link: '/build/sdk-rust' },
          ],
        },
      ],
      '/runners/': [
        {
          text: 'Runners and tool providers',
          items: [
            { text: 'Overview', link: '/runners/' },
            { text: 'Quickstart', link: '/runners/quickstart' },
            { text: 'Deploy a runner', link: '/runners/deploy' },
            { text: 'Tools and announcements', link: '/runners/tools-and-announcements' },
            { text: 'Claims and results', link: '/runners/claims-and-results' },
            { text: 'Captures and files', link: '/runners/captures-and-files' },
            { text: 'Tool providers', link: '/runners/tool-providers' },
            { text: 'Security model', link: '/runners/security-model' },
            { text: 'Monitor and troubleshoot', link: '/runners/monitor-and-troubleshoot' },
          ],
        },
      ],
      '/reference/': [
        {
          text: 'Reference',
          items: [
            { text: 'Index', link: '/reference/' },
            { text: 'Events', link: '/reference/events' },
            { text: 'Statuses', link: '/reference/statuses' },
            { text: 'Rate limits', link: '/reference/rate-limits' },
            { text: 'Kernel tools', link: '/reference/kernel-tools' },
            { text: 'Command line', link: '/reference/cli' },
            { text: 'Glossary', link: '/reference/glossary' },
          ],
        },
        {
          text: 'Agent API v1',
          collapsed: false,
          items: [
            { text: 'Common contract', link: '/reference/agent-api' },
            { text: 'Profile', link: '/reference/agent-api/profile' },
            { text: 'Agent configuration', link: '/reference/agent-api/profile-configuration' },
            { text: 'Named Agents', link: '/reference/agent-api/profile-agents' },
            { text: 'Memory collections', link: '/reference/agent-api/memory-collections' },
            { text: 'Profile memory collections', link: '/reference/agent-api/profile-memory' },
            { text: 'Profile prompt documents', link: '/reference/agent-api/profile-prompt-documents' },
            { text: 'Runs', link: '/reference/agent-api/runs' },
            { text: 'Attention', link: '/reference/agent-api/attention' },
            { text: 'Work report', link: '/reference/agent-api/work-report' },
            { text: 'Work analysis', link: '/reference/agent-api/work-analysis' },
            { text: 'Run tools', link: '/reference/agent-api/run-tools' },
            { text: 'Run orchestration', link: '/reference/agent-api/run-orchestration' },
            { text: 'Run steps', link: '/reference/agent-api/run-steps' },
            { text: 'Run statuses and failure', link: '/reference/agent-api/run-statuses' },
            { text: 'Run approval', link: '/reference/agent-api/run-approval' },
            { text: 'Run compaction', link: '/reference/agent-api/run-compaction' },
            { text: 'Run feeds', link: '/reference/agent-api/run-feeds' },
            { text: 'Prompt assembly', link: '/reference/agent-api/prompt-assembly' },
            { text: 'Tool assembly', link: '/reference/agent-api/tool-assembly' },
            { text: 'MCP connections', link: '/reference/agent-api/mcp-connections' },
            { text: 'Conversations', link: '/reference/agent-api/conversations' },
            { text: 'Conversation inputs', link: '/reference/agent-api/conversation-inputs' },
            { text: 'Conversation input fields', link: '/reference/agent-api/conversation-input-fields' },
            { text: 'Kernel mail', link: '/reference/agent-api/conversation-kernel-mail' },
            { text: 'Conversation turns', link: '/reference/agent-api/conversation-turns' },
            { text: 'Conversation context', link: '/reference/agent-api/conversation-context' },
            { text: 'Conversation feeds', link: '/reference/agent-api/conversation-feeds' },
            { text: 'Conversation memory', link: '/reference/agent-api/conversation-memory' },
            { text: 'Conversation history', link: '/reference/agent-api/conversation-history' },
            { text: 'Conversation export', link: '/reference/agent-api/conversation-export' },
            { text: 'Conversation reasoning', link: '/reference/agent-api/conversation-reasoning' },
            { text: 'Execution retention', link: '/reference/agent-api/execution-retention' },
            { text: 'Schedules', link: '/reference/agent-api/schedules' },
            { text: 'Workspaces', link: '/reference/agent-api/workspaces' },
            { text: 'Store entries', link: '/reference/agent-api/store-entries' },
            { text: 'InferenceRequests', link: '/reference/agent-api/inference-requests' },
            { text: 'Uploads', link: '/reference/agent-api/uploads' },
            { text: 'Models and providers', link: '/reference/agent-api/models' },
            { text: 'Executor', link: '/reference/agent-api/executor' },
            { text: 'Executor inbox', link: '/reference/agent-api/executor-inbox' },
            { text: 'Executor operations', link: '/reference/agent-api/executor-operations' },
            { text: 'Task realtime', link: '/reference/agent-api/task-realtime' },
            { text: 'Ingress speakers', link: '/reference/agent-api/ingress' },
          ],
        },
        {
          text: 'Platform API v1',
          collapsed: true,
          items: [
            { text: 'Common contract', link: '/reference/platform-api' },
            { text: 'Session', link: '/reference/platform-api/session' },
            { text: 'Profile', link: '/reference/platform-api/profile' },
            { text: 'Balances and allowances', link: '/reference/platform-api/budgets' },
            { text: 'Persona', link: '/reference/platform-api/persona' },
            { text: 'Agent settings', link: '/reference/platform-api/agents' },
            { text: 'Agent API keys', link: '/reference/platform-api/agent-api-keys' },
            { text: 'Managed Runners', link: '/reference/platform-api/runners' },
            { text: 'MCP connections', link: '/reference/platform-api/mcp-connections' },
            { text: 'Admin users', link: '/reference/platform-api/admin-users' },
            { text: 'Admin deployment', link: '/reference/platform-api/admin-deployment' },
            { text: 'Admin budgets', link: '/reference/platform-api/admin-budgets' },
            { text: 'Admin models', link: '/reference/platform-api/admin-models' },
            { text: 'Account retention', link: '/reference/platform-api/retention' },
            { text: 'Admin model usage', link: '/reference/platform-api/admin-model-usage' },
            { text: 'Provider authorization', link: '/reference/platform-api/provider-authorization' },
          ],
        },
        {
          text: 'OAuth',
          collapsed: true,
          items: [
            { text: 'Overview', link: '/reference/oauth' },
            { text: 'Application login', link: '/reference/oauth/application-login' },
            { text: 'Device flow', link: '/reference/oauth/device-flow' },
          ],
        },
      ],
    },

    search: { provider: 'local' },
    socialLinks: [{ icon: 'github', link: 'https://github.com/jasl/cybros.ai' }],
    editLink: {
      pattern: 'https://github.com/jasl/cybros.ai/edit/main/guides/:path',
      text: 'Edit this page',
    },
    outline: [2, 3],
    footer: {
      message: 'Nexus is licensed O\u2019Saasy. The rest of the repository defaults to MIT.',
    },
  },
})

// LLM readers get what the reference vendors publish: an index at /llms.txt,
// the whole site at /llms-full.txt, and each page at its source .md path.
// Directory indexes use /index.md. Frontmatter is dropped; the body is the source as
// written, so VitePress containers appear in their fenced spelling.
async function writeLlmExports(site: SiteConfig) {
  const pages = site.pages.filter((page) => !page.startsWith('zh/')).sort()
  const index: string[] = []
  const full: string[] = []

  for (const page of pages) {
    const source = await readFile(join(site.srcDir, page), 'utf8')
    const { body, data } = splitFrontmatter(source)
    const route = '/' + page.replace(/(^|\/)index\.md$/, '$1').replace(/\.md$/, '')
    const pageTitle = data.title ?? body.match(/^#\s+(.+)$/m)?.[1] ?? route
    const pageDescription = data.description ?? firstParagraph(body)

    const target = join(site.outDir, page)
    await mkdir(dirname(target), { recursive: true })
    await writeFile(target, body)

    index.push(`- [${pageTitle}](/${page})${pageDescription ? `: ${pageDescription}` : ''}`)
    full.push(`<!-- ${route} -->\n\n${body.trim()}`)
  }

  const header = `# ${title}\n\n> ${description}\n\nEvery page is available as Markdown at the links below. Directory home pages use \`index.md\`. The complete site is at /llms-full.txt.\n\n## Pages\n\n`
  await writeFile(join(site.outDir, 'llms.txt'), header + index.join('\n') + '\n')
  await writeFile(join(site.outDir, 'llms-full.txt'), full.join('\n\n---\n\n') + '\n')
}

function splitFrontmatter(source: string): { body: string; data: Record<string, string> } {
  const match = source.match(/^---\n([\s\S]*?)\n---\n/)
  if (!match) return { body: source, data: {} }
  const data: Record<string, string> = {}
  for (const line of match[1].split('\n')) {
    const field = line.match(/^(title|description):\s*(.+)$/)
    if (field) data[field[1]] = field[2].trim().replace(/^['"]|['"]$/g, '')
  }
  return { body: source.slice(match[0].length), data }
}

function firstParagraph(body: string): string {
  const paragraph = body
    .split(/\n\s*\n/)
    .map((block) => block.trim())
    .find((block) => block && !/^(#|\||-|\*|:::|```|<|\d+\.)/.test(block))
  if (!paragraph) return ''
  const text = paragraph.replace(/\s+/g, ' ').replace(/\[([^\]]+)\]\([^)]*\)/g, '$1').replace(/[`*_]/g, '')
  return text.length > 200 ? `${text.slice(0, 197).trimEnd()}…` : text
}

function overviewSidebar() {
  return [
    {
      text: 'Overview',
      items: [
        { text: 'What is Cybros?', link: '/overview/what-is-cybros' },
        { text: 'Core concepts', link: '/overview/core-concepts' },
        { text: 'Architecture', link: '/overview/architecture' },
        { text: 'Coming from managed agents', link: '/overview/coming-from-managed-agents' },
        { text: 'Release and compatibility', link: '/overview/release-and-compatibility' },
        { text: 'Roadmap', link: '/overview/roadmap' },
      ],
    },
    {
      text: 'Get started: the default bundle',
      items: [
        { text: 'Install the stack', link: '/get-started/install' },
        { text: 'Your first conversation', link: '/get-started/first-conversation' },
        { text: 'Install with an agent', link: '/get-started/install-with-an-agent' },
        { text: 'Connect a host installation', link: '/get-started/connect-a-host-installation' },
      ],
    },
    {
      text: 'Get started: your own agent',
      items: [
        { text: 'Build your own agent', link: '/get-started/build-an-agent' },
        { text: 'Agent API quickstart', link: '/build/quickstart' },
        { text: 'Runner quickstart', link: '/runners/quickstart' },
        { text: 'Nexus development on macOS', link: '/get-started/install-on-macos' },
      ],
    },
  ]
}
