"use client";

import { useCallback, useEffect, useMemo, useState } from "react";

type Seller = {
  key: "honest" | "faulty" | "absent";
  name: string;
  archetype: "honest" | "faulty" | "absent";
  agentId: string | null;
  endpoint: string;
  priceBot: string;
  service: string;
  description: string;
  configured: boolean;
  bond: { gross: string; reserved: string; free: string } | null;
};

type Job = {
  id: string;
  sellerAgentId: string;
  amountBot: string;
  reservedBondBot: string;
  statusLabel: string;
  responseDeadline: number;
  proofs: Record<string, string>;
};

type LiveState = {
  totalJobs: string;
  activeJobs: number;
  disputedJobs: number;
  escrowedBot: string;
  bondRatioPercent: number;
  responseWindowSeconds: number;
  validationRegistryEnabled: boolean;
  buyerBalanceBot: string | null;
  writeEnabled: boolean;
  updatedAt: string;
};

type DemoEvent = {
  type: string;
  message: string;
  txHash?: string;
  requestHash?: string;
  quoteToken?: string;
  sessionToken?: string;
  jobId?: string;
  amountBot?: string;
  priceBot?: string;
  requiredBondBot?: string;
  sellerAgentId?: string;
  expiresAt?: string;
  evidenceHash?: string;
  evidenceMode?: string;
  infrastructureFailure?: boolean;
  delivery?: {
    ok: boolean;
    status: number;
    payload: Record<string, string | number | string[] | null> | null;
    faults: string[];
  };
};

type Phase = "choose" | "fund" | "inspect" | "settle";
type Verdict = "accept" | "dispute";

function usePolling<T>(path: string, interval: number) {
  const [data, setData] = useState<T>();
  const [error, setError] = useState<string>();
  const load = useCallback(async () => {
    try {
      const response = await fetch(path, { cache: "no-store" });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error || "Live read failed");
      setData(body);
      setError(undefined);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Live read failed");
    }
  }, [path]);
  useEffect(() => {
    const initial = window.setTimeout(() => void load(), 0);
    const timer = window.setInterval(() => { if (!document.hidden) void load(); }, interval);
    return () => {
      window.clearTimeout(initial);
      window.clearInterval(timer);
    };
  }, [interval, load]);
  return { data, error, retry: load };
}

