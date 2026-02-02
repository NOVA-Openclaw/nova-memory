/**
 * Message hook events for message:received and message:sent
 *
 * These hooks enable automation around the message lifecycle:
 * - message:received — fires when an inbound message is about to be processed
 * - message:sent — fires after an outbound message is successfully delivered
 */
import { createInternalHookEvent, triggerInternalHook } from "./internal-hooks.js";
/**
 * Trigger message:received hook
 * Call this when an inbound message is about to be processed by the agent
 */
export async function triggerMessageReceived(sessionKey, ctx) {
    const hookEvent = createInternalHookEvent("message", "received", sessionKey, {
        message: ctx.Body ?? "",
        rawBody: ctx.RawBody,
        senderId: ctx.SenderId,
        senderName: ctx.SenderName,
        channel: ctx.Provider,
        messageId: ctx.MessageSid,
        isGroup: ctx.ChatType === "group",
        groupId: ctx.ChatType === "group" ? ctx.From : undefined,
        timestamp: ctx.Timestamp,
        commandAuthorized: ctx.CommandAuthorized,
    });
    await triggerInternalHook(hookEvent);
}
/**
 * Trigger message:sent hook
 * Call this after an outbound message is successfully delivered
 */
export async function triggerMessageSent(sessionKey, payload, context) {
    const hookEvent = createInternalHookEvent("message", "sent", sessionKey, {
        text: payload.text,
        mediaUrl: payload.mediaUrl,
        target: context.target,
        channel: context.channel,
        kind: context.kind,
    });
    await triggerInternalHook(hookEvent);
}
