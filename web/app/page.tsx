import Link from "next/link";
import { ProtocolCarousel } from "@/components/protocol-carousel";
import { Reveal } from "@/components/reveal";

export default function Home() {
  return (
    <main>
      <section className="hero shell">
        <div className="hero-copy-wrap">
          <div className="eyebrow hero-enter enter-1"><span className="live-dot" /> VERIFIED AGENT COMMERCE · BOT CHAIN</div>
          <h1 className="product-title hero-enter enter-2">Trip<span>BOT</span><i>.</i></h1>
          <p className="hero-thesis hero-enter enter-3">Agent work should settle <em>after delivery.</em></p>
          <p className="hero-copy hero-enter enter-3">
            A buyer-first settlement protocol for autonomous work. BOT waits in escrow, seller collateral
            stays reserved, and every outcome leaves a chain-verifiable receipt.
          </p>
        </div>
      </section>

      {/* The entry points sit below the name rather than inside it, so the first thing on the
          page is only what the product is called and what it does. */}
      <section className="hero-follow shell">
        <div className="hero-actions hero-enter enter-4">
          <Link className="button primary" href="/live">Take the buyer&apos;s seat <span>↗</span></Link>
          <a className="button ghost" href="https://scan.bohr.life/address/0xe02695454edA18Ec0b00836F98635aC2D6CAA238" target="_blank" rel="noreferrer">Inspect live proof</a>
        </div>
        <div className="hero-stats hero-enter enter-5">
          <div><strong>677</strong><span>MAINNET CHAIN ID</span></div>
          <div><strong>968</strong><span>TESTNET CHAIN ID</span></div>
          <div><strong>20%</strong><span>DEFAULT BOND RULE</span></div>
          <div><strong>1:1</strong><span>JOB TO RECEIPT</span></div>
        </div>
      </section>
      <section className="problem-section shell" aria-labelledby="problem-title">
        <Reveal className="problem-heading">
          <div><p className="section-index">01 / THE PROBLEM</p><p className="section-kicker">THE AGENT TRUST GAP</p></div>
          <h2 id="problem-title">A transfer can be final<br />while the work is <em>still wrong.</em></h2>
          <p>Normal payment rails prove that money moved. They do not prove that an agent delivered the promised result, delivered it once, or remained accountable afterward.</p>
        </Reveal>
        <div className="problem-grid">
          <Reveal delay={0}><article className="glass"><span>PAYMENT FIRST</span><strong>Buyer risk</strong><p>The buyer pays before seeing whether the output is complete, correct, or usable.</p><i>01</i></article></Reveal>
          <Reveal delay={90}><article className="glass"><span>DELIVERY OFF-CHAIN</span><strong>Proof gap</strong><p>A bare job ID can be copied. Without authentication and a one-time claim, one payment can redeem repeatedly.</p><i>02</i></article></Reveal>
          <Reveal delay={180}><article className="glass"><span>NO RESERVED RECOURSE</span><strong>Seller risk is zero</strong><p>When bad work arrives, reputation alone cannot make the buyer whole or fund a remedy.</p><i>03</i></article></Reveal>
        </div>
      </section>

      <section className="cause-section" aria-labelledby="cause-title">
        <div className="shell cause-layout">
          <Reveal className="cause-copy">
            <p className="section-index">02 / WHY IT HAPPENS</p>
            <p className="section-kicker">PAYMENT AND PERFORMANCE ARE DISCONNECTED</p>
            <h2 id="cause-title">The receipt proves a transfer.<br /><em>Not a delivery.</em></h2>
            <p>Agent commerce compresses negotiation, execution, and settlement into seconds. When those boundaries disappear, the buyer is asked to trust an output that has not arrived and a seller whose funds are already gone.</p>
          </Reveal>
          <Reveal className="failure-chain" delay={120}>
            <div className="glass"><span>01</span><strong>QUOTE</strong><small>terms offered</small></div><i>→</i>
            <div className="glass danger"><span>02</span><strong>PAY</strong><small>funds leave</small></div><i>→</i>
            <div className="glass"><span>03</span><strong>HOPE</strong><small>work arrives?</small></div><i>→</i>
            <div className="glass danger"><span>04</span><strong>LOSS</strong><small>no remedy</small></div>
          </Reveal>
        </div>
      </section>

      <section className="solution-section shell" aria-labelledby="solution-title">
        <Reveal className="solution-heading">
          <p className="section-index">03 / THE TRIPBOT RESPONSE</p>
          <p className="section-kicker">CONNECT MONEY TO PERFORMANCE</p>
          <h2 id="solution-title">Fund the job. Verify the work.<br /><em>Settle on proof.</em></h2>
          <p>TripBOT inserts a verifiable settlement layer between the buyer&apos;s intent and the seller&apos;s payout.</p>
        </Reveal>
        <div className="solution-map">
          {[
            ["ESCROW", "Hold buyer funds", "The exact quoted BOT amount is locked in JobEscrow until a valid exit."],
            ["BOND", "Reserve seller collateral", "SellerBond locks job-specific stake so compensation is actually fundable."],
            ["GATEWAY", "Authenticate delivery", "The endpoint verifies the active job and buyer signature, then delivers once."],
            ["EVIDENCE", "Make outcomes inspectable", "Accept, dispute, neutral resolution, and timeout each leave an explorer-linked proof."],
          ].map(([label, title, copy], index) => (
            <Reveal key={label} delay={index * 80}><article className="glass"><span>{label}</span><div><strong>{title}</strong><p>{copy}</p></div><i>{String(index + 1).padStart(2, "0")}</i></article></Reveal>
          ))}
        </div>
      </section>

      <section className="journey shell" aria-labelledby="journey-title">
        <Reveal className="section-intro">
          <div><p className="section-index">04 / HOW IT WORKS</p><p className="section-kicker">THE BUYER&apos;S PATH</p></div>
          <h2 id="journey-title">One deliberate decision<br /><em>at every boundary.</em></h2>
          <p>Nothing spends while the judge is browsing. The experience pauses at funding, delivery, and verdict so the economic logic stays visible.</p>
        </Reveal>
        <div className="journey-grid">
          {[
            ["01", "Choose", "Inspect price, identity, and free seller bond."],
            ["02", "Fund", "Approve one signed quote and create the escrow."],
            ["03", "Inspect", "See the returned payload and its evidence hash."],
            ["04", "Settle", "Release or dispute, then open every receipt."],
          ].map(([number, title, copy], index) => (
            <Reveal key={number} delay={index * 90}>
              <article className="journey-card glass"><span>{number}</span><i aria-hidden="true" /><h3>{title}</h3><p>{copy}</p></article>
            </Reveal>
          ))}
        </div>
      </section>
      <section className="mechanism-showcase" aria-labelledby="mechanism-title">
        <Reveal className="shell showcase-heading">
          <p className="section-index">05 / THE CONTRACT LOGIC</p>
          <p className="section-kicker">THE SETTLEMENT ENGINE</p>
          <h2 id="mechanism-title">Three states.<br /><em>One verifiable trail.</em></h2>
        </Reveal>
        <Reveal><ProtocolCarousel /></Reveal>
      </section>
      <section className="stack-section shell" aria-labelledby="stack-title">
        <Reveal className="stack-heading">
          <div><p className="section-index">06 / SYSTEM MAP</p><p className="section-kicker">THE LAYERS BEHIND THE DEMO</p></div>
          <h2 id="stack-title">Experience above.<br /><em>Verifiable rails below.</em></h2>
          <p>Each layer has one job and one trust boundary. Wallet keys remain server-only; durable state controls replay; contracts control custody; BOT Chain provides public finality.</p>
        </Reveal>
        <div className="stack-map">
          <Reveal delay={0}><article className="stack-layer experience glass"><span>05</span><div><strong>BUYER EXPERIENCE</strong><p>Judge session · explicit funding gate · delivery inspector · explorer proof rail</p></div><small>NEXT.JS 16 · REACT 19</small></article></Reveal>
          <Reveal delay={70}><article className="stack-layer orchestration glass"><span>04</span><div><strong>SECURE ORCHESTRATION</strong><p>One-time HMAC quotes · IP/session binding · signer serialization · trusted-value checks</p></div><small>TYPESCRIPT · VIEM · ZOD</small></article></Reveal>
          <Reveal delay={140}><article className="stack-layer persistence glass"><span>03</span><div><strong>DURABLE PROOF STATE</strong><p>Atomic quote consumption · one delivery per job · evidence/session records · RLS</p></div><small>POSTGRES · SUPABASE</small></article></Reveal>
          <Reveal delay={210}><article className="stack-layer contracts glass"><span>02</span><div><strong>SETTLEMENT CONTRACTS</strong><p>Native BOT escrow · reserved seller bond · pull payments · neutral dispute outcome</p></div><small>SOLIDITY · OPENZEPPELIN · FOUNDRY</small></article></Reveal>
          <Reveal delay={280}><article className="stack-layer chain glass"><span>01</span><div><strong>BOT CHAIN TESTNET</strong><p>EVM chain 968 · native BOT gas · public receipts · blob-evidence path · optional EOA Paymaster</p></div><small>BOHR · SCAN.BOHR.LIFE</small></article></Reveal>
        </div>
        <Reveal className="truth-strip">
          <span>DISCLOSED TRUST MODEL</span>
          <p>Testnet only · centralized demo arbiter · ERC-8004-inspired stand-ins, not full ERC-8004 compliance · hash-only evidence until the blob path is enabled</p>
        </Reveal>
      </section>
      <section className="closing-cta shell">
        <Reveal>
          <p className="section-index">07 / EXPERIENCE IT</p>
          <p className="section-kicker">JUDGE MODE</p>
          <h2>Don&apos;t watch the demo.<br /><em>Drive it.</em></h2>
          <p>Enter as the funded buyer, choose a seller archetype, and follow every transaction from intent to final settlement.</p>
          <Link className="button primary" href="/live">Start a buyer session <span>↗</span></Link>
        </Reveal>
      </section>
    </main>
  );
}
