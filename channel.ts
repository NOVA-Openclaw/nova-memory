import pg from "pg";
import type {
  ChannelPlugin,
  OpenClawConfig,
  ChannelGatewayContext,
  ChannelMeta,
} from "openclaw/plugin-sdk";
import { getAgentChatRuntime } from "./runtime.js";
import { AgentChatConfigSchema, type ResolvedAgentChatAccount } from "./config.js";

const { Client } = pg;

const PLUGIN_ID = "agent_chat";

// Manual meta definition since "agent_chat" is not in the core channel allowlist
const meta: Omit<ChannelMeta, "id"> = {
  label: "Agent Chat",
  selectionLabel: "Agent Chat",
  docsPath: "/channels/agent_chat",
  blurb: "PostgreSQL-based agent messaging via agent_chat table",
  order: 999,
};

/**
 * Create PostgreSQL client from config
 */
function createPgClient(config: {
  host: string;
  port: number;
  database: string;
  user: string;
  password: string;
}) {
  return new Client({
    host: config.host,
    port: config.port,
    database: config.database,
    user: config.user,
    password: config.password,
  });
}

/**
 * Get all identifiers for this agent (config name, database name, aliases)
 * Returns lowercase normalized identifiers for case-insensitive matching
 */
async function getAgentIdentifiers(client: pg.Client, agentName: string): Promise<string[]> {
  const identifiers: string[] = [];
  
  // Always include the agentName from config (normalized to lowercase)
  identifiers.push(agentName.toLowerCase());
  
  // Query database for agent's name and aliases
  const query = `
    SELECT DISTINCT LOWER(identifier) as identifier
    FROM (
      -- Get agent name from agents table
      SELECT a.name as identifier
      FROM agents a
      WHERE LOWER(a.name) = LOWER($1)
      
      UNION
      
      -- Get agent nickname from agents table (if exists)
      SELECT a.nickname as identifier
      FROM agents a
      WHERE LOWER(a.name) = LOWER($1)
        AND a.nickname IS NOT NULL
      
      UNION
      
      -- Get all aliases for this agent
      SELECT aa.alias as identifier
      FROM agents a
      JOIN agent_aliases aa ON a.id = aa.agent_id
      WHERE LOWER(a.name) = LOWER($1)
    ) all_identifiers
    WHERE identifier IS NOT NULL
  `;
  
  try {
    const result = await client.query(query, [agentName]);
    
    // Add all database identifiers (already lowercase from query)
    for (const row of result.rows) {
      if (!identifiers.includes(row.identifier)) {
        identifiers.push(row.identifier);
      }
    }
  } catch (error) {
    // If query fails (e.g., table doesn't exist yet), just use agentName
    // This provides backward compatibility
    console.error('Error fetching agent identifiers:', error);
  }
  
  return identifiers;
}

/**
 * Resolve a human-friendly target identifier to an agent's name (agentName)
 * Searches: agents.name, agents.nickname, agent_aliases.alias
 * Returns the agent's name field for use in mentions array
 * 
 * This is the reverse operation of getAgentIdentifiers() - instead of
 * "given agentName, find all identifiers", this does "given any identifier, find agentName"
 */
async function resolveAgentName(client: pg.Client, target: string): Promise<string> {
  // Normalize target for case-insensitive matching
  const normalizedTarget = target.toLowerCase().trim();
  
  if (!normalizedTarget) {
    throw new Error('Target cannot be empty');
  }
  
  // Query to find agent by any identifier (name, nickname, or alias)
  const query = `
    SELECT DISTINCT a.name
    FROM agents a
    LEFT JOIN agent_aliases aa ON a.id = aa.agent_id
    WHERE 
      LOWER(a.name) = $1
      OR LOWER(a.nickname) = $1
      OR LOWER(aa.alias) = $1
    LIMIT 1
  `;
  
  try {
    const result = await client.query(query, [normalizedTarget]);
    
    if (result.rows.length === 0) {
      throw new Error(`Agent not found: ${target}`);
    }
    
    return result.rows[0].name;
  } catch (error) {
    // Re-throw with context
    if ((error as Error).message.includes('Agent not found')) {
      throw error;
    }
    throw new Error(`Error resolving agent name for "${target}": ${(error as Error).message}`);
  }
}

