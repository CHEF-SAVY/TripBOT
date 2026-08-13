"use client";

import { useCallback, useEffect, useState } from "react";

type Seller = {
  key: "honest" | "faulty" | "absent";
  name: string;
  archetype: "honest" | "faulty" | "absent";
  agentId: string | null;
  priceBot: string;
  service: string;
  description: string;
  configured: boolean;
  bond: { gross: string; reserved: string; free: string } | null;
  /// Collateral the escrow would reserve for this specific job, derived on the server from
  /// the chain's current bond ratio — this is what the buyer actually recovers on a slash.
  atRiskBot: string;
  atRiskCovered: boolean;
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

/// Rendered from the escrow's own responseWindow rather than a constant, because it is an
/// owner-settable risk parameter: printing a hardcoded figure would misstate how long the
/// buyer actually has to release or dispute the moment anyone changes it on-chain.
function formatWindow(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return "—";
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3_600) return `${Math.round(seconds / 60)}m`;
  if (seconds % 86_400 === 0) return `${seconds / 86_400}d`;
  return `${Math.round(seconds / 3_600)}h`;
}

type Payments = {
  refundBot: string;
  slashedBondBot: string;
  totalBot: string;
  bondBeforeBot: string;
  bondAfterBot: string;
  paidTo: "buyer" | "seller";
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
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const [events, setEvents] = useState<DemoEvent[]>([]);
  const [quote, setQuote] = useState<DemoEvent>();
  const [delivery, setDelivery] = useState<DemoEvent>();
  const [sessionToken, setSessionToken] = useState<string>();
  const [verdict, setVerdict] = useState<Verdict>();
  const [resolved, setResolved] = useState<{ message: string; txHash: string; outcome: string; payments?: Payments }>();
  const [stagedPayment, setStagedPayment] = useState<"none" | "refund" | "slash" | "total">("none");

  const phase: Phase = delivery ? "inspect" : quote ? "fund" : "choose";
  const visualPhase: Phase = verdict || resolved ? "settle" : phase;

  // Provisioned on arrival rather than unlocked with a code. The identity still matters:
  // it is what the tour limiter counts and what the quote and session tokens bind to.
  useEffect(() => {
    let active = true;
    void fetch("/api/live/access", { cache: "no-store" })
      .then((response) => response.json())
      .then((body: { authorized?: boolean }) => { if (active) setAuthorized(body.authorized === true); })
      .catch(() => undefined)
      .catch(() => undefined);
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
    setStagedPayment("none");
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
      const body = await response.json() as { message?: string; txHash?: string; outcome?: string; payments?: Payments; error?: string };
      if (!response.ok || !body.message || !body.txHash || !body.outcome) throw new Error(body.error || "The evidence ruling stopped safely.");
      setResolved({ message: body.message, txHash: body.txHash, outcome: body.outcome, payments: body.payments });
      setEvents((current) => [...current, { type: "resolved", message: body.message as string, txHash: body.txHash }]);

      // The buyer is compensated by two separate movements from two different contracts.
      // Revealing them a beat apart is what makes that legible; collapsing them into one
      // number is exactly the thing this product argues against. Reduced-motion users get
      // the completed ledger immediately rather than a staged one.
      if (body.payments && body.outcome === "seller-at-fault") {
        const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
        setStagedPayment(reduced ? "total" : "refund");
        if (!reduced) {
          window.setTimeout(() => setStagedPayment("slash"), 600);
          window.setTimeout(() => setStagedPayment("total"), 1_200);
        }
      } else {
        setStagedPayment("total");
      }
      await Promise.all([state.retry(), jobs.retry(), sellers.retry()]);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "The evidence ruling stopped safely.");
    } finally {
      setBusy(false);
    }
  }

  const canAct = Boolean(state.data?.writeEnabled && authorized);
  const funded = events.find((item) => item.type === "funded");
  const steps: Phase[] = ["choose", "fund", "inspect", "settle"];
  const stepIndex = steps.indexOf(visualPhase);

  return (
    <div className="lp">
      <nav className="lp-rail" aria-label="Session progress">
        {steps.map((step, index) => (
          <span key={step} className={`lp-rail-seg ${index === stepIndex ? "on" : index < stepIndex ? "done" : ""}`}>
            <i />
            <b>{step}</b>
          </span>
        ))}
      </nav>

      <section className="lp-stage" aria-live="polite">
        {!state.data?.writeEnabled && (
          <p className="lp-note">Read-only safety mode. The chain state below is real; no transaction can be sent.</p>
        )}

        {visualPhase === "choose" && (
          <div className="lp-act">
            <header className="lp-act-head">
              <p className="lp-kicker">Step 01 — counterparty</p>
              <h2>Who gets your job?</h2>
              <p>Three agents. Their collateral is real and posted on-chain. Their behaviour is not revealed until they deliver.</p>
            </header>

            <div className="lp-sellers">
              {sellers.data?.sellers.map((seller) => (
                <button
                  key={seller.key}
                  className={`lp-seller ${selected === seller.key ? "on" : ""}`}
                  onClick={() => { if (!busy && !quote) setSelected(seller.key); }}
                  disabled={!seller.configured || busy || Boolean(quote) || !canAct}
                >
                  <span className="lp-seller-top">
                    <i className={`lp-orb ${seller.archetype}`} />
                    <em>agent #{seller.agentId ?? "—"}</em>
                  </span>
                  <h3>{seller.name}</h3>
                  <p>{seller.service}</p>
                  <div className="lp-seller-price">
                    <span>{seller.priceBot} BOT</span>
                    {seller.bond && <b>recover {seller.atRiskBot} on fault</b>}
                  </div>
                  {seller.bond ? (
                    <dl className="lp-bond">
                      <div><dt>posted</dt><dd>{seller.bond.gross}</dd></div>
                      <div><dt>reserved</dt><dd>{seller.bond.reserved}</dd></div>
                      <div><dt>free</dt><dd>{seller.bond.free}</dd></div>
                    </dl>
                  ) : (
                    <p className="lp-warn">Not registered for this demo.</p>
                  )}
                  {seller.bond && !seller.atRiskCovered && <p className="lp-warn">Not enough free collateral right now.</p>}
                </button>
              )) ?? <div className="lp-skeleton">Reading collateral from SellerBond…</div>}
            </div>

            <div className="lp-cta">
              <button className="lp-btn primary" onClick={() => void requestTerms()} disabled={!selected || busy || !canAct}>
                {busy ? "Requesting terms…" : "Request verified terms"}
              </button>
              <small>Free. Registers an ERC-8004 validation request on-chain. Nothing is spent.</small>
            </div>
          </div>
        )}

        {visualPhase === "fund" && quote && (
          <div className="lp-act lp-narrow">
            <header className="lp-act-head">
              <p className="lp-kicker">Step 02 — escrow</p>
              <h2>Nothing has left the wallet yet.</h2>
              <p>These terms were checked against the escrow this server trusts, not the one the seller named.</p>
            </header>

            <dl className="lp-terms">
              <div><dt>Amount into escrow</dt><dd className="big">{quote.priceBot} BOT</dd></div>
              <div><dt>Seller collateral reserved</dt><dd>{quote.requiredBondBot} BOT</dd></div>
              <div><dt>Counterparty</dt><dd>agent #{quote.sellerAgentId}</dd></div>
              <div><dt>Release or dispute within</dt><dd>{state.data ? formatWindow(state.data.responseWindowSeconds) : "—"}</dd></div>
            </dl>

            <div className="lp-cta">
              <button className="lp-btn primary" onClick={() => void fund()} disabled={busy}>
                {busy ? "Sending to escrow…" : `Fund escrow · ${quote.priceBot} BOT`}
              </button>
              <small>The escrow holds it. The seller cannot take it.</small>
            </div>
          </div>
        )}

        {visualPhase === "inspect" && delivery && (
          <div className="lp-act lp-narrow">
            <header className="lp-act-head">
              <p className="lp-kicker">Step 03 — delivery{funded?.jobId ? ` · job #${funded.jobId}` : ""}</p>
              <h2>{delivery.delivery?.ok ? "Is this worth paying for?" : "Nothing usable arrived."}</h2>
              <p>{delivery.message}</p>
            </header>

            <div className="lp-payload">
              <span className="lp-payload-head">
                <em>HTTP {delivery.delivery?.status}</em>
                <em>{(delivery.evidenceMode ?? "hash-only").toUpperCase()} EVIDENCE</em>
              </span>
              <pre>{JSON.stringify(delivery.delivery?.payload, null, 2)}</pre>
              {delivery.delivery?.faults.length ? (
                <ul className="lp-faults">{delivery.delivery.faults.map((fault) => <li key={fault}>{fault}</li>)}</ul>
              ) : null}
              <code className="lp-hash">{delivery.evidenceHash}</code>
            </div>

            {!verdict && (
              <div className="lp-verdict">
                <button className="lp-btn" onClick={() => void submitVerdict("accept")} disabled={busy}>Accept · pay the seller</button>
                <button className="lp-btn danger" onClick={() => void submitVerdict("dispute")} disabled={busy}>Dispute · hold the funds</button>
              </div>
            )}
          </div>
        )}

        {visualPhase === "settle" && (
          <div className="lp-act lp-narrow">
            <header className="lp-act-head">
              <p className="lp-kicker">Step 04 — settlement</p>
              <h2>
                {resolved?.outcome === "seller-at-fault"
                  ? "The buyer was paid twice."
                  : resolved
                    ? resolved.outcome.replaceAll("-", " ")
                    : verdict === "dispute" ? "Escrow and collateral are locked." : "The seller was paid."}
              </h2>
              <p>{resolved?.message ?? (verdict === "dispute"
                ? "The arbiter re-reads the job on-chain and recomputes the evidence commitment before it can move anything."
                : "Escrow released to the seller and the reserved collateral was returned.")}</p>
            </header>

            {verdict === "dispute" && !resolved && (
              <div className="lp-cta">
                <button className="lp-btn primary" onClick={() => void resolve()} disabled={busy}>
                  {busy ? "Ruling on-chain…" : "Request the evidence ruling"}
                </button>
              </div>
            )}

            {resolved?.payments && resolved.payments.paidTo === "buyer" && (
              <div className="lp-pay" aria-live="polite">
                <div className={stagedPayment !== "none" ? "on" : ""}>
                  <span>Escrow refund</span><b>+{resolved.payments.refundBot} BOT</b>
                </div>
                {resolved.outcome === "seller-at-fault" && (
                  <div className={stagedPayment === "slash" || stagedPayment === "total" ? "on alarm" : ""}>
                    <span>Slashed collateral</span>
                    <b>{stagedPayment === "slash" || stagedPayment === "total" ? `+${resolved.payments.slashedBondBot} BOT` : "…"}</b>
                  </div>
                )}
                <div className={stagedPayment === "total" ? "on total" : ""}>
                  <span>Total to buyer</span>
                  <b>{stagedPayment === "total" ? `+${resolved.payments.totalBot} BOT` : "—"}</b>
                </div>
                <p>Seller collateral {resolved.payments.bondBeforeBot} → {resolved.payments.bondAfterBot} BOT</p>
              </div>
            )}

            {resolved?.outcome === "seller-at-fault" && stagedPayment === "total" && (
              <p className="lp-punch">The seller paid for failing, out of their own stake. That is the tripwire.</p>
            )}

            {resolved && (
              <div className="lp-cta">
                <button
                  className="lp-btn"
                  onClick={() => {
                    setSelected(undefined); setQuote(undefined); setDelivery(undefined);
                    setSessionToken(undefined); setVerdict(undefined); setResolved(undefined);
                    setStagedPayment("none"); setEvents([]);
                  }}
                >
                  Run another seller
                </button>
              </div>
            )}
          </div>
        )}

        {error && <p className="lp-error"><b>Stopped safely.</b> {error}</p>}
      </section>

      {events.length > 0 && (
        <section className="lp-trail">
          <h3>Receipts from this session</h3>
          <ol>
            {events.filter((item) => item.type !== "error").map((item, index) => (
              <li key={`${item.type}-${index}`}>
                <span className="lp-n">{String(index + 1).padStart(2, "0")}</span>
                <span className="lp-body"><b>{item.type.replaceAll("-", " ")}</b><em>{item.message}</em></span>
                {item.txHash
                  ? <a href={`${explorer}/tx/${item.txHash}`} target="_blank" rel="noreferrer">receipt ↗</a>
                  : <em className="lp-off">off-chain</em>}
              </li>
            ))}
          </ol>
        </section>
      )}

      <section className="lp-ledger">
        <h3>
          Settlement history
          <span>{state.data?.totalJobs ?? "—"} jobs · {state.data?.escrowedBot ?? "—"} BOT escrowed · {state.data?.bondRatioPercent ?? "—"}% collateral rule</span>
        </h3>
        <ol>
          {jobs.data?.jobs.map((job) => (
            <li key={job.id}>
              <span className="lp-n">#{job.id}</span>
              <span className="lp-body">
                <b>{job.statusLabel.toLowerCase()}</b>
                <em>{job.amountBot} BOT · agent #{job.sellerAgentId} · {job.reservedBondBot} BOT collateral</em>
              </span>
              <span className="lp-proofs">
                {Object.entries(job.proofs).map(([kind, hash]) => (
                  <a key={kind} href={`${explorer}/tx/${hash}`} target="_blank" rel="noreferrer">{kind} ↗</a>
                ))}
              </span>
            </li>
          )) ?? <li className="lp-skeleton">Reading job history…</li>}
        </ol>
      </section>
    </div>
  );
}
