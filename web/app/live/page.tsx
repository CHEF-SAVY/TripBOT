import { BuyerSession } from "@/components/buyer-session";

export default function LivePage() {
  return (
    <main className="live-page">
      <header className="lp-head">
        <p className="lp-head-kicker">Judge mode · funded buyer session</p>
        <h1>You control the buyer. The chain keeps the receipt.</h1>
        <p>
          This session directs a funded BOT Chain testnet wallet held server-side. It never connects to, or spends
          from, a personal wallet — and it stops to ask before it spends anything at all.
        </p>
      </header>
      <BuyerSession />
    </main>
  );
}
