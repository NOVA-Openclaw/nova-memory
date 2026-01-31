/**
 * Memory Extraction Hook for Clawdbot
 * 
 * Automatically extracts entities, facts, opinions, and relationships
 * from incoming messages and stores them in the PostgreSQL memory database.
 * 
 * REQUIRES: message:received event (currently planned, not yet implemented)
 * 
 * Setup:
 * 1. Install scripts from this repo
 * 2. Set ANTHROPIC_API_KEY environment variable
 * 3. Configure PostgreSQL connection
 * 4. Enable hook: clawdbot hooks enable memory-extract
 */

import type { HookHandler } from 'clawdbot';
import { exec } from 'child_process';
import { promisify } from 'util';
import { join } from 'path';

const execAsync = promisify(exec);

// Configure path to scripts (adjust for your installation)
const SCRIPTS_DIR = process.env.NOVA_MEMORY_SCRIPTS || join(process.env.HOME || '', 'clawd/scripts');

const handler: HookHandler = async (event) => {
  // Log that we were triggered
  console.log('[memory-extract] Event received:', event.type, event.action);
  
  // Only process message:received events
  if (event.type !== 'message' || event.action !== 'received') {
    return;
  }
  
  // Extract message content from event context
  const message = (event.context as any)?.message 
    || (event.context as any)?.text
    || (event as any).message;
    
  if (!message || typeof message !== 'string') {
    console.log('[memory-extract] No message content found in event');
    return;
  }
  
  // Skip very short messages (likely not containing extractable info)
  if (message.length < 20) {
    console.log('[memory-extract] Message too short, skipping');
    return;
  }
  
  console.log('[memory-extract] Processing message:', message.substring(0, 100) + '...');
  
  // Get sender info if available
  const sender = (event.context as any)?.senderId 
    || (event.context as any)?.sender
    || 'unknown';
  
  // Prefix message with sender context for better extraction
  const contextualMessage = sender !== 'unknown' 
    ? `${sender} said: ${message}`
    : message;
  
  // Run extraction script asynchronously (fire and forget)
  const scriptPath = join(SCRIPTS_DIR, 'process-input.sh');
  const escapedMessage = contextualMessage.replace(/"/g, '\\"').replace(/\$/g, '\\$');
  
  try {
    execAsync(`"${scriptPath}" "${escapedMessage}"`)
      .then(({ stdout, stderr }) => {
        if (stdout) console.log('[memory-extract] Extraction output:', stdout.substring(0, 200));
        if (stderr) console.error('[memory-extract] Extraction stderr:', stderr.substring(0, 200));
        console.log('[memory-extract] Extraction complete');
      })
      .catch(err => {
        console.error('[memory-extract] Extraction failed:', err.message);
      });
  } catch (err) {
    console.error('[memory-extract] Failed to start extraction:', err);
  }
};

export default handler;
