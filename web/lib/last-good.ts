import "server-only";

/// Keeps the last successful payload for a read route so a slow or failing dependency
/// degrades into slightly-old numbers rather than an empty page.
///
/// BOT Chain's public RPC has been observed taking many seconds just to open a connection,
/// and the previous behaviour — 503, render nothing — turned that latency into a page that
/// looked broken and said nothing true. A financial figure must never be replaced by zero,
/// but showing the last real one and saying it is stale is both honest and useful.
type Entry = { value: unknown; at: number };

const store = new Map<string, Entry>();

export async function withLastGood<T extends object>(
  key: string,
  freshFor: number,
  read: () => Promise<T>,
): Promise<{ body: T & { stale: boolean; readAt: string }; ok: boolean }> {
  const cached = store.get(key);
  if (cached && Date.now() - cached.at < freshFor) {
    return { body: { ...(cached.value as T), stale: false, readAt: new Date(cached.at).toISOString() }, ok: true };
  }

  try {
    const value = await read();
    store.set(key, { value, at: Date.now() });
    return { body: { ...value, stale: false, readAt: new Date().toISOString() }, ok: true };
  } catch (error) {
    console.error(`Live read failed for ${key}`, error);
    if (!cached) return { body: null as never, ok: false };
    return { body: { ...(cached.value as T), stale: true, readAt: new Date(cached.at).toISOString() }, ok: true };
  }
}