/**
 * Fetch unprocessed messages for this agent from agent_chat table
 * Matches against multiple identifiers: agentName (config), database name, and aliases (case-insensitive)
 */
async function fetchUnprocessedMessages(client: pg.Client, agentName: string) {
  // Get all identifiers for this agent (already normalized to lowercase)
  const identifiers = await getAgentIdentifiers(client, agentName);
  
  // Build query that checks if any mention matches any identifier (case-insensitive)
  const query = `
    SELECT ac.id, ac.channel, ac.sender, ac.message, ac.mentions, ac.reply_to, ac.created_at
    FROM agent_chat ac
    LEFT JOIN agent_chat_processed acp ON ac.id = acp.chat_id AND LOWER(acp.agent) = LOWER($1)
    WHERE EXISTS (
      SELECT 1
      FROM unnest(ac.mentions) AS mention
      WHERE LOWER(mention) = ANY($2::text[])
    )
    AND acp.chat_id IS NULL
    ORDER BY ac.created_at ASC
  `;

  const result = await client.query(query, [agentName, identifiers]);
  return result.rows;
}

/**
 * Mark message as received (initial state)
 */
async function markMessageReceived(client: pg.Client, chatId: number, agentName: string) {
  const query = `
    INSERT INTO agent_chat_processed (chat_id, agent, status, received_at)
    VALUES ($1, LOWER($2), 'received', NOW())
    ON CONFLICT (chat_id, agent) DO UPDATE
    SET received_at = COALESCE(agent_chat_processed.received_at, NOW())
  `;

  await client.query(query, [chatId, agentName]);
}

/**
 * Mark message as routed (passed to agent session)
 */
async function markMessageRouted(client: pg.Client, chatId: number, agentName: string) {
  const query = `
    UPDATE agent_chat_processed
    SET status = 'routed', routed_at = NOW()
    WHERE chat_id = $1 AND LOWER(agent) = LOWER($2)
  `;

  await client.query(query, [chatId, agentName]);
}

/**
 * Mark message as responded (agent replied)
 */
async function markMessageResponded(client: pg.Client, chatId: number, agentName: string) {
  const query = `
    UPDATE agent_chat_processed
    SET status = 'responded', responded_at = NOW()
    WHERE chat_id = $1 AND LOWER(agent) = LOWER($2)
  `;

  await client.query(query, [chatId, agentName]);
}

/**
 * Mark message as failed with error
 */
async function markMessageFailed(
  client: pg.Client,
  chatId: number,
  agentName: string,
  errorMsg: string,
) {
  const query = `
    UPDATE agent_chat_processed
    SET status = 'failed', error_message = $3
    WHERE chat_id = $1 AND LOWER(agent) = LOWER($2)
  `;

  await client.query(query, [chatId, agentName, errorMsg]);
}

/**
 * Insert outbound message into agent_chat
 */
async function insertOutboundMessage(
  client: pg.Client,
  {
    channel,
    sender,
    message,
    mentions,
    replyTo,
  }: {
    channel: string;
    sender: string;
    message: string;
    mentions?: string[];
    replyTo: number | null;
  },
) {
  const query = `
    INSERT INTO agent_chat (channel, sender, message, mentions, reply_to, created_at)
    VALUES ($1, $2, $3, $4, $5, NOW())
    RETURNING id
  `;

  const result = await client.query(query, [channel, sender, message, mentions || [], replyTo || null]);

  return result.rows[0];
}

/**
 * Build session label for agent_chat message
 */
function buildSessionLabel({
  channel,
  sender,
  chatId,
}: {
  channel: string;
  sender: string;
  chatId: number;
}) {
  return `${PLUGIN_ID}:${channel}:${sender}:${chatId}`;
}

/**
 * Process a single message from agent_chat
 */