async function readEventStream(
  body: Record<string, string>,
  onEvent: (event: DemoEvent) => void,
) {
  const response = await fetch("/api/live/session", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!response.ok || !response.body) {
    const payload = await response.json().catch(() => null) as { error?: string } | null;
    throw new Error(payload?.error || "The buyer-session request was rejected safely.");
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let pending = "";
  while (true) {
    const { value, done } = await reader.read();
    pending += decoder.decode(value, { stream: !done });
    const lines = pending.split("\n");
    pending = lines.pop() ?? "";
    for (const line of lines) {
      if (!line.trim()) continue;
      const event = JSON.parse(line) as DemoEvent;
      onEvent(event);
      if (event.type === "error") throw new Error(event.message);
    }
    if (done) break;
  }
  if (pending.trim()) {
    const event = JSON.parse(pending) as DemoEvent;
    onEvent(event);
    if (event.type === "error") throw new Error(event.message);
  }
}

const explorer = "https://scan.bohr.life";

export function BuyerSession() {
  const state = usePolling<LiveState>("/api/live/state", 8_000);
  const sellers = usePolling<{ sellers: Seller[] }>("/api/live/sellers", 12_000);
  const jobs = usePolling<{ jobs: Job[] }>("/api/live/jobs?limit=8", 10_000);
  const [selected, setSelected] = useState<Seller["key"]>();
  const [authorized, setAuthorized] = useState(false);
  const [accessChecked, setAccessChecked] = useState(false);
  const [accessCode, setAccessCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const [events, setEvents] = useState<DemoEvent[]>([]);
  const [quote, setQuote] = useState<DemoEvent>();
  const [delivery, setDelivery] = useState<DemoEvent>();
  const [sessionToken, setSessionToken] = useState<string>();
  const [verdict, setVerdict] = useState<Verdict>();
  const [resolved, setResolved] = useState<{ message: string; txHash: string; outcome: string }>();

  const selectedSeller = useMemo(
    () => sellers.data?.sellers.find((seller) => seller.key === selected),
    [selected, sellers.data],
  );
  const phase: Phase = delivery ? "inspect" : quote ? "fund" : "choose";
  const visualPhase: Phase = verdict || resolved ? "settle" : phase;

  useEffect(() => {
    let active = true;
    void fetch("/api/live/access", { cache: "no-store" })
      .then((response) => response.json())
      .then((body: { authorized?: boolean }) => { if (active) setAuthorized(body.authorized === true); })
      .catch(() => undefined)
      .finally(() => { if (active) setAccessChecked(true); });
    return () => { active = false; };
  }, []);

  const record = useCallback((event: DemoEvent) => {
    setEvents((current) => [...current, event]);
    if (event.type === "awaiting-funding") setQuote(event);
    if (event.type === "delivery") {
      setDelivery(event);
      setSessionToken(event.sessionToken);
    }
  }, []);

  async function unlock(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    setError(undefined);
    try {
      const response = await fetch("/api/live/access", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ code: accessCode }),
      });
      const body = await response.json() as { authorized?: boolean; error?: string };
      if (!response.ok || !body.authorized) throw new Error(body.error || "Judge access could not be verified.");
      setAuthorized(true);
      setAccessCode("");
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Judge access could not be verified.");
    } finally {
      setBusy(false);
    }
  }

  async function requestTerms() {
    if (!selected) return;
    setBusy(true);
    setError(undefined);
    setEvents([]);
    setQuote(undefined);
    setDelivery(undefined);
    setSessionToken(undefined);
    setVerdict(undefined);
    setResolved(undefined);
    try {
      await readEventStream({ action: "start", sellerKey: selected }, record);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Terms could not be requested.");
    } finally {
      setBusy(false);
    }
  }

  async function fund() {
    if (!quote?.quoteToken) return;
    setBusy(true);
    setError(undefined);
    try {
      await readEventStream({ action: "fund", quoteToken: quote.quoteToken }, record);
      await Promise.all([state.retry(), jobs.retry(), sellers.retry()]);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Funding stopped safely.");
    } finally {
      setBusy(false);
    }
  }

  async function submitVerdict(verdictChoice: Verdict) {
    if (!sessionToken) return;
    setBusy(true);
    setError(undefined);
    try {
      await readEventStream({ action: "verdict", sessionToken, verdict: verdictChoice }, record);
      setVerdict(verdictChoice);
      await Promise.all([state.retry(), jobs.retry(), sellers.retry()]);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "The verdict stopped safely.");
    } finally {
      setBusy(false);
    }
  }

  async function resolve() {
    if (!sessionToken) return;
    setBusy(true);
    setError(undefined);
    try {
      const response = await fetch("/api/live/resolve", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ sessionToken }),
      });
      const body = await response.json() as { message?: string; txHash?: string; outcome?: string; error?: string };
      if (!response.ok || !body.message || !body.txHash || !body.outcome) throw new Error(body.error || "The evidence ruling stopped safely.");
      setResolved({ message: body.message, txHash: body.txHash, outcome: body.outcome });
      setEvents((current) => [...current, { type: "resolved", message: body.message as string, txHash: body.txHash }]);
      await Promise.all([state.retry(), jobs.retry(), sellers.retry()]);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "The evidence ruling stopped safely.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <div className="live-journey" aria-label="Buyer session stages">
        {(["choose", "fund", "inspect", "settle"] as Phase[]).map((item, index) => (
          <div className={visualPhase === item ? "active" : (["choose", "fund", "inspect", "settle"].indexOf(visualPhase) > index ? "complete" : "")} key={item}>
            <span>0{index + 1}</span><strong>{item.toUpperCase()}</strong><small>{["counterparty", "escrow", "delivery", "on-chain"][index]}</small>
          </div>
        )).reduce<React.ReactNode[]>((items, item, index) => {
          if (index) items.push(<i key={`line-${index}`} />);
          items.push(item);
          return items;
        }, [])}
      </div>

      <div className="buyer-console">
        <section className="session-stage">
          <div className="stage-head">
            <div><span className="step-number">{visualPhase === "choose" ? "1" : visualPhase === "fund" ? "2" : visualPhase === "inspect" ? "3" : "4"}</span><div><p>BUYER CONTROL SURFACE</p><h2>{visualPhase === "choose" ? "Agent market" : visualPhase === "fund" ? "Funding decision" : visualPhase === "inspect" ? "Delivery inspector" : "Settlement receipt"}</h2></div></div>
            <span className={`status-chip ${state.data?.writeEnabled ? "ok" : "pending"}`}>
              {state.data?.writeEnabled ? (authorized ? "judge unlocked" : "access required") : "read-only safety mode"}
            </span>
          </div>

          {state.data?.writeEnabled && accessChecked && !authorized && (
            <form className="access-gate" onSubmit={unlock}>
              <div><p className="section-kicker">FUNDED TESTNET SESSION</p><h3>Unlock the judge buyer</h3><p>The code grants a short-lived demo session. It never exposes the wallet key or connects a personal wallet.</p></div>
              <div><label htmlFor="judge-code">Judge access code</label><input id="judge-code" type="password" autoComplete="off" value={accessCode} onChange={(event) => setAccessCode(event.target.value)} placeholder="Enter access code" /><button className="button primary" disabled={busy || !accessCode}>{busy ? "Verifying…" : "Unlock buyer →"}</button></div>
            </form>
          )}

          {(!state.data?.writeEnabled || authorized) && !delivery && (
            <>
              <div className="seller-grid">
                {sellers.data?.sellers.map((seller) => (
                  <button className={`seller-card glass ${selected === seller.key ? "selected" : ""}`} key={seller.key} onClick={() => { if (!busy && !quote) setSelected(seller.key); }} disabled={!seller.configured || busy || Boolean(quote)}>
                    <div className="seller-top"><span className={`agent-orb ${seller.archetype}`} /><span>AGENT #{seller.agentId ?? "—"}</span></div>
                    <h3>{seller.name}</h3><p>{seller.description}</p>
                    <div className="seller-meta"><strong>{seller.priceBot} BOT</strong><span>{seller.bond ? `${seller.bond.free} BOT bond free` : "awaiting registration"}</span></div>
                  </button>
                )) ?? <div className="skeleton-card">Reading seller bonds…</div>}
              </div>

              <div className={`fund-gate ${quote ? "ready" : ""}`}>
                <div>
                  <p className="section-kicker">{quote ? "VERIFIED TERMS · STOP BEFORE FUNDING" : "NO-SPEND QUOTE STEP"}</p>
                  <h3>{quote ? `${quote.priceBot} BOT held in escrow` : selectedSeller ? `Review ${selectedSeller.name}'s terms` : "Choose an agent to request terms"}</h3>
                  <p>{quote ? `Seller agent #${quote.sellerAgentId} reserves ${quote.requiredBondBot} BOT collateral. Quote expires ${new Date(quote.expiresAt as string).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}.` : selectedSeller ? `${selectedSeller.service} · ${selectedSeller.priceBot} BOT · agent #${selectedSeller.agentId}` : "No BOT moves while you browse or request terms. Funding is always a separate decision."}</p>
                </div>
                {!quote ? (
                  <button className="button primary" onClick={() => void requestTerms()} disabled={!selectedSeller || !state.data?.writeEnabled || !authorized || busy}>{busy ? "Verifying…" : "Request verified terms →"}</button>
                ) : (
                  <button className="button primary danger-confirm" onClick={() => void fund()} disabled={busy}>{busy ? "Funding on-chain…" : `Fund exactly ${quote.priceBot} BOT →`}</button>
                )}
              </div>
            </>
          )}

          {delivery?.delivery && (
            <div className="delivery-inspector">
              <div className="delivery-banner"><div><p className="section-kicker">JOB #{events.find((item) => item.type === "funded")?.jobId ?? "—"} · HASH-ONLY EVIDENCE</p><h3>{delivery.delivery.ok ? "Seller returned a payload" : "No usable delivery arrived"}</h3></div><span className={`status-chip ${delivery.delivery.ok && !delivery.delivery.faults.length ? "ok" : "pending"}`}>HTTP {delivery.delivery.status}</span></div>
              <div className="evidence-hash"><span>EVIDENCE COMMITMENT</span><code>{delivery.evidenceHash}</code></div>
              <pre>{JSON.stringify(delivery.delivery.payload, null, 2)}</pre>
              {delivery.delivery.faults.length > 0 && <div className="fault-list"><strong>Detected evidence flags</strong>{delivery.delivery.faults.map((fault) => <span key={fault}>× {fault}</span>)}</div>}
              {!verdict ? (
                <div className="verdict-actions"><div><strong>Your verdict controls the next transaction.</strong><span>Accept releases escrow. Dispute keeps escrow and bond locked for evidence review.</span></div><button className="button ghost accept-button" disabled={busy} onClick={() => void submitVerdict("accept")}>Accept + release</button><button className="button dispute-button" disabled={busy} onClick={() => void submitVerdict("dispute")}>Open dispute</button></div>
              ) : verdict === "dispute" && !resolved ? (
                <div className="resolution-gate"><div><p className="section-kicker">ESCROW + BOND REMAIN LOCKED</p><h3>Request the evidence ruling</h3><p>The arbiter recomputes the stored evidence commitment before choosing seller fault, seller prevails, or neutral infrastructure failure.</p></div><button className="button primary" disabled={busy} onClick={() => void resolve()}>{busy ? "Ruling on-chain…" : "Resolve from evidence →"}</button></div>
              ) : (
                <div className="final-outcome"><span>FINAL ON-CHAIN OUTCOME</span><h3>{resolved?.outcome.replaceAll("-", " ") ?? "seller paid"}</h3><p>{resolved?.message ?? "Buyer accepted the delivery. Escrow paid the seller and released the reserved bond."}</p></div>
              )}
            </div>
          )}

          {!state.data?.writeEnabled && <p className="inline-notice">The currently deployed escrow is the legacy contract, so transaction controls are deliberately locked. A fresh hardened deployment and funded role-separated wallets are required before judge writes can be enabled. Live proof remains readable below.</p>}
          {error && <div className="session-error" role="alert"><strong>Stopped safely</strong><span>{error}</span></div>}

          {events.length > 0 && (
            <div className="session-events"><div className="proof-list-head"><span>THIS SESSION</span><span>{busy ? "PROCESSING" : "VERIFIED STEPS"}</span></div>{events.filter((item) => item.type !== "error").map((item, index) => <article key={`${item.type}-${index}`}><span>{String(index + 1).padStart(2, "0")}</span><div><strong>{item.type.replaceAll("-", " ")}</strong><p>{item.message}</p></div>{item.txHash ? <a href={`${explorer}/tx/${item.txHash}`} target="_blank" rel="noreferrer">receipt ↗</a> : <small>OFF-CHAIN GATE</small>}</article>)}</div>
          )}
        </section>

        <aside className="proof-rail">
          <div className="rail-title"><span className="live-dot" /><span>ON-CHAIN PROOF</span></div>
          <div className="stat-grid"><div><span>Jobs</span><strong>{state.data?.totalJobs ?? "—"}</strong></div><div><span>Escrowed</span><strong>{state.data?.escrowedBot ?? "—"} BOT</strong></div><div><span>Bond rule</span><strong>{state.data?.bondRatioPercent ?? "—"}%</strong></div><div><span>Disputed</span><strong>{state.data?.disputedJobs ?? "—"}</strong></div></div>
          <div className="proof-list">
            <div className="proof-list-head"><span>Recent settlement proofs</span><span>LIVE</span></div>
            {jobs.data?.jobs.map((job) => <article className="proof-row" key={job.id}><div><strong>JOB {job.id.padStart(2, "0")}</strong><span className={`job-status ${job.statusLabel.toLowerCase().replace(" ", "-")}`}>{job.statusLabel}</span></div><p>{job.amountBot} BOT · agent #{job.sellerAgentId}</p><div className="proof-links">{Object.entries(job.proofs).map(([kind, hash]) => <a key={kind} href={`${explorer}/tx/${hash}`} target="_blank" rel="noreferrer">{kind} ↗</a>)}</div></article>) ?? <div className="skeleton-card">Reading transaction receipts…</div>}
          </div>
          {(state.error || sellers.error || jobs.error) && <button className="error-panel" onClick={() => { void state.retry(); void sellers.retry(); void jobs.retry(); }}>Live reads are stale. Retry now.</button>}
        </aside>
      </div>
    </>
  );
}
