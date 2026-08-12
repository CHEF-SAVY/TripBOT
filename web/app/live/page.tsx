import { BuyerSession } from "@/components/buyer-session";

export default function LivePage() {
  return (
    <main className="live-page shell-wide">
      <div className="live-heading">
        <div>
          <p className="section-kicker">JUDGE MODE · BUYER SESSION</p>
          <h1>You control the buyer. The chain keeps the receipt.</h1>
        </div>
        <p>This session directs a funded testnet buyer wallet. It never connects to or spends from your personal wallet.</p>
      </div>
      <BuyerSession />
    </main>
  );
}