async function processAgentChatMessage({
  message,
  client,
  agentName,
  cfg,
  ctx,
}: {
  message: {
    id: number;
    channel: string;
    sender: string;
    message: string;
    mentions: string[];
    reply_to: number | null;
    created_at: Date;
  };
  client: pg.Client;
  agentName: string;
  cfg: OpenClawConfig;
  ctx: ChannelGatewayContext<ResolvedAgentChatAccount>;
}) {
  const log = ctx.log;
  const runtime = getAgentChatRuntime();

  log?.info?.(`Processing message ${message.id} from ${message.sender}`);

  try {
    // Mark as received first
    await markMessageReceived(client, message.id, agentName);
    log?.debug?.(`Marked message ${message.id} as received`);

    // Build session label
    const sessionLabel = buildSessionLabel({
      channel: message.channel,
      sender: message.sender,
      chatId: message.id,
    });

    // Format the inbound message envelope
    const envelopeOptions = runtime.channel.reply.resolveEnvelopeFormatOptions(cfg);
    const fromLabel = `${message.sender} (${message.channel})`;
    const body = runtime.channel.reply.formatInboundEnvelope({
      channel: "AgentChat",
      from: fromLabel,
      timestamp: message.created_at ? new Date(message.created_at).getTime() : undefined,
      body: message.message,
      chatType: "direct",
      sender: { name: message.sender, id: message.sender },
      envelope: envelopeOptions,
    });

    // Build the inbound context
    const agentChatTo = `agent_chat:${message.channel}`;
    const ctxPayload = runtime.channel.reply.finalizeInboundContext({
      Body: body,
      RawBody: message.message,
      CommandBody: message.message,
      From: `agent_chat:${message.sender}`,
      To: agentChatTo,
      SessionKey: sessionLabel,
      ChatType: "direct",
      ConversationLabel: fromLabel,
      SenderName: message.sender,
      SenderId: message.sender,
      Provider: "agent_chat",
      Surface: "agent_chat",
      MessageSid: String(message.id),
      Timestamp: message.created_at ? new Date(message.created_at).getTime() : undefined,
      OriginatingChannel: "agent_chat",
      OriginatingTo: agentChatTo,
    });

    // Create reply dispatcher that sends replies back to agent_chat table
    const { dispatcher, replyOptions, markDispatchIdle } =
      runtime.channel.reply.createReplyDispatcherWithTyping({
        deliver: async (payload, info) => {
          try {
            await insertOutboundMessage(client, {
              channel: message.channel,
              sender: agentName,
              message: payload.text || "",
              mentions: [], // Replies don't need mentions - original message already has routing
              replyTo: message.id,
            });

            // Mark as responded
            await markMessageResponded(client, message.id, agentName);
            log?.info?.(`Sent reply for message ${message.id}`);
          } catch (err) {
            log?.error?.(`Failed to send reply for message ${message.id}: ${err}`);
            throw err;
          }
        },
        onError: (err, info) => {
          log?.error?.(`${info.kind} reply failed: ${err}`);
        },
      });

    // Dispatch the message to the agent using dispatchReplyFromConfig
    log?.info?.(`🚀 Dispatching message ${message.id} to agent...`);

    try {
      await runtime.channel.reply.dispatchReplyFromConfig({
        ctx: ctxPayload,
        cfg,
        dispatcher,
        replyOptions,
      });

      markDispatchIdle();

      log?.info?.(`✅ Successfully dispatched message ${message.id}`);
      await markMessageRouted(client, message.id, agentName);
    } catch (dispatchError) {
      log?.error?.(`❌ Dispatch error for message ${message.id}: ${dispatchError}`);
      await markMessageFailed(
        client,
        message.id,
        agentName,
        (dispatchError as Error).message,
      );
    }
  } catch (error) {
    // Mark as failed if routing fails
    await markMessageFailed(client, message.id, agentName, (error as Error).message);
    log?.error?.(`Failed to route message ${message.id}: ${error}`);
  }
}

/**
 * Start monitoring agent_chat for this account
 */
async function startAgentChatMonitor(
  ctx: ChannelGatewayContext<ResolvedAgentChatAccount>,
): Promise<void> {
  const { agentName, pollIntervalMs } = ctx.account.config;
  const log = ctx.log;

  log?.info?.(
    `Starting monitor for agent: ${agentName} @ ${ctx.account.config.host}:${ctx.account.config.port}/${ctx.account.config.database}`,
  );

  const client = createPgClient(ctx.account.config);

  try {
    await client.connect();
    log?.info?.(`Connected to PostgreSQL`);

    // Listen to agent_chat channel
    await client.query("LISTEN agent_chat");
    log?.info?.(`Listening on channel 'agent_chat'`);

    // Handle notifications
    client.on("notification", async (msg) => {
      if (msg.channel === "agent_chat") {
        log?.debug?.(`Received notification`);

        try {
          const messages = await fetchUnprocessedMessages(client, agentName);

          for (const message of messages) {
            await processAgentChatMessage({
              message,
              client,
              agentName,
              cfg: ctx.cfg,
              ctx,
            });
          }
        } catch (error) {
          log?.error?.(`Error processing notification: ${error}`);
        }
      }
    });

    // Initial check for existing unprocessed messages
    const initialMessages = await fetchUnprocessedMessages(client, agentName);
    log?.info?.(`Found ${initialMessages.length} unprocessed messages on startup`);

    for (const message of initialMessages) {
      await processAgentChatMessage({
        message,
        client,
        agentName,
        cfg: ctx.cfg,
        ctx,
      });
    }

    // Keep connection alive
    const keepAliveInterval = setInterval(() => {
      if (!ctx.abortSignal?.aborted) {
        client.query("SELECT 1").catch((err) => {
          log?.error?.(`Keep-alive failed: ${err}`);
        });
      }
    }, pollIntervalMs);

    // Handle abort signal
    if (ctx.abortSignal) {
      ctx.abortSignal.addEventListener("abort", async () => {
        log?.info?.(`Received abort signal`);
        clearInterval(keepAliveInterval);
        try {
          await client.query("UNLISTEN agent_chat");
          await client.end();
          log?.info?.(`Disconnected from PostgreSQL`);
        } catch (error) {
          log?.error?.(`Error during shutdown: ${error}`);
        }
      });
    }

    // Wait for abort
    return new Promise<void>((resolve) => {
      if (ctx.abortSignal) {
        ctx.abortSignal.addEventListener("abort", () => resolve());
      }
    });
  } catch (error) {
    log?.error?.(`Fatal error: ${error}`);
    try {
      await client.end();
    } catch (cleanupError) {
      // Ignore cleanup errors
    }
    throw error;
  }
}

/**
 * Normalize agent_chat messaging target
 */
function normalizeAgentChatMessagingTarget(raw: string): string | undefined {
  const trimmed = raw.trim();
  if (!trimmed) return undefined;

  let normalized = trimmed;

  // Strip 'agent_chat:' prefix (case-insensitive)
  if (normalized.toLowerCase().startsWith("agent_chat:")) {
    normalized = normalized.slice("agent_chat:".length).trim();
  }
  // Strip 'agent:' prefix (case-insensitive)
  else if (normalized.toLowerCase().startsWith("agent:")) {
    normalized = normalized.slice("agent:".length).trim();
  }

  if (!normalized) return undefined;

  return normalized;
}

/**
 * Check if raw string looks like an agent_chat target ID
 */
function looksLikeAgentChatTargetId(raw: string): boolean {
  const trimmed = raw.trim();
  if (!trimmed) return false;

  // Accept 'agent:' or 'agent_chat:' prefixes
  if (/^(agent_chat:|agent:)/i.test(trimmed)) return true;

  // Accept bare agent names (alphanumeric, underscore, hyphen)
  return /^[a-zA-Z0-9_-]+$/.test(trimmed);
}

/**
 * Agent Chat Channel Plugin
 */
export const agentChatPlugin: ChannelPlugin<ResolvedAgentChatAccount> = {
  id: PLUGIN_ID,

  meta: {
    id: PLUGIN_ID,
    ...meta,
  },

  capabilities: {
    chatTypes: ["direct", "group"],
    media: false,
    reactions: false,
    threads: false,
  },

  reload: {
    configPrefixes: ["channels.agent_chat"],
  },

  configSchema: AgentChatConfigSchema,

  messaging: {
    normalizeTarget: normalizeAgentChatMessagingTarget,
    targetResolver: {
      looksLikeId: looksLikeAgentChatTargetId,
      hint: "<AgentName|agent:AgentName|agent_chat:AgentName>",
    },
  },

  config: {
    listAccountIds: (cfg) => {
      const channelConfig = cfg.channels?.agent_chat;
      if (!channelConfig) return [];

      const accounts = ["default"];
      if (channelConfig.accounts) {
        accounts.push(...Object.keys(channelConfig.accounts));
      }
      return accounts;
    },

    resolveAccount: (cfg, accountId) => {
      const channelConfig = cfg.channels?.agent_chat;

      if (!channelConfig) {
        return {
          accountId: accountId || "default",
          name: accountId || "default",
          enabled: false,
          config: {
            agentName: "",
            database: "",
            host: "",
            port: 5432,
            user: "",
            password: "",
            pollIntervalMs: 1000,
          },
        } as ResolvedAgentChatAccount;
      }

      const normalizedAccountId = accountId || "default";
      const config =
        normalizedAccountId === "default"
          ? channelConfig
          : channelConfig.accounts?.[normalizedAccountId] || {};

      return {
        accountId: normalizedAccountId,
        name: config.name || normalizedAccountId,
        enabled: config.enabled !== false,
        config: {
          agentName: config.agentName || "",
          database: config.database || "",
          host: config.host || "",
          port: config.port || 5432,
          user: config.user || "",
          password: config.password || "",
          pollIntervalMs: config.pollIntervalMs || 1000,
        },
      } as ResolvedAgentChatAccount;
    },

    defaultAccountId: () => "default",

    isConfigured: (account, cfg) =>
      Boolean(
        account.config.agentName &&
          account.config.database &&
          account.config.host &&
          account.config.user &&
          account.config.password,
      ),

    describeAccount: (account, cfg) => ({
      accountId: account.accountId,
      name: account.name,
      enabled: account.enabled,
      configured: Boolean(
        account.config.agentName &&
          account.config.database &&
          account.config.host &&
          account.config.user &&
          account.config.password,
      ),
      agentName: account.config.agentName,
      database: account.config.database,
      host: account.config.host,
    }),
  },

  outbound: {
    deliveryMode: "direct",
    textChunkLimit: 4000, // PostgreSQL text field - generous limit

    sendText: async ({ cfg, to, text, accountId }) => {
      const account = agentChatPlugin.config!.resolveAccount(cfg, accountId);

      if (!agentChatPlugin.config!.isConfigured?.(account, cfg)) {
        throw new Error(`agent_chat account ${accountId} not configured`);
      }

      const client = createPgClient(account.config);

      try {
        await client.connect();

        // Extract channel from 'to' parameter (format: "agent_chat:channel" or just "channel")
        let channel = to.includes(":") ? to.split(":").pop() || "default" : to;
        
        // Resolve the target to an agentName for the mentions array
        // This enables human-friendly targets like "Newhart" (nickname) 
        // to be resolved to "nhr-agent" (agentName) for proper message routing
        let targetAgentName: string;
        try {
          targetAgentName = await resolveAgentName(client, channel);
        } catch (error) {
          // If resolution fails, throw a helpful error
          throw new Error(
            `Failed to resolve target agent "${channel}": ${(error as Error).message}. ` +
            `Ensure the target agent exists in the agents table with name, nickname, or alias matching "${channel}".`
          );
        }

        const result = await insertOutboundMessage(client, {
          channel: "direct", // Use "direct" as default channel for agent-to-agent messages
          sender: account.config.agentName,
          message: text,
          mentions: [targetAgentName], // Add resolved agentName to mentions array
          replyTo: null, // Could be enhanced to track reply_to from context
        });

        return {
          channel: PLUGIN_ID,
          messageId: String(result.id),
          success: true,
        };
      } finally {
        await client.end();
      }
    },
  },

  gateway: {
    startAccount: async (ctx) => {
      return await startAgentChatMonitor(ctx);
    },
  },

  status: {
    defaultRuntime: {
      accountId: "default",
      running: false,
      lastStartAt: null,
      lastStopAt: null,
      lastError: null,
    },

    buildChannelSummary: ({ snapshot }) => ({
      configured: snapshot.configured ?? false,
      running: snapshot.running ?? false,
      // agentName and database stored in probe for custom display
      agentName: (snapshot.probe as { agentName?: string })?.agentName ?? null,
      database: (snapshot.probe as { database?: string })?.database ?? null,
    }),

    buildAccountSnapshot: ({ account, runtime }) => ({
      accountId: account.accountId,
      name: account.name,
      enabled: account.enabled,
      configured: Boolean(
        account.config.agentName &&
          account.config.database &&
          account.config.host &&
          account.config.user &&
          account.config.password,
      ),
      running: runtime?.running ?? false,
      lastStartAt: runtime?.lastStartAt ?? null,
      lastStopAt: runtime?.lastStopAt ?? null,
      lastError: runtime?.lastError ?? null,
      // Store custom info in probe
      probe: {
        agentName: account.config.agentName,
        database: account.config.database,
      },
    }),
  },
};
